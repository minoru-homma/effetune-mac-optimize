#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const wasmPath = path.resolve(__dirname, '..', '..', '..', 'plugins', 'wasm', 'spectrum_analyzer.wasm');

class JsRef {
    constructor(pt) {
        this.pt = pt;
        const fftSize = 1 << pt;
        this.fftSize = fftSize;
        this.real = new Float32Array(fftSize);
        this.imag = new Float32Array(fftSize);
        this.window = new Float32Array(fftSize);
        this.sinTable = new Float32Array(fftSize);
        this.cosTable = new Float32Array(fftSize);
        const factor = 2 * Math.PI / fftSize;
        for (let i = 0; i < fftSize; i++) {
            const t = factor * i;
            this.sinTable[i] = -Math.sin(t);
            this.cosTable[i] = Math.cos(t);
            this.window[i] = 0.5 * (1 - Math.cos(t));
        }
        this.spectrum = new Float32Array(fftSize >> 1);
    }
    reverseBits(x) {
        let result = 0;
        for (let i = 0; i < this.pt; i++) {
            result = (result << 1) | (x & 1);
            x >>= 1;
        }
        return result;
    }
    fft(real, imag) {
        const n = real.length;
        for (let i = 0; i < n; i++) {
            const j = this.reverseBits(i);
            if (j > i) {
                [real[i], real[j]] = [real[j], real[i]];
                [imag[i], imag[j]] = [imag[j], imag[i]];
            }
        }
        for (let stage = 1, size = 2; size <= n; stage++, size <<= 1) {
            const halfSize = size >> 1;
            const shift = this.pt - stage;
            for (let i = 0; i < n; i += size) {
                for (let j = i, k = 0; j < i + halfSize; j++, k++) {
                    const tableIndex = (k << shift) & (n - 1);
                    const cos = this.cosTable[tableIndex];
                    const sin = this.sinTable[tableIndex];
                    const tr = real[j + halfSize] * cos - imag[j + halfSize] * sin;
                    const ti = real[j + halfSize] * sin + imag[j + halfSize] * cos;
                    real[j + halfSize] = (real[j] - tr) * 0.5;
                    imag[j + halfSize] = (imag[j] - ti) * 0.5;
                    real[j] = (real[j] + tr) * 0.5;
                    imag[j] = (imag[j] + ti) * 0.5;
                }
            }
        }
    }
    analyze(buf, bp) {
        const n = this.fftSize, half = n >> 1;
        this.imag.fill(0);
        let pos = bp % n;
        for (let i = 0; i < n; i++) {
            this.real[i] = buf[pos] * this.window[i];
            pos++; if (pos >= n) pos = 0;
        }
        this.fft(this.real, this.imag);
        for (let i = 0; i < half; i++) {
            const rp = this.real[i] * this.real[i] + this.imag[i] * this.imag[i];
            const corr = i === 0 ? 6.020 : 12.041;
            this.spectrum[i] = 10 * Math.log10(rp + 1e-24) + corr;
        }
    }
}

(async () => {
    const PT = 12;
    const FFT = 1 << PT;
    const SR = 96000;
    const ITERS = 5000;

    const buf = new Float32Array(FFT);
    for (let i = 0; i < FFT; i++) {
        const t = i / SR;
        buf[i] = 0.5 * Math.sin(2 * Math.PI * 1000 * t) + 0.2 * Math.sin(2 * Math.PI * 80 * t);
    }

    const js = new JsRef(PT);
    for (let i = 0; i < 50; i++) js.analyze(buf, 0);
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < ITERS; i++) js.analyze(buf, 0);
    const t1 = process.hrtime.bigint();
    const jsMs = Number(t1 - t0) / 1e6;

    const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
    const inst = new WebAssembly.Instance(mod);
    const e = inst.exports;
    const sp = e.init(PT);
    const inPtr = e.input_ptr(sp);
    new Float32Array(e.memory.buffer, inPtr, FFT).set(buf);
    for (let i = 0; i < 50; i++) e.analyze(sp, 0);
    const t2 = process.hrtime.bigint();
    for (let i = 0; i < ITERS; i++) e.analyze(sp, 0);
    const t3 = process.hrtime.bigint();
    const wasmMs = Number(t3 - t2) / 1e6;

    console.log(`FFT size: ${FFT}, iterations: ${ITERS}`);
    console.log(`JS:    ${jsMs.toFixed(1)} ms total, ${(jsMs / ITERS * 1000).toFixed(2)} us/FFT`);
    console.log(`WASM:  ${wasmMs.toFixed(1)} ms total, ${(wasmMs / ITERS * 1000).toFixed(2)} us/FFT`);
    console.log(`Speedup: ${(jsMs / wasmMs).toFixed(2)}x`);
    e.free_state(sp);
})();
