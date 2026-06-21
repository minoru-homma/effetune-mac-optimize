#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'dynamics', 'brickwall_limiter.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'brickwall_limiter.wasm');

const src = fs.readFileSync(pluginPath, 'utf8');
const start = src.indexOf("this.registerProcessor(`") + "this.registerProcessor(`".length;
let end = -1;
for (let i = start; i < src.length - 1; i++) {
  if (src[i] === '`' && src[i + 1] === ')' && src[i - 1] !== '\\') { end = i; break; }
}
let body = src.slice(start, end).replace(/\\`/g, '`').replace(/\\\$/g, '$');
const wasmStart = body.indexOf('// --- WebAssembly fast path');
if (wasmStart >= 0) {
  // Strip the WASM block — we want to benchmark the pure JS path here.
  // Find the closing `}` of the outer `if (context.wasmModule ...) { ... }`.
  let depth = 0;
  let scan = body.indexOf('if (context.wasmModule', wasmStart);
  let openBrace = body.indexOf('{', scan);
  let i = openBrace + 1;
  depth = 1;
  while (i < body.length && depth > 0) {
    if (body[i] === '{') depth++;
    else if (body[i] === '}') depth--;
    i++;
  }
  body = body.slice(0, wasmStart) + body.slice(i);
}

const sandbox = { Math, Float32Array, Float64Array, Number, Array };
vm.createContext(sandbox);
function jsRun(context, data, parameters, time) {
  sandbox.context = context;
  sandbox.data = data;
  sandbox.parameters = parameters;
  sandbox.time = time;
  return vm.runInContext(`(function(){ ${body}\nreturn data; })()`, sandbox);
}

const SR = 96000, BLOCK = 128, CHANS = 2, SAMPLES = CHANS * BLOCK;
const BLOCKS = 5000;
const OS = 4;

const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, time: 0,
  th: -1, rl: 100, la: 3, os: OS, ig: 0, sm: -0.5
};

const inputBuf = new Float32Array(SAMPLES);
for (let i = 0; i < BLOCK; i++) {
  const t = i / SR;
  const v = 0.95 * Math.sin(2 * Math.PI * 1000 * t);
  inputBuf[i] = v; inputBuf[BLOCK + i] = v * 0.99;
}

(async () => {
  const jsCtx = {};
  for (let i = 0; i < 50; i++) { const d = new Float32Array(inputBuf); jsRun(jsCtx, d, params, 0); }
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < BLOCKS; i++) { const d = new Float32Array(inputBuf); jsRun(jsCtx, d, params, 0); }
  const t1 = process.hrtime.bigint();
  const jsMs = Number(t1 - t0) / 1e6;

  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK, OS);
  e.set_params(sp, params.th, params.rl, params.la, params.ig, params.sm);
  const inPtr = e.input_ptr(sp);
  // Refresh view each call: in tight loops the WASM memory stays put after the
  // first allocation, but explicitly recreating the view is the safe pattern.
  for (let i = 0; i < 50; i++) {
    new Float32Array(e.memory.buffer, inPtr, SAMPLES).set(inputBuf);
    e.process_block(sp, BLOCK);
  }
  const t2 = process.hrtime.bigint();
  for (let i = 0; i < BLOCKS; i++) {
    new Float32Array(e.memory.buffer, inPtr, SAMPLES).set(inputBuf);
    e.process_block(sp, BLOCK);
  }
  const t3 = process.hrtime.bigint();
  const wasmMs = Number(t3 - t2) / 1e6;

  const audioMs = (BLOCKS * BLOCK / SR) * 1000;
  console.log(`Audio simulated: ${audioMs.toFixed(0)} ms (96kHz, OS=${OS})`);
  console.log(`JS:    ${jsMs.toFixed(1)} ms total, ${(jsMs / BLOCKS * 1000).toFixed(2)} us/block, ${(audioMs / jsMs).toFixed(1)}x realtime`);
  console.log(`WASM:  ${wasmMs.toFixed(1)} ms total, ${(wasmMs / BLOCKS * 1000).toFixed(2)} us/block, ${(audioMs / wasmMs).toFixed(1)}x realtime`);
  console.log(`Speedup (WASM vs JS): ${(jsMs / wasmMs).toFixed(2)}x`);
  e.free_state(sp);
})();
