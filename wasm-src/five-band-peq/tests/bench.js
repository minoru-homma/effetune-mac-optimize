#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'eq', 'five_band_peq.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'five_band_peq.wasm');

const src = fs.readFileSync(pluginPath, 'utf8');
const marker = 'static processorFunction = `';
const start = src.indexOf(marker) + marker.length;
let end = -1;
for (let i = start; i < src.length - 1; i++) {
  if (src[i] === '`' && src[i + 1] === ';' && src[i - 1] !== '\\') { end = i; break; }
}
let body = src.slice(start, end).replace(/\\`/g, '`').replace(/\\\$/g, '$');
const wasmStart = body.indexOf('// --- WebAssembly fast path');
if (wasmStart >= 0) {
  const wasmEnd = body.indexOf('\n  }\n', wasmStart);
  if (wasmEnd >= 0) body = body.slice(0, wasmStart) + body.slice(wasmEnd + 5);
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
const BLOCKS = 10000;

const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, ch: 'All',
  e0: true, t0: 'ls', f0: 80,    g0: 4.0, q0: 0.7,
  e1: true, t1: 'pk', f1: 320,   g1: -3.0, q1: 1.4,
  e2: true, t2: 'pk', f2: 1000, g2: 2.0,  q2: 1.0,
  e3: true, t3: 'pk', f3: 3160,  g3: 6.0,  q3: 1.0,
  e4: true, t4: 'hs', f4: 10000, g4: -2.0, q4: 0.7
};
const TYPE_MAP = { pk: 0, lp: 1, hp: 2, ls: 3, hs: 4, bp: 5, no: 6, ap: 7 };

const inputBuf = new Float32Array(SAMPLES);
for (let i = 0; i < BLOCK; i++) {
  const t = i / SR;
  const v = 0.4 * Math.sin(2 * Math.PI * 1000 * t) + 0.2 * Math.sin(2 * Math.PI * 80 * t)
          + 0.15 * Math.sin(2 * Math.PI * 5000 * t);
  inputBuf[i] = v; inputBuf[BLOCK + i] = v * 0.97;
}

(async () => {
  const jsCtx = {};
  for (let i = 0; i < 100; i++) { const d = new Float32Array(inputBuf); jsRun(jsCtx, d, params, 0); }
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < BLOCKS; i++) { const d = new Float32Array(inputBuf); jsRun(jsCtx, d, params, 0); }
  const t1 = process.hrtime.bigint();
  const jsMs = Number(t1 - t0) / 1e6;

  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK);
  for (let i = 0; i < 5; i++) {
    e.set_band(sp, i, params['e' + i] ? 1 : 0, TYPE_MAP[params['t' + i]],
      params['f' + i], params['g' + i], params['q' + i]);
  }
  const ioView = new Float32Array(e.memory.buffer, e.io_ptr(sp), SAMPLES);
  for (let i = 0; i < 100; i++) { ioView.set(inputBuf); e.process_block(sp, BLOCK); }
  const t2 = process.hrtime.bigint();
  for (let i = 0; i < BLOCKS; i++) { ioView.set(inputBuf); e.process_block(sp, BLOCK); }
  const t3 = process.hrtime.bigint();
  const wasmMs = Number(t3 - t2) / 1e6;

  const audioMs = (BLOCKS * BLOCK / SR) * 1000;
  console.log(`Audio simulated: ${audioMs.toFixed(0)} ms`);
  console.log(`JS:    ${jsMs.toFixed(1)} ms total, ${(jsMs / BLOCKS * 1000).toFixed(2)} us/block, ${(audioMs / jsMs).toFixed(1)}x realtime`);
  console.log(`WASM:  ${wasmMs.toFixed(1)} ms total, ${(wasmMs / BLOCKS * 1000).toFixed(2)} us/block, ${(audioMs / wasmMs).toFixed(1)}x realtime`);
  console.log(`Speedup (WASM vs JS): ${(jsMs / wasmMs).toFixed(2)}x`);
  e.free_state(sp);
})();
