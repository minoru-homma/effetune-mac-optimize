#!/usr/bin/env node
// A/B compare the JS-only Brickwall Limiter against the WASM port.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'dynamics', 'brickwall_limiter.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'brickwall_limiter.wasm');

// Extract the registerProcessor template literal body.
const src = fs.readFileSync(pluginPath, 'utf8');
const start = src.indexOf("this.registerProcessor(`") + "this.registerProcessor(`".length;
let end = -1;
for (let i = start; i < src.length - 1; i++) {
  if (src[i] === '`' && src[i + 1] === ')' && src[i - 1] !== '\\') { end = i; break; }
}
let body = src.slice(start, end).replace(/\\`/g, '`').replace(/\\\$/g, '$');
// Strip the WASM fast-path block so we exercise the pure JS path here.
const wasmStart = body.indexOf('// --- WebAssembly fast path');
if (wasmStart >= 0) {
  let scan = body.indexOf('if (context.wasmModule', wasmStart);
  let openBrace = body.indexOf('{', scan);
  let i = openBrace + 1;
  let depth = 1;
  while (i < body.length && depth > 0) {
    if (body[i] === '{') depth++;
    else if (body[i] === '}') depth--;
    i++;
  }
  body = body.slice(0, wasmStart) + body.slice(i);
}

const sandbox = { Math, Float32Array, Float64Array, Number, Array, console };
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
const OS = 4; // user's setting

const params = {
  enabled: true, blockSize: BLOCK, sampleRate: SR, channelCount: CHANS, time: 0,
  th: -1, rl: 100, la: 3, os: OS, ig: 0, sm: -0.5
};

// Generate hot-loud signal that will trigger the limiter.
function fillInput(buf, blkIdx) {
  for (let i = 0; i < BLOCK; i++) {
    const n = blkIdx * BLOCK + i;
    const t = n / SR;
    // 1 kHz sine pumping at 0.95 amplitude (above threshold).
    const v = 0.95 * Math.sin(2 * Math.PI * 1000 * t);
    buf[i] = v;
    buf[BLOCK + i] = v * 0.99;
  }
}

const jsCtx = {};
const jsOutputs = [];
for (let blk = 0; blk < BLOCKS; blk++) {
  const data = new Float32Array(SAMPLES);
  fillInput(data, blk);
  params.time = (blk * BLOCK) / SR;
  const out = jsRun(jsCtx, data, params, params.time);
  jsOutputs.push(new Float32Array(out));
}

(async () => {
  const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK, OS);
  e.set_params(sp, params.th, params.rl, params.la, params.ig, params.sm);

  let sumSqDiff = 0, sumSqJs = 0, maxAbsDiff = 0;
  for (let blk = 0; blk < BLOCKS; blk++) {
    const data = new Float32Array(SAMPLES);
    fillInput(data, blk);
    const inView = new Float32Array(e.memory.buffer, e.input_ptr(sp), SAMPLES);
    inView.set(data);
    e.process_block(sp, BLOCK);
    const outView = new Float32Array(e.memory.buffer, e.output_ptr(sp), SAMPLES);
    const wOut = new Float32Array(outView);
    const jOut = jsOutputs[blk];
    let blkSqDiff = 0, blkMax = 0;
    for (let i = 0; i < SAMPLES; i++) {
      const d = wOut[i] - jOut[i];
      sumSqDiff += d * d;
      blkSqDiff += d * d;
      sumSqJs += jOut[i] * jOut[i];
      const ad = Math.abs(d);
      if (ad > blkMax) blkMax = ad;
      if (ad > maxAbsDiff) maxAbsDiff = ad;
    }
    if (blk < 4 || blk === BLOCKS - 1) {
      console.log(`block ${blk}: rms_diff=${Math.sqrt(blkSqDiff / SAMPLES).toFixed(7)} max=${blkMax.toFixed(6)}`);
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
