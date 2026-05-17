#!/usr/bin/env node
// A/B compare 15-Band PEQ JS vs WASM.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'eq', 'fifteen_band_peq.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'fifteen_band_peq.wasm');

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
const BANDS = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000];
const TYPES = ['ls', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'pk', 'hs'];
const GAINS = [3, -2, 1, 0, -1, 2, 0, -1, 1, 0, 2, -2, 1, 0, 2];
const QS = [0.7, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.7];

const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, time: 0, ch: 'All'
};
for (let i = 0; i < 15; i++) {
  params['e' + i] = true;
  params['t' + i] = TYPES[i];
  params['f' + i] = BANDS[i];
  params['g' + i] = GAINS[i];
  params['q' + i] = QS[i];
}

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

const jsCtx = {};
const jsOutputs = [];
for (let blk = 0; blk < BLOCKS; blk++) {
  const data = new Float32Array(SAMPLES);
  fillInput(data, blk);
  jsRun(jsCtx, data, params, blk * BLOCK / SR);
  jsOutputs.push(new Float32Array(data));
}

const TYPE_MAP = { pk: 0, lp: 1, hp: 2, ls: 3, hs: 4, bp: 5, no: 6, ap: 7 };

(async () => {
  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK);
  for (let i = 0; i < 15; i++) {
    e.set_band(sp, i, params['e' + i] ? 1 : 0, TYPE_MAP[params['t' + i]],
      params['f' + i], params['g' + i], params['q' + i]);
  }
  let sumSqDiff = 0, sumSqJs = 0, maxAbsDiff = 0;
  for (let blk = 0; blk < BLOCKS; blk++) {
    const data = new Float32Array(SAMPLES);
    fillInput(data, blk);
    new Float32Array(e.memory.buffer, e.io_ptr(sp), SAMPLES).set(data);
    e.process_block(sp, BLOCK);
    const ioView = new Float32Array(e.memory.buffer, e.io_ptr(sp), SAMPLES);
    const wOut = new Float32Array(ioView);
    const jOut = jsOutputs[blk];
    for (let i = 0; i < SAMPLES; i++) {
      const d = wOut[i] - jOut[i];
      sumSqDiff += d * d;
      sumSqJs += jOut[i] * jOut[i];
      if (Math.abs(d) > maxAbsDiff) maxAbsDiff = Math.abs(d);
    }
  }
  const rmsDiff = Math.sqrt(sumSqDiff / (BLOCKS * SAMPLES));
  const rmsJs = Math.sqrt(sumSqJs / (BLOCKS * SAMPLES));
  console.log(`  JS RMS:        ${rmsJs.toFixed(6)} (${(20 * Math.log10(rmsJs)).toFixed(2)} dBFS)`);
  console.log(`  Diff RMS:      ${rmsDiff.toFixed(6)} (${(20 * Math.log10(rmsDiff + 1e-30)).toFixed(2)} dBFS)`);
  console.log(`  Max abs diff:  ${maxAbsDiff.toFixed(6)}`);
  console.log(`  Signal/diff:   ${(20 * Math.log10(rmsJs / (rmsDiff + 1e-30))).toFixed(2)} dB`);
  e.free_state(sp);
})();
