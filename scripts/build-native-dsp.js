#!/usr/bin/env node
// Build the EffeTune DSP modules as NATIVE macOS dylibs (for the native app).
//
// Each Rust module already exposes a clean C ABI (init/set_params/process_block/
// io_ptr/free_state + per-module extras) via #[no_mangle] pub extern "C", and is
// crate-type = ["cdylib"]. Building for an Apple target therefore yields a
// directly loadable .dylib with the SAME symbols used by the WASM build — no
// source changes required.
//
// Because every module exports the same symbol names (init, process_block, ...),
// they CANNOT be statically linked into one binary. The native app loads each
// module as its own dylib via dlopen/dlsym, which keeps the symbol namespaces
// separate. This script produces one universal (arm64 + x86_64) dylib per module
// under native/dsp/.
//
// If a target/toolchain is missing, the script degrades gracefully: it builds
// whatever arches are available (arm64-only is fine on Apple Silicon dev) and
// only lipo's when more than one arch was produced. Exits 0 when cargo is absent
// so other build steps can proceed.

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..');
const outDir = path.join(repoRoot, 'native', 'dsp');

// crate name (== artifact base) -> source dir under wasm-src/
const modules = [
  { crate: 'auto_leveler',          src: 'auto-leveler' },
  { crate: 'brickwall_limiter',     src: 'brickwall-limiter' },
  { crate: 'fifteen_band_peq',      src: 'fifteen-band-peq' },
  { crate: 'five_band_peq',         src: 'five-band-peq' },
  { crate: 'multiband_compressor',  src: 'multiband-compressor' },
  { crate: 'spectrum_analyzer',     src: 'spectrum-analyzer' },
  { crate: 'sub_synth',             src: 'sub-synth' },
  { crate: 'transient_shaper',      src: 'transient-shaper' },
];

const ARCHES = ['aarch64-apple-darwin', 'x86_64-apple-darwin'];

function has(cmd) {
  const finder = process.platform === 'win32' ? 'where' : 'which';
  return spawnSync(finder, [cmd], { stdio: 'ignore' }).status === 0;
}

function installedTargets() {
  const r = spawnSync('rustup', ['target', 'list', '--installed'], { encoding: 'utf8' });
  if (r.status !== 0 || !r.stdout) return null; // rustup missing -> assume host only
  return r.stdout.split('\n').map((s) => s.trim()).filter(Boolean);
}

if (!has('cargo')) {
  console.log('[build-native-dsp] cargo not found; skipping native DSP build');
  process.exit(0);
}
if (process.platform !== 'darwin') {
  console.log('[build-native-dsp] not macOS; native dylibs are only used by the macOS app');
  process.exit(0);
}

const targets = installedTargets();
const arches = ARCHES.filter((a) => !targets || targets.includes(a));
if (arches.length === 0) {
  console.error('[build-native-dsp] no Apple Rust targets installed (rustup target add aarch64-apple-darwin)');
  process.exit(1);
}
console.log(`[build-native-dsp] building arches: ${arches.join(', ')}`);

fs.mkdirSync(outDir, { recursive: true });

for (const m of modules) {
  const srcDir = path.join(repoRoot, 'wasm-src', m.src);
  const archDylibs = [];
  for (const arch of arches) {
    console.log(`[build-native-dsp] ${m.crate} (${arch})`);
    const build = spawnSync('cargo', ['build', '--release', '--target', arch], {
      cwd: srcDir,
      stdio: 'inherit',
    });
    if (build.status !== 0) {
      console.error(`[build-native-dsp] cargo build failed for ${m.crate}/${arch}`);
      process.exit(build.status || 1);
    }
    archDylibs.push(path.join(srcDir, 'target', arch, 'release', `lib${m.crate}.dylib`));
  }

  const out = path.join(outDir, `lib${m.crate}.dylib`);
  if (archDylibs.length === 1) {
    fs.copyFileSync(archDylibs[0], out);
  } else {
    const lipo = spawnSync('lipo', ['-create', ...archDylibs, '-output', out], { stdio: 'inherit' });
    if (lipo.status !== 0) {
      console.error(`[build-native-dsp] lipo failed for ${m.crate}`);
      process.exit(lipo.status || 1);
    }
  }
  console.log(`[build-native-dsp] -> ${path.relative(repoRoot, out)}`);
}

console.log(`[build-native-dsp] done: ${modules.length} dylibs in ${path.relative(repoRoot, outDir)}`);
