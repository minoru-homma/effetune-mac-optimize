#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'dynamics', 'transient_shaper.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'transient_shaper.wasm');

const src = fs.readFileSync(pluginPath, 'utf8');
const start = src.indexOf("this.registerProcessor(`") + "this.registerProcessor(`".length;
let end = -1;
for (let i = start; i < src.length - 1; i++) {
  if (src[i] === '`' && src[i + 1] === ')' && src[i - 1] !== '\\') { end = i; break; }
}
let body = src.slice(start, end).replace(/\\`/g, '`').replace(/\\\$/g, '$');
const wasmStart = body.indexOf('// --- WebAssembly fast path');
if (wasmStart >= 0) {
  let scan = body.indexOf('if (context.wasmModule', wasmStart);
  let i = body.indexOf('{', scan) + 1;
  let depth = 1;
  while (i < body.length && depth > 0) {
    if (body[i] === '{') depth++; else if (body[i] === '}') depth--;
    i++;
  }
  body = body.slice(0, wasmStart) + body.slice(i);
}

const sandbox = { Math, Float32Array, Number, Array, console };
vm.createContext(sandbox);
function jsRun(context, data, parameters, time) {
  sandbox.context = context;
  sandbox.data = data;
  sandbox.parameters = parameters;
  sandbox.time = time;
  return vm.runInContext(`(function(){ ${body}\nreturn data; })()`, sandbox);
}

const SR = 96000, BLOCK = 128, CHANS = 2, SAMPLES = CHANS * BLOCK;
const BLOCKS = 200;
const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, time: 0,
  fa: 2, fr: 30, sa: 25, sr: 400, gt: 3, gs: 0, sm: 8
};
function fillInput(buf, blkIdx) {
  for (let i = 0; i < BLOCK; i++) {
    const n = blkIdx * BLOCK + i;
    const t = n / SR;
    // Mix of percussive and sustained content
    const v = 0.5 * Math.sin(2 * Math.PI * 440 * t)
            + 0.3 * Math.sin(2 * Math.PI * 1000 * t) * Math.exp(-((n % 4800) / 4800) * 4);
    buf[i] = v;
    buf[BLOCK + i] = v * 0.97;
  }
}
const jsCtx = {};
const jsOutputs = [];
for (let blk = 0; blk < BLOCKS; blk++) {
  const data = new Float32Array(SAMPLES);
  fillInput(data, blk);
  jsRun(jsCtx, data, params, blk * BLOCK / SR);
  jsOutputs.push(new Float32Array(data));
}

(async () => {
  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK);
  e.set_params(sp, params.fa, params.fr, params.sa, params.sr, params.gt, params.gs, params.sm);
  let sumSqDiff = 0, sumSqJs = 0, maxAbsDiff = 0;
  for (let blk = 0; blk < BLOCKS; blk++) {
    const data = new Float32Array(SAMPLES);
    fillInput(data, blk);
    new Float32Array(e.memory.buffer, e.io_ptr(sp), SAMPLES).set(data);
    e.process_block(sp, BLOCK);
    const ioView = new Float32Array(e.memory.buffer, e.io_ptr(sp), SAMPLES);
    const wOut = new Float32Array(ioView);
    const jOut = jsOutputs[blk];
    let blkMax = 0;
    for (let i = 0; i < SAMPLES; i++) {
      const d = wOut[i] - jOut[i];
      sumSqDiff += d * d;
      sumSqJs += jOut[i] * jOut[i];
      const ad = Math.abs(d);
      if (ad > blkMax) blkMax = ad;
      if (ad > maxAbsDiff) maxAbsDiff = ad;
    }
    if (blk < 3 || blk === BLOCKS - 1) {
      console.log(`block ${blk}: max=${blkMax.toFixed(7)}`);
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
