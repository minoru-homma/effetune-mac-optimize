#!/usr/bin/env node
// Compare JS-only Spectrum Analyzer FFT path vs WASM port.
// Synthesises a windowed FFT directly from the JS class methods, side-by-side
// with the WASM analyze() output.

const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const wasmPath = path.join(repoRoot, 'plugins', 'wasm', 'spectrum_analyzer.wasm');

// Replicate the JS reference algorithm verbatim (no canvas / DOM bits).
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
        this.correctionAC = 10 * Math.log10(16);
        this.correctionDC = 10 * Math.log10(4);
        this.spectrum = new Float32Array(fftSize >> 1).fill(-144);
        this.peaks = new Float32Array(fftSize >> 1).fill(-145);
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
    analyze(averageBuffer, bufferPosition) {
        const fftSize = this.fftSize;
        const halfFft = fftSize >> 1;
        this.imag.fill(0);
        let pos = bufferPosition % fftSize;
        for (let i = 0; i < fftSize; i++) {
            this.real[i] = averageBuffer[pos] * this.window[i];
            pos++; if (pos >= fftSize) pos = 0;
        }
        this.fft(this.real, this.imag);
        for (let i = 0; i < halfFft; i++) {
            const rawPower = this.real[i] * this.real[i] + this.imag[i] * this.imag[i];
            const corr = i === 0 ? this.correctionDC : this.correctionAC;
            this.spectrum[i] = 10 * Math.log10(rawPower + 1e-24) + corr;
        }
    }
}

(async () => {
    const PT = 12;
    const FFT = 1 << PT;
    const HALF = FFT >> 1;
    const SR = 96000;

    // Test signal: 1 kHz sine + sub component, half-buffer fill
    const buf = new Float32Array(FFT);
    for (let i = 0; i < FFT; i++) {
        const t = i / SR;
        buf[i] = 0.5 * Math.sin(2 * Math.PI * 1000 * t)
               + 0.2 * Math.sin(2 * Math.PI * 80 * t);
    }
    const bufferPosition = (FFT >> 1) | 0; // simulate half-filled circular buffer

    const js = new JsRef(PT);
    js.analyze(buf, bufferPosition);

    const mod = await WebAssembly.compile(fs.readFileSync(wasmPath));
    const inst = new WebAssembly.Instance(mod);
    const e = inst.exports;
    const sp = e.init(PT);
    new Float32Array(e.memory.buffer, e.input_ptr(sp), FFT).set(buf);
    e.analyze(sp, bufferPosition);
    const wasmSpec = new Float32Array(
        new Float32Array(e.memory.buffer, e.spectrum_ptr(sp), HALF)
    );

    let sumSqDiff = 0, sumSqJs = 0, maxAbsDiff = 0, maxIdx = -1;
    for (let i = 0; i < HALF; i++) {
        const d = wasmSpec[i] - js.spectrum[i];
        sumSqDiff += d * d;
        sumSqJs += js.spectrum[i] * js.spectrum[i];
        if (Math.abs(d) > maxAbsDiff) { maxAbsDiff = Math.abs(d); maxIdx = i; }
    }
    const rmsDiff = Math.sqrt(sumSqDiff / HALF);
    console.log(`FFT size: ${FFT}, HALF: ${HALF}`);
    console.log(`Spectrum diff RMS:  ${rmsDiff.toFixed(6)} dB`);
    console.log(`Max abs diff:       ${maxAbsDiff.toFixed(6)} dB at bin ${maxIdx}`);
    console.log(`JS bin@~1kHz: ${js.spectrum[Math.round(1000 / SR * FFT)].toFixed(2)} dB`);
    console.log(`WASM bin@~1kHz: ${wasmSpec[Math.round(1000 / SR * FFT)].toFixed(2)} dB`);
    e.free_state(sp);
})();
