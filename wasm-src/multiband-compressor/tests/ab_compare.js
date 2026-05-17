#!/usr/bin/env node
// Compare the JS-only multiband-compressor processor against the WASM one.
// Runs N blocks of identical input through both and prints per-block / cumulative
// RMS error in dBFS so we can confirm the WASM port is sonically equivalent.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const pluginPath = path.join(repoRoot, 'plugins', 'dynamics', 'multiband_compressor.js');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'multiband_compressor.wasm');

// --- 1. Extract the processor body string from the JS plugin without running
//        the surrounding class (which expects window, PluginBase, etc.).

const src = fs.readFileSync(pluginPath, 'utf8');
const start = src.indexOf("getProcessorCode() {");
const tplStart = src.indexOf('return `', start) + 'return `'.length;
const tplEnd = src.indexOf('`;', tplStart);
if (tplStart < 0 || tplEnd < 0) {
  console.error('Could not extract processor template literal');
  process.exit(1);
}
const processorBody = src.slice(tplStart, tplEnd);

// Strip the WASM-fast-path block (we want to run the JS implementation only).
const wasmBlockStart = processorBody.indexOf('// --- WebAssembly fast path');
const wasmBlockEnd = processorBody.indexOf('// --- State Initialization');
let jsOnlyBody;
if (wasmBlockStart >= 0 && wasmBlockEnd > wasmBlockStart) {
  jsOnlyBody = processorBody.slice(0, wasmBlockStart) + processorBody.slice(wasmBlockEnd);
} else {
  jsOnlyBody = processorBody;
}

const sandbox = { Math, Float32Array, Number, console, Array };
vm.createContext(sandbox);

function runJsProcessor(context, data, parameters, time) {
  sandbox.context = context;
  sandbox.data = data;
  sandbox.parameters = parameters;
  sandbox.time = time;
  return vm.runInContext(`(function(){ ${jsOnlyBody}\nreturn data; })()`, sandbox);
}

// --- 2. Build a parameter set + input.

const SR = 48000;
const BLOCK = 128;
const CHANS = 2;
const BLOCKS = 200; // ~0.5 s of audio
const SAMPLES = CHANS * BLOCK;

const params = {
  enabled: true,
  blockSize: BLOCK,
  sampleRate: SR,
  channelCount: CHANS,
  time: 0,
  f1: 100, f2: 500, f3: 2000, f4: 8000,
  bands: [
    { t: -20, r: 4,   a: 30,  rl: 150, k: 6, g: -1,  gr: 0 },
    { t: -22, r: 3,   a: 20,  rl: 120, k: 4, g: 0,   gr: 0 },
    { t: -25, r: 2.5, a: 15,  rl: 80,  k: 4, g: 1,   gr: 0 },
    { t: -28, r: 2,   a: 10,  rl: 60,  k: 3, g: 1.5, gr: 0 },
    { t: -18, r: 5,   a: 5,   rl: 40,  k: 2, g: -2,  gr: 0 }
  ]
};

function fillInput(buf, blockIndex) {
  for (let i = 0; i < BLOCK; i++) {
    const n = blockIndex * BLOCK + i;
    const t = n / SR;
    const sample = 0.4 * Math.sin(2 * Math.PI * 1000 * t)
                 + 0.2 * Math.sin(2 * Math.PI * 60 * t)
                 + 0.1 * Math.sin(2 * Math.PI * 9000 * t);
    buf[i] = sample;
    buf[BLOCK + i] = sample * 0.95;
  }
}

// --- 3. Run JS processor.

const jsCtx = {};
const jsOutputs = [];
for (let blk = 0; blk < BLOCKS; blk++) {
  const data = new Float32Array(SAMPLES);
  fillInput(data, blk);
  params.time = (blk * BLOCK) / SR;
  const out = runJsProcessor(jsCtx, data, params, params.time);
  jsOutputs.push(new Float32Array(out));
}

// --- 4. Run WASM processor.

const wasmBuf = fs.readFileSync(wasmPath);

(async () => {
  const mod = await WebAssembly.compile(wasmBuf);
  const inst = new WebAssembly.Instance(mod);
  const e = inst.exports;
  const sp = e.init(SR, CHANS, BLOCK, params.f1, params.f2, params.f3, params.f4);
  for (let b = 0; b < 5; b++) {
    const bp = params.bands[b];
    e.set_band_params(sp, b, bp.t, bp.r, bp.a, bp.rl, bp.k, bp.g);
  }

  let sumSqDiff = 0;
  let sumSqJs = 0;
  let maxAbsDiff = 0;

  for (let blk = 0; blk < BLOCKS; blk++) {
    const data = new Float32Array(SAMPLES);
    fillInput(data, blk);

    const inView = new Float32Array(e.memory.buffer, e.input_ptr(sp), SAMPLES);
    inView.set(data);
    e.process_block(sp, BLOCK);
    const outView = new Float32Array(e.memory.buffer, e.output_ptr(sp), SAMPLES);

    const wOut = new Float32Array(outView);
    const jOut = jsOutputs[blk];

    for (let i = 0; i < SAMPLES; i++) {
      const d = wOut[i] - jOut[i];
      sumSqDiff += d * d;
      sumSqJs += jOut[i] * jOut[i];
      if (Math.abs(d) > maxAbsDiff) maxAbsDiff = Math.abs(d);
    }

    let blkSqDiff = 0, blkSqJs = 0, blkMax = 0;
    for (let i = 0; i < SAMPLES; i++) {
      const d = wOut[i] - jOut[i];
      blkSqDiff += d * d;
      blkSqJs += jOut[i] * jOut[i];
      if (Math.abs(d) > blkMax) blkMax = Math.abs(d);
    }
    if (blk < 5 || blk === BLOCKS - 1) {
      const blkRms = Math.sqrt(blkSqDiff / SAMPLES);
      const blkSig = Math.sqrt(blkSqJs / SAMPLES);
      console.log(`block ${blk}: rms_diff=${blkRms.toFixed(6)} max_diff=${blkMax.toFixed(6)} sig_rms=${blkSig.toFixed(6)}`);
    }
  }

  const rmsDiff = Math.sqrt(sumSqDiff / (BLOCKS * SAMPLES));
  const rmsJs = Math.sqrt(sumSqJs / (BLOCKS * SAMPLES));
  const diffDbfs = 20 * Math.log10(rmsDiff + 1e-30);
  const sigDbfs = 20 * Math.log10(rmsJs + 1e-30);
  const sndr = sigDbfs - diffDbfs;

  console.log(`\nProcessed ${BLOCKS} blocks @ ${SR} Hz, ${CHANS} ch, ${BLOCK} samples/block.`);
  console.log(`  JS RMS:        ${rmsJs.toFixed(6)} (${sigDbfs.toFixed(2)} dBFS)`);
  console.log(`  Diff RMS:      ${rmsDiff.toFixed(6)} (${diffDbfs.toFixed(2)} dBFS)`);
  console.log(`  Max abs diff:  ${maxAbsDiff.toFixed(6)}`);
  console.log(`  Signal/diff:   ${sndr.toFixed(2)} dB`);

  e.free_state(sp);
})();
