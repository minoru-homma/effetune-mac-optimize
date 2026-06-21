#!/usr/bin/env node
// Build the SIMD-accelerated WebAssembly bundles used by select plugins.
// If the Rust toolchain is unavailable, the script exits 0 so the regular
// Electron build can proceed using the committed *.wasm files.

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const targets = [
  {
    name: 'multiband_compressor',
    src: path.join(repoRoot, 'wasm-src', 'multiband-compressor'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'multiband_compressor.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/multiband_compressor.wasm'
  },
  {
    name: 'five_band_peq',
    src: path.join(repoRoot, 'wasm-src', 'five-band-peq'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'five_band_peq.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/five_band_peq.wasm'
  },
  {
    name: 'brickwall_limiter',
    src: path.join(repoRoot, 'wasm-src', 'brickwall-limiter'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'brickwall_limiter.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/brickwall_limiter.wasm'
  },
  {
    name: 'transient_shaper',
    src: path.join(repoRoot, 'wasm-src', 'transient-shaper'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'transient_shaper.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/transient_shaper.wasm'
  },
  {
    name: 'sub_synth',
    src: path.join(repoRoot, 'wasm-src', 'sub-synth'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'sub_synth.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/sub_synth.wasm'
  },
  {
    name: 'auto_leveler',
    src: path.join(repoRoot, 'wasm-src', 'auto-leveler'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'auto_leveler.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/auto_leveler.wasm'
  },
  {
    name: 'spectrum_analyzer',
    src: path.join(repoRoot, 'wasm-src', 'spectrum-analyzer'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'spectrum_analyzer.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/spectrum_analyzer.wasm'
  },
  {
    name: 'fifteen_band_peq',
    src: path.join(repoRoot, 'wasm-src', 'fifteen-band-peq'),
    out: path.join(repoRoot, 'plugins', 'wasm', 'fifteen_band_peq.wasm'),
    artifact: 'target/wasm32-unknown-unknown/release/fifteen_band_peq.wasm'
  }
];

function hasCargo() {
  const finder = process.platform === 'win32' ? 'where' : 'which';
  const r = spawnSync(finder, ['cargo'], { stdio: 'ignore' });
  return r.status === 0;
}

if (!hasCargo()) {
  console.log('[build-wasm] cargo not found; using committed plugins/wasm/*.wasm');
  process.exit(0);
}

for (const t of targets) {
  console.log(`[build-wasm] building ${t.name}`);
  const build = spawnSync(
    'cargo',
    ['build', '--release', '--target', 'wasm32-unknown-unknown'],
    { cwd: t.src, stdio: 'inherit' }
  );
  if (build.status !== 0) {
    console.error(`[build-wasm] cargo build failed for ${t.name} (exit ${build.status})`);
    process.exit(build.status || 1);
  }
  const built = path.join(t.src, t.artifact);
  fs.mkdirSync(path.dirname(t.out), { recursive: true });
  fs.copyFileSync(built, t.out);
  console.log(`[build-wasm] -> ${path.relative(repoRoot, t.out)}`);
}
