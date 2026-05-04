#!/usr/bin/env node
// Benchmark JS-only vs WASM multiband compressor.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'dynamics', 'multiband_compressor.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'multiband_compressor.wasm');

const src = fs.readFileSync(pluginPath, 'utf8');
const tplStart = src.indexOf('return `', src.indexOf('getProcessorCode')) + 'return `'.length;
const tplEnd = src.indexOf('`;', tplStart);
let body = src.slice(tplStart, tplEnd);
const wasmBlockStart = body.indexOf('// --- WebAssembly fast path');
const wasmBlockEnd = body.indexOf('// --- State Initialization');
if (wasmBlockStart >= 0 && wasmBlockEnd > wasmBlockStart) {
  body = body.slice(0, wasmBlockStart) + body.slice(wasmBlockEnd);
}

const sandbox = { Math, Float32Array, Number, Array };
vm.createContext(sandbox);
function jsRun(context, data, parameters, time) {
  sandbox.context = context;
  sandbox.data = data;
  sandbox.parameters = parameters;
  sandbox.time = time;
  return vm.runInContext(`(function(){ ${body}\nreturn data; })()`, sandbox);
}

const SR = 48000, BLOCK = 128, CHANS = 2, SAMPLES = CHANS * BLOCK;
const BLOCKS = 10000; // 10000 * 128 / 48000 = ~26.7 s of audio

const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, time: 0,
  f1: 100, f2: 500, f3: 2000, f4: 8000,
  bands: [
    { t: -20, r: 4,   a: 30,  rl: 150, k: 6, g: -1,  gr: 0 },
    { t: -22, r: 3,   a: 20,  rl: 120, k: 4, g: 0,   gr: 0 },
    { t: -25, r: 2.5, a: 15,  rl: 80,  k: 4, g: 1,   gr: 0 },
    { t: -28, r: 2,   a: 10,  rl: 60,  k: 3, g: 1.5, gr: 0 },
    { t: -18, r: 5,   a: 5,   rl: 40,  k: 2, g: -2,  gr: 0 }
  ]
};

const inputBuf = new Float32Array(SAMPLES);
for (let i = 0; i < BLOCK; i++) {
  const t = i / SR;
  const v = 0.4 * Math.sin(2 * Math.PI * 1000 * t) + 0.2 * Math.sin(2 * Math.PI * 60 * t)
          + 0.1 * Math.sin(2 * Math.PI * 9000 * t);
  inputBuf[i] = v;
  inputBuf[BLOCK + i] = v * 0.95;
}

(async () => {
  // ---- JS path ----
  const jsCtx = {};
  // Warm-up
  for (let i = 0; i < 100; i++) {
    const d = new Float32Array(inputBuf);
    jsRun(jsCtx, d, params, 0);
  }
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < BLOCKS; i++) {
    const d = new Float32Array(inputBuf);
    jsRun(jsCtx, d, params, 0);
  }
  const t1 = process.hrtime.bigint();
  const jsMs = Number(t1 - t0) / 1e6;

  // ---- WASM path ----
  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK, params.f1, params.f2, params.f3, params.f4);
  for (let b = 0; b < 5; b++) {
    const bp = params.bands[b];
    e.set_band_params(sp, b, bp.t, bp.r, bp.a, bp.rl, bp.k, bp.g);
  }
  const inView = new Float32Array(e.memory.buffer, e.input_ptr(sp), SAMPLES);
  const outView = new Float32Array(e.memory.buffer, e.output_ptr(sp), SAMPLES);
  // Warm-up
  for (let i = 0; i < 100; i++) {
    inView.set(inputBuf);
    e.process_block(sp, BLOCK);
  }
  const t2 = process.hrtime.bigint();
  for (let i = 0; i < BLOCKS; i++) {
    inView.set(inputBuf);
    e.process_block(sp, BLOCK);
  }
  const t3 = process.hrtime.bigint();
  const wasmMs = Number(t3 - t2) / 1e6;

  const audioMs = (BLOCKS * BLOCK / SR) * 1000;
  console.log(`Audio simulated: ${audioMs.toFixed(0)} ms`);
  console.log(`JS:    ${jsMs.toFixed(1)} ms total, ${(jsMs / BLOCKS * 1000).toFixed(2)} us/block, ${(audioMs / jsMs).toFixed(1)}x realtime`);
  console.log(`WASM:  ${wasmMs.toFixed(1)} ms total, ${(wasmMs / BLOCKS * 1000).toFixed(2)} us/block, ${(audioMs / wasmMs).toFixed(1)}x realtime`);
  console.log(`Speedup (WASM vs JS): ${(jsMs / wasmMs).toFixed(2)}x`);
  e.free_state(sp);
})();
