#!/usr/bin/env node
//
// A/B parity gate for the Rust+WASM DSP ports.
//
// Each wasm-src/<crate>/tests/ab_compare.js runs the JS-only reference
// processor and the committed WASM port over the same input and prints a
// numeric comparison ("Max abs diff:" / "Signal/diff:"). Those harnesses only
// *print* — they assert nothing — so a DSP regression or a stale committed
// .wasm would pass silently. This runner executes all of them and FAILS
// (non-zero exit) when any crate's parity falls outside an audio-realistic
// tolerance.
//
// The default thresholds are intentionally loose: this is the "measure first"
// gate (see review decision). They catch gross breakage — wrong algorithm,
// stale binary, NaN/Inf — while tolerating the f32(WASM)-vs-f64(JS) numeric
// noise that the ports inherently carry. Tighten via env once measured:
//
//   AB_MAXABS=<linear>   max |WASM-JS| for time-domain crates   (default 1e-2)
//   AB_SND_DB=<dB>       min signal-to-diff ratio for those     (default 40)
//   AB_SPECTRUM_DB=<dB>  max per-bin dB error for spectrum       (default 1.0)
//
// No network / no Rust toolchain needed: runs against the committed
// plugins/wasm/*.wasm. Not wired into CI by request (fork); run locally with
// `npm test`.

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');

const MAXABS_LIMIT = Number(process.env.AB_MAXABS || 1e-2);
const SND_DB_LIMIT = Number(process.env.AB_SND_DB || 40);
const SPECTRUM_DB_LIMIT = Number(process.env.AB_SPECTRUM_DB || 1.0);

// crate dir -> kind. 'spectrum' compares in the dB domain (no Signal/diff);
// everything else is a time-domain sample comparison.
const CRATES = [
  { dir: 'multiband-compressor', kind: 'time' },
  { dir: 'five-band-peq', kind: 'time' },
  { dir: 'fifteen-band-peq', kind: 'time' },
  { dir: 'brickwall-limiter', kind: 'time' },
  { dir: 'transient-shaper', kind: 'time' },
  { dir: 'sub-synth', kind: 'time' },
  { dir: 'auto-leveler', kind: 'time' },
  { dir: 'spectrum-analyzer', kind: 'spectrum' }
];

function parseNumber(stdout, re) {
  const m = stdout.match(re);
  return m ? Number(m[1]) : NaN;
}

function evaluate(crate, stdout) {
  const maxAbs = parseNumber(stdout, /Max abs diff:\s*(-?[0-9.eE+]+)/);
  if (crate.kind === 'spectrum') {
    // "Max abs diff:  X dB at bin N" — dB-domain magnitude error.
    if (!Number.isFinite(maxAbs)) {
      return { pass: false, why: 'no "Max abs diff" line in output', maxAbs, snd: NaN };
    }
    return {
      pass: maxAbs <= SPECTRUM_DB_LIMIT,
      why: `maxAbs=${maxAbs} dB (limit ${SPECTRUM_DB_LIMIT})`,
      maxAbs, snd: NaN
    };
  }
  const snd = parseNumber(stdout, /Signal\/diff:\s*(-?[0-9.eE+]+)\s*dB/);
  if (!Number.isFinite(maxAbs) || !Number.isFinite(snd)) {
    return { pass: false, why: 'missing "Max abs diff"/"Signal/diff" in output', maxAbs, snd };
  }
  const pass = maxAbs <= MAXABS_LIMIT && snd >= SND_DB_LIMIT;
  return {
    pass,
    why: `maxAbs=${maxAbs} (limit ${MAXABS_LIMIT}), S/diff=${snd} dB (limit ${SND_DB_LIMIT})`,
    maxAbs, snd
  };
}

let anyFail = false;
const rows = [];

for (const crate of CRATES) {
  const harness = path.join(repoRoot, 'wasm-src', crate.dir, 'tests', 'ab_compare.js');
  if (!fs.existsSync(harness)) {
    rows.push({ dir: crate.dir, status: 'MISSING', detail: harness });
    anyFail = true;
    continue;
  }
  const r = spawnSync(process.execPath, [harness], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: 120000
  });
  const out = (r.stdout || '') + (r.stderr || '');
  if (r.status !== 0) {
    rows.push({
      dir: crate.dir,
      status: 'FAIL',
      detail: `harness exited ${r.status}${r.signal ? ' (' + r.signal + ')' : ''}`
    });
    process.stdout.write(out);
    anyFail = true;
    continue;
  }
  const verdict = evaluate(crate, out);
  rows.push({
    dir: crate.dir,
    status: verdict.pass ? 'PASS' : 'FAIL',
    detail: verdict.why
  });
  if (!verdict.pass) {
    process.stdout.write(out);
    anyFail = true;
  }
}

console.log('\n=== A/B parity summary ===');
for (const row of rows) {
  console.log(`  [${row.status}] ${row.dir.padEnd(22)} ${row.detail}`);
}
console.log(`Thresholds: AB_MAXABS=${MAXABS_LIMIT} AB_SND_DB=${SND_DB_LIMIT} AB_SPECTRUM_DB=${SPECTRUM_DB_LIMIT}`);

if (anyFail) {
  console.error('\nA/B parity gate FAILED — see crate output above.');
  process.exit(1);
}
console.log('\nA/B parity gate passed.');
