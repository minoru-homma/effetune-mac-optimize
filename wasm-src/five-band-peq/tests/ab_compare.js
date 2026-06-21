#!/usr/bin/env node
// A/B numerical comparison of the JS-only 5 Band PEQ processor against the WASM port.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'eq', 'five_band_peq.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'five_band_peq.wasm');

// 1. Extract the JS processor body from the static processorFunction template.
const src = fs.readFileSync(pluginPath, 'utf8');
const marker = 'static processorFunction = `';
const start = src.indexOf(marker) + marker.length;
// Find the closing backtick of the OUTER template literal: a backtick + semicolon
// that is NOT preceded by a backslash (which would mean an escaped inner backtick).
let end = -1;
for (let i = start; i < src.length - 1; i++) {
  if (src[i] === '`' && src[i + 1] === ';' && src[i - 1] !== '\\') {
    end = i;
    break;
  }
}
let body = src.slice(start, end);
// Strip escape sequences that the template literal carries in source form.
body = body.replace(/\\`/g, '`').replace(/\\\$/g, '$');
// Excise the WebAssembly fast-path block so we exercise the pure JS path here.
const wasmStart = body.indexOf('// --- WebAssembly fast path');
if (wasmStart >= 0) {
  // Match the closing brace of the outer `if (context.wasmModule ...)` block.
  // The block ends at a single `}` at column 2 (indent matches surrounding code).
  const wasmEnd = body.indexOf('\n  }\n', wasmStart);
  if (wasmEnd >= 0) {
    body = body.slice(0, wasmStart) + body.slice(wasmEnd + 5);
  }
}

const sandbox = { Math, Float32Array, Number, Array, console };
vm.createContext(sandbox);
function runJsProcessor(context, data, parameters, time) {
  sandbox.context = context;
  sandbox.data = data;
  sandbox.parameters = parameters;
  sandbox.time = time;
  return vm.runInContext(`(function(){ ${body}\nreturn data; })()`, sandbox);
}

const SR = 48000, BLOCK = 128, CHANS = 2, SAMPLES = CHANS * BLOCK;
const BLOCKS = 200;

// Mixed band activity: low shelf + 2 peaks + high cut + bypassed band
const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, ch: 'All',
  e0: true, t0: 'ls', f0: 80,    g0: 4.0, q0: 0.7,
  e1: true, t1: 'pk', f1: 320,   g1: -3.0, q1: 1.4,
  e2: false, t2: 'pk', f2: 1000, g2: 0.0,  q2: 1.0,
  e3: true, t3: 'pk', f3: 3160,  g3: 6.0,  q3: 1.0,
  e4: true, t4: 'hs', f4: 10000, g4: -2.0, q4: 0.7
};

function fillInput(buf, blkIdx) {
  for (let i = 0; i < BLOCK; i++) {
    const n = blkIdx * BLOCK + i;
    const t = n / SR;
    const v = 0.4 * Math.sin(2 * Math.PI * 1000 * t)
            + 0.2 * Math.sin(2 * Math.PI * 80 * t)
            + 0.15 * Math.sin(2 * Math.PI * 5000 * t);
    buf[i] = v;
    buf[BLOCK + i] = v * 0.97;
  }
}

const TYPE_MAP = { pk: 0, lp: 1, hp: 2, ls: 3, hs: 4, bp: 5, no: 6, ap: 7 };

const jsCtx = {};
const jsOutputs = [];
for (let blk = 0; blk < BLOCKS; blk++) {
  const data = new Float32Array(SAMPLES);
  fillInput(data, blk);
  runJsProcessor(jsCtx, data, params, blk * BLOCK / SR);
  jsOutputs.push(new Float32Array(data));
}

(async () => {
  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK);
  for (let i = 0; i < 5; i++) {
    e.set_band(sp, i,
      params['e' + i] ? 1 : 0,
      TYPE_MAP[params['t' + i]],
      params['f' + i],
      params['g' + i],
      params['q' + i]
    );
  }
  let sumSqDiff = 0, sumSqJs = 0, maxAbsDiff = 0;
  for (let blk = 0; blk < BLOCKS; blk++) {
    const data = new Float32Array(SAMPLES);
    fillInput(data, blk);
    const ioView = new Float32Array(e.memory.buffer, e.io_ptr(sp), SAMPLES);
    ioView.set(data);
    e.process_block(sp, BLOCK);
    const wOut = new Float32Array(ioView);
    const jOut = jsOutputs[blk];
    let blkSqDiff = 0;
    for (let i = 0; i < SAMPLES; i++) {
      const d = wOut[i] - jOut[i];
      sumSqDiff += d * d;
      blkSqDiff += d * d;
      sumSqJs += jOut[i] * jOut[i];
      if (Math.abs(d) > maxAbsDiff) maxAbsDiff = Math.abs(d);
    }
    if (blk < 3 || blk === BLOCKS - 1) {
      console.log(`block ${blk}: rms_diff=${Math.sqrt(blkSqDiff / SAMPLES).toFixed(7)}`);
    }
  }
  const rmsDiff = Math.sqrt(sumSqDiff / (BLOCKS * SAMPLES));
  const rmsJs = Math.sqrt(sumSqJs / (BLOCKS * SAMPLES));
  console.log(`\n  JS RMS:        ${rmsJs.toFixed(6)} (${(20 * Math.log10(rmsJs)).toFixed(2)} dBFS)`);
  console.log(`  Diff RMS:      ${rmsDiff.toFixed(6)} (${(20 * Math.log10(rmsDiff + 1e-30)).toFixed(2)} dBFS)`);
  console.log(`  Max abs diff:  ${maxAbsDiff.toFixed(6)}`);
  console.log(`  Signal/diff:   ${(20 * Math.log10(rmsJs / (rmsDiff + 1e-30))).toFixed(2)} dB`);
  e.free_state(sp);
})();
