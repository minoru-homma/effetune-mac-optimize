class SpectrumAnalyzerPlugin extends PluginBase {
    constructor() {
        super('Spectrum Analyzer', 'Real-time spectrum analyzer with peak hold');
        
        // Initialize parameters
        this.dr = -96;
        this.pt = 12;
        const fftSize = 1 << this.pt; // Using bit shift for power of 2
        this.spectrum = new Float32Array(fftSize >> 1).fill(-144);
        this.peaks = new Float32Array(fftSize >> 1).fill(-144);
        this.lastProcessTime = performance.now() / 1000;
        this.sampleRate = 48000; // Default, updated from processor messages

        // dB correction factors for 0dBFS scaling (assuming 1/N FFT normalization & Hann window)
        this.correctionAC = 10 * Math.log10(16); // For AC components (approx. +12.04dB)
        this.correctionDC = 10 * Math.log10(4);  // For DC component (approx. +6.02dB)

        // Initialize FFT buffers and tables
        this.real = new Float32Array(fftSize);
        this.imag = new Float32Array(fftSize);
        this.window = new Float32Array(fftSize);
        this.sinTable = new Float32Array(fftSize);
        this.cosTable = new Float32Array(fftSize);

        // Combined loop: Initialize sin/cos tables for FFT and Hann window
        const factor = 2 * Math.PI / fftSize;
        for (let i = 0; i < fftSize; i++) {
            const t = factor * i;
            this.sinTable[i] = -Math.sin(t); // sin(-t)
            this.cosTable[i] = Math.cos(t);
            this.window[i] = 0.5 * (1 - Math.cos(t));
        }

        // Store event listeners for cleanup
        this.boundEventListeners = new Map();

        // Register processor function
        this.registerProcessor(SpectrumAnalyzerPlugin.processorFunction);
        this.observer = null;

        // Main-thread WASM instance for FFT + magnitude + peak hold.
        // The processor (worklet) part is just buffering; the heavy work is in
        // process(message) below, which runs on the main thread when each
        // half-FFT-sized chunk arrives.
        this._wasm = null;
        this._wasmPt = 0;
        this._loadWasmModule();

        // WebGPU renderer (replaces drawGraph's Canvas 2D path when available).
        // Loaded asynchronously; until ready (or if it fails), drawGraph()
        // continues to use the Canvas 2D fallback below.
        this._gpu = null;
        this._gpuPending = false;
        this._gpuDisabled = SpectrumAnalyzerPlugin._readGpuFlag() === false;
        this._loadGpuRenderer();
    }

    static _readGpuFlag() {
        // ?gpu=0 forces fallback for A/B testing; ?gpu=1 (or absent) tries GPU.
        try {
            if (typeof window === 'undefined' || !window.location) return null;
            const v = new URLSearchParams(window.location.search).get('gpu');
            if (v === '0') return false;
            if (v === '1') return true;
            return null;
        } catch (_) {
            return null;
        }
    }

    static processorFunction = `
        // Reuse result buffer from context
        let result = context.resultBuffer;
        if (!result || result.length !== data.length) {
            result = new Float32Array(data.length);
            context.resultBuffer = result;
        }
        result.set(data);

        const { channelCount, blockSize, pt } = parameters; // Removed ch
        const fftSize = 1 << pt; // Using bit shift for power of 2
        
        // Initialize context if needed - Modified for single average buffer
        if (!context.initialized || context.fftSize !== fftSize || !context.buffer) { // Check if buffer exists
            context.buffer = [new Float32Array(fftSize)]; // Single buffer in an array
            context.bufferPosition = 0;
            context.fftSize = fftSize;
            context.initialized = true;
        }

        // --- Process input data: Calculate average and write to single buffer ---
        const averageBuffer = context.buffer[0]; // Target the single buffer
        let bufferPosition = context.bufferPosition;
        for (let i = 0; i < blockSize; i++) {
            const leftSample = data[i] || 0; // Get Left sample (or 0 if undefined)
            const rightSample = channelCount > 1 ? data[blockSize + i] : leftSample; // Get Right sample (or use Left if mono)
            const averageSample = (leftSample + rightSample) * 0.5; // Calculate arithmetic average
            averageBuffer[bufferPosition] = averageSample; // Write average to buffer[0]
            bufferPosition = (bufferPosition + 1) & (fftSize - 1);
        }
        context.bufferPosition = bufferPosition; // Update position

        // Send buffer to UI every half FFT size
        if (context.bufferPosition % (fftSize / 2) === 0) {
            result.measurements = {
                buffer: [Float32Array.from(context.buffer[0])], // Send copy of average buffer in array
                bufferPosition: context.bufferPosition,
                time: time,
                sampleRate: parameters.sampleRate 
            };
        }

        return result;
    `;

    // FFT implementation
    fft(real, imag) {
        const n = real.length;
        
        // Bit reversal
        for (let i = 0; i < n; i++) {
            const j = this.reverseBits(i);
            if (j > i) {
                [real[i], real[j]] = [real[j], real[i]];
                [imag[i], imag[j]] = [imag[j], imag[i]];
            }
        }

        // FFT
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

    reverseBits(x) {
        let result = 0;
        const bits = this.pt;
        for (let i = 0; i < bits; i++) {
            result = (result << 1) | (x & 1);
            x >>= 1;
        }
        return result;
    }

    // Parameter setters
    setDBRange(value) {
        const val = typeof value === 'number' ? value : parseFloat(value);
        this.dr = val < -144 ? -144 : (val > -48 ? -48 : val);
        this.updateParameters();
        if (this._gpu) {
            this._gpuConfigureNow();
            if (typeof this._drawStaticOverlay === 'function') this._drawStaticOverlay();
        }
    }

    setPoints(value) {
        const parsedValue = typeof value === 'number' ? value : parseFloat(value);
        const newPoints = parsedValue < 8 ? 8 : (parsedValue > 14 ? 14 : parsedValue);
        if (newPoints === this.pt) return;
        
        this.pt = newPoints; // Update pt first
        const fftSize = 1 << newPoints;
        
        this.spectrum = new Float32Array(fftSize >> 1).fill(-144);
        this.peaks = new Float32Array(fftSize >> 1).fill(-144);
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
        
        this.lastProcessTime = performance.now() / 1000;
        this.updateParameters();
        if (this._gpu) {
            this._gpuConfigureNow();
            if (typeof this._drawStaticOverlay === 'function') this._drawStaticOverlay();
        }
    }

    // Reset parameters
    reset() {
        this.setDBRange(-96);
        this.setPoints(12); // Note: constructor uses 12, reset button might use 10. Keeping 12 here.
    }

    getParameters() {
        return {
            type: this.constructor.name,
            enabled: this.enabled,
            dr: this.dr,
            pt: this.pt
        };
    }

    setParameters(params) {
        if (params.enabled !== undefined) this.enabled = params.enabled;
        if (params.dr !== undefined) this.setDBRange(params.dr);
        if (params.pt !== undefined) this.setPoints(params.pt);
        this.updateParameters();
    }

    onMessage(message) {
        if (message.type === 'processBuffer') {
            this.process(message);
        }
    }

    process(message) {
        if (!message?.measurements?.buffer) {
            return;
        }

        if (!this.enabled) {
            return;
        }

        const fftSize = 1 << this.pt;
        const halfFft = fftSize >> 1;
        const bufferPosition = message.measurements.bufferPosition;
        const [averageBuffer] = message.measurements.buffer;

        if (!averageBuffer || fftSize !== averageBuffer.length) return;

        // Update sampleRate if it has changed
        if (message.measurements.sampleRate && this.sampleRate !== message.measurements.sampleRate) {
            this.sampleRate = message.measurements.sampleRate;
        }

        const currentTime = message.measurements.time;
        const deltaTime = this.lastProcessTime < currentTime ? currentTime - this.lastProcessTime : 0.02;
        const decay = 20 * deltaTime;

        // --- WebAssembly fast path -------------------------------------------------
        // Lazily (re)create the WASM instance for the current FFT size.
        if (this._wasmModule && this._wasmPt !== this.pt) {
            try {
                // free_state lives on the Instance exports (this._wasm.ex),
                // NOT on the WebAssembly.Module — `this._wasmModule.exports`
                // is always undefined, so the old form never freed anything
                // and leaked the previous instance's linear memory.
                if (this._wasm && this._wasm.ex) this._wasm.ex.free_state?.(this._wasm.sp);
            } catch (_) { /* ignore */ }
            this._wasm = null;
        }
        if (this._wasmModule && !this._wasm) {
            try {
                const inst = new WebAssembly.Instance(this._wasmModule);
                const ex = inst.exports;
                const sp = ex.init(this.pt);
                this._wasm = { ex, memory: ex.memory, sp };
                this._wasmPt = this.pt;
                // Seed peaks with current JS values so the visual is continuous.
                const peaksView = new Float32Array(ex.memory.buffer, ex.peaks_ptr(sp), halfFft);
                peaksView.set(this.peaks.subarray(0, halfFft));
                const msg = 'WASM instance active (fftSize=' + fftSize + ' sr=' + this.sampleRate + ')';
                console.log('[SpectrumAnalyzer]', msg);
                if (window.electronAPI && window.electronAPI.logToMain) {
                    window.electronAPI.logToMain('info', 'SpectrumAnalyzer', msg);
                }
            } catch (err) {
                console.warn('[SpectrumAnalyzer] WASM instance failed:', err.message);
                this._wasmModule = null; // disable
            }
        }

        if (this._wasm) {
            try {
                const w = this._wasm;
                // Refresh views every call (memory.grow detaches old views).
                new Float32Array(w.memory.buffer, w.ex.input_ptr(w.sp), fftSize)
                    .set(averageBuffer);
                w.ex.analyze(w.sp, bufferPosition >>> 0);
                w.ex.update_peaks(w.sp, decay);
                // Refresh views post-call to be safe against memory growth.
                const specView = new Float32Array(w.memory.buffer, w.ex.spectrum_ptr(w.sp), halfFft);
                const peaksView = new Float32Array(w.memory.buffer, w.ex.peaks_ptr(w.sp), halfFft);
                this.spectrum.set(specView);
                if (!this.peaks || this.peaks.length !== halfFft) {
                    this.peaks = new Float32Array(halfFft);
                }
                this.peaks.set(peaksView);
                this.lastProcessTime = currentTime;
                return;
            } catch (err) {
                console.warn('[SpectrumAnalyzer] WASM error, falling back to JS:', err.message);
                this._wasm = null;
                this._wasmModule = null;
                // fall through to JS path
            }
        }

        // --- JS fallback path ----------------------------------------------------
        this.imag.fill(0);
        let pos = bufferPosition % fftSize;
        for (let i = 0; i < fftSize; i++) {
            let sample = averageBuffer[pos];
            this.real[i] = sample * this.window[i];
            pos++;
            if (pos >= fftSize) pos = 0;
        }

        this.fft(this.real, this.imag);

        for (let i = 0; i < halfFft; i++) {
            const rawPower = this.real[i] * this.real[i] + this.imag[i] * this.imag[i];
            const currentCorrection = i === 0 ? this.correctionDC : this.correctionAC;
            this.spectrum[i] = 10 * Math.log10(rawPower + 1e-24) + currentCorrection;
        }

        if (!this.peaks || this.peaks.length !== halfFft) {
            this.peaks = new Float32Array(halfFft).fill(-145);
        }

        for (let i = 0; i < halfFft; i++) {
            if (isNaN(this.peaks[i]) || this.peaks[i] < -145 || this.peaks[i] > 0) {
                this.peaks[i] = -145;
            }
            const decayedPeak = this.peaks[i] - decay;
            const newPeak = this.spectrum[i] > decayedPeak ? this.spectrum[i] : decayedPeak;
            this.peaks[i] = newPeak < -145 ? -145 : newPeak > 0 ? 0 : newPeak;
        }
        this.lastProcessTime = currentTime;
    }

    _loadWasmModule() {
        if (typeof window === 'undefined' || typeof WebAssembly === 'undefined') return;
        try {
            const currentPath = window.location.pathname;
            const basePath = currentPath.substring(0, currentPath.lastIndexOf('/'));
            const url = `${basePath}/plugins/wasm/spectrum_analyzer.wasm`;
            fetch(url)
                .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.arrayBuffer(); })
                .then(buf => WebAssembly.compile(buf))
                .then(mod => {
                    this._wasmModule = mod;
                    const msg = 'WASM compiled (FFT + magnitude + peak-hold).';
                    console.log('[SpectrumAnalyzer]', msg);
                    if (window.electronAPI && window.electronAPI.logToMain) {
                        window.electronAPI.logToMain('info', 'SpectrumAnalyzer', msg);
                    }
                })
                .catch(err => {
                    const msg = 'WASM unavailable, using JS path: ' + err.message;
                    console.warn('[SpectrumAnalyzer]', msg);
                    if (window.electronAPI && window.electronAPI.logToMain) {
                        window.electronAPI.logToMain('warn', 'SpectrumAnalyzer', msg);
                    }
                });
        } catch (err) {
            console.warn('[SpectrumAnalyzer] WASM load skipped:', err.message);
        }
    }

    _loadGpuRenderer() {
        if (this._gpuDisabled) return;
        if (typeof window === 'undefined') return;

        // Already loaded by an earlier plugin instance?
        if (window.SpectrumAnalyzerGpuRenderer) {
            this._gpuLoadPromise = Promise.resolve(true);
            return;
        }
        // Already in flight from an earlier instance?
        if (window.__spectrumGpuLoadPromise) {
            this._gpuLoadPromise = window.__spectrumGpuLoadPromise;
            return;
        }
        try {
            const currentPath = window.location.pathname;
            const basePath = currentPath.substring(0, currentPath.lastIndexOf('/'));
            const url = `${basePath}/plugins/analyzer/spectrum_analyzer_gpu.js`;
            const script = document.createElement('script');
            script.src = url;
            script.async = true;
            const promise = new Promise((resolve) => {
                script.onload = () => {
                    const ok = !!window.SpectrumAnalyzerGpuRenderer;
                    if (window.electronAPI && window.electronAPI.logToMain) {
                        window.electronAPI.logToMain('info', 'SpectrumAnalyzer',
                            'GPU renderer script loaded (defined=' + ok + ')');
                    }
                    resolve(ok);
                };
                script.onerror = () => {
                    const msg = 'GPU renderer script failed to load';
                    console.warn('[SpectrumAnalyzer]', msg);
                    if (window.electronAPI && window.electronAPI.logToMain) {
                        window.electronAPI.logToMain('warn', 'SpectrumAnalyzer', msg);
                    }
                    resolve(false);
                };
            });
            window.__spectrumGpuLoadPromise = promise;
            this._gpuLoadPromise = promise;
            document.head.appendChild(script);
        } catch (err) {
            console.warn('[SpectrumAnalyzer] GPU script inject skipped:', err.message);
            this._gpuLoadPromise = Promise.resolve(false);
        }
    }

    _gpuConfigureNow() {
        if (!this._gpu) return;
        const fftSize = 1 << this.pt;
        const minDisplayFreq = 20;
        const maxDisplayFreq = 40000;
        this._gpu.configure({
            pt: this.pt,
            sampleRate: this.sampleRate,
            dr: this.dr,
            minFreq: minDisplayFreq,
            maxFreq: maxDisplayFreq,
            fftSize
        });
    }

    // Toggle the dedicated WebGPU canvas (and its stacked text-label overlay)
    // on/off. Hiding them reveals the always-valid Canvas 2D base canvas
    // underneath — which WebGPU never claimed, so getContext('2d') keeps
    // working even after a WebGPU failure or device loss.
    _setGpuLayerVisible(visible) {
        const disp = visible ? 'block' : 'none';
        if (this.gpuCanvas) this.gpuCanvas.style.display = disp;
        if (this.labelCanvas) this.labelCanvas.style.display = disp;
    }

    // Recover from an unexpected WebGPU device loss (GPU process recycle,
    // sleep/wake, driver update, GC) by re-initialising the renderer on the
    // same canvas with a fresh adapter/device.  Without this the shared canvas
    // stays claimed by the dead webgpu context and the Canvas 2D fallback
    // cannot draw, leaving the analyzer permanently black until app restart.
    _handleGpuDeviceLost(reason) {
        const gpuLogToMain = (level, text) => {
            if (typeof window !== 'undefined' && window.electronAPI && window.electronAPI.logToMain) {
                window.electronAPI.logToMain(level, 'SpectrumAnalyzer', text);
            }
        };
        if (this._gpuReinitInProgress) return;
        // Count *consecutive* failed re-init attempts. The streak is reset to
        // 0 on a successful recovery (below), so routine device losses spread
        // across the app's lifetime (sleep/wake, driver update, GPU process
        // recycle) never exhaust the cap — only a tight, genuinely
        // unrecoverable loss loop does.
        this._gpuReinitConsecutiveFailures = (this._gpuReinitConsecutiveFailures || 0) + 1;
        // Lifetime backstop (never reset on success): a flaky *real* GPU whose
        // init() succeeds every cycle but loses the device ~1 s later would
        // otherwise reset the consecutive-failure streak each success and
        // re-init forever. Cap total lifetime re-inits so that pathological
        // loop is bounded too, while still allowing many routine sleep/wake
        // losses across a long session.
        this._gpuReinitTotal = (this._gpuReinitTotal || 0) + 1;
        if (this._gpuReinitConsecutiveFailures > 8 || this._gpuReinitTotal > 64) {
            gpuLogToMain('warn', `device lost (${reason}) — giving up WebGPU (consecutive failures=${this._gpuReinitConsecutiveFailures - 1}, lifetime re-inits=${this._gpuReinitTotal - 1})`);
            // Reveal the dedicated, never-poisoned Canvas 2D fallback.
            this._setGpuLayerVisible(false);
            return;
        }
        this._gpuReinitInProgress = true;
        // Drop the dead renderer immediately so drawGraph() does not call
        // render() on it during the async re-init window, and hide the GPU
        // layer so the Canvas 2D fallback draws while we recover.
        const dead = this._gpu;
        this._gpu = null;
        try { if (dead) dead.destroy(); } catch (_) { /* ignore */ }
        this._setGpuLayerVisible(false);
        gpuLogToMain('warn', `device lost (${reason}) — re-initialising WebGPU (attempt ${this._gpuReinitConsecutiveFailures})`);
        // Small delay: the GPU stack is often briefly unstable right after a
        // loss (process recycle / wake), so an immediate retry tends to fail.
        setTimeout(() => {
            if (this._gpuDisabled || typeof window === 'undefined' ||
                !this.canvas || !window.SpectrumAnalyzerGpuRenderer ||
                !window.SpectrumAnalyzerGpuRenderer.isSupported()) {
                this._gpuReinitInProgress = false;
                return;
            }
            const renderer = new window.SpectrumAnalyzerGpuRenderer(this.gpuCanvas || this.canvas);
            renderer.init().then((ok) => {
                this._gpuReinitInProgress = false;
                if (!ok) {
                    gpuLogToMain('warn', 'WebGPU re-init returned false');
                    return;
                }
                this._gpu = renderer;
                // Recovered — clear the consecutive-failure streak so the cap
                // only ever trips on a genuinely unrecoverable loss loop.
                this._gpuReinitConsecutiveFailures = 0;
                renderer.onDeviceLost = (r) => this._handleGpuDeviceLost(r);
                this._setGpuLayerVisible(true);
                this._gpuConfigureNow();
                if (typeof this._drawStaticOverlay === 'function') this._drawStaticOverlay();
                try { this.drawGraph(); } catch (_) { /* ignore */ }
                gpuLogToMain('info', 'WebGPU renderer recovered after device loss');
            }).catch((err) => {
                this._gpuReinitInProgress = false;
                gpuLogToMain('warn', 'WebGPU re-init threw: ' + (err && err.message ? err.message : String(err)));
            });
        }, 400);
    }

    // Render axis labels and dB tick text onto the overlay canvas. The grid
    // lines themselves live on the GPU canvas so they stay crisp during
    // animation; this overlay only draws static text and is redrawn solely
    // when sampleRate / dr / pt change.
    _drawStaticOverlay() {
        if (!this.labelCanvas) return;
        const ctx = this.labelCanvas.getContext('2d');
        if (!ctx) return;
        const width = this.labelCanvas.width;
        const height = this.labelCanvas.height;
        ctx.clearRect(0, 0, width, height);

        const minDisplayFreq = 20;
        const maxDisplayFreq = 40000;
        const logMin = Math.log10(minDisplayFreq);
        const logMax = Math.log10(maxDisplayFreq);
        const logRange = logMax - logMin;
        if (logRange <= 0) return;

        ctx.font = '24px Arial';
        ctx.fillStyle = '#ccc';

        // Frequency labels
        ctx.textAlign = 'center';
        const baseGridFreqs = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
        let freqs = baseGridFreqs.filter(f => f >= minDisplayFreq && f <= maxDisplayFreq);
        if (!freqs.includes(maxDisplayFreq)) freqs.push(maxDisplayFreq);
        freqs = [...new Set(freqs)].sort((a, b) => a - b);
        for (const f of freqs) {
            const x = width * (Math.log10(f) - logMin) / logRange;
            if (x < width * 0.02 || x > width * 0.98) continue;
            const label = f >= 1000 ? `${f / 1000}k` : `${f}`;
            ctx.fillText(label, x, height - 30);
        }

        // dB labels
        ctx.textAlign = 'right';
        for (let db = 0; db >= this.dr; db -= 12) {
            const y = height * (db / this.dr);
            ctx.fillText(`${db}`, 70, y + 9);
        }

        // Axis titles
        ctx.fillText('Frequency (Hz)', width / 2, height - 4);
        ctx.save();
        ctx.translate(28, height / 2);
        ctx.rotate(-Math.PI / 2);
        ctx.textAlign = 'center';
        ctx.fillText('Level (dB)', 0, 0);
        ctx.restore();
    }

    createUI() {
        if (this.observer) {
            this.observer.disconnect();
        }
        const container = document.createElement('div');
        container.className = 'plugin-parameter-ui';

        container.appendChild(this.createParameterControl(
            'DB Range', -144, -48, 1, this.dr, (v) => this.setDBRange(v), 'dB'
        ));

        const pointsRow = document.createElement('div');
        pointsRow.className = 'parameter-row';
        const pointsLabel = document.createElement('label');
        pointsLabel.textContent = 'Points:';
        pointsLabel.htmlFor = `${this.id}-${this.name}-points-slider`;
        const pointsSlider = document.createElement('input');
        pointsSlider.type = 'range'; pointsSlider.id = `${this.id}-${this.name}-points-slider`; pointsSlider.name = `${this.id}-${this.name}-points-slider`;
        pointsSlider.min = 8; pointsSlider.max = 14; pointsSlider.step = 1; pointsSlider.value = this.pt; pointsSlider.autocomplete = "off";
        const pointsValue = document.createElement('input');
        pointsValue.type = 'number'; pointsValue.id = `${this.id}-${this.name}-points-value`; pointsValue.name = `${this.id}-${this.name}-points-value`;
        pointsValue.value = 1 << this.pt; pointsValue.step = 1; pointsValue.min = 1 << 8; pointsValue.max = 1 << 14; pointsValue.autocomplete = "off";

        const pointsHandler = (e) => {
            const value = parseInt(e.target.value);
            pointsValue.value = 1 << value; // Update text input when slider changes
            this.setPoints(value);
        };
        pointsSlider.addEventListener('input', pointsHandler);
        this.boundEventListeners.set(pointsSlider, pointsHandler);
        
        // Update slider when text input changes
        pointsValue.addEventListener('change', (e) => {
            const numFFTPoints = parseInt(e.target.value);
            const exponent = Math.round(Math.log2(numFFTPoints)); // Allow nearest power of 2
            if (exponent >= 8 && exponent <= 14) {
                pointsSlider.value = exponent;
                pointsValue.value = 1 << exponent; // Ensure value is a power of 2
                this.setPoints(exponent);
            } else {
                 pointsValue.value = 1 << this.pt; // Revert to current if invalid
            }
        });


        pointsRow.appendChild(pointsLabel);
        pointsRow.appendChild(pointsSlider);
        pointsRow.appendChild(pointsValue);
        container.appendChild(pointsRow);

        const graphContainer = document.createElement('div');
        graphContainer.className = 'graph-container';
        graphContainer.style.position = 'relative'; graphContainer.style.width = '1024px'; graphContainer.style.height = '480px';
        
        // Base canvas: ALWAYS the Canvas 2D fallback target. getContext('webgpu')
        // is never called on it, so getContext('2d') keeps working even after a
        // WebGPU failure / device loss — the dedicated gpuCanvas below is what
        // the WebGPU renderer claims instead.
        const canvas = document.createElement('canvas');
        canvas.width = 2048; canvas.height = 960;
        canvas.style.width = '1024px'; canvas.style.height = '480px';
        graphContainer.appendChild(canvas);
        this.canvas = canvas;

        // Dedicated WebGPU canvas, stacked over the 2D canvas. Visible only
        // while a WebGPU renderer is active; hidden (revealing the 2D canvas)
        // whenever WebGPU is unavailable, fails, or is given up after a loss.
        const gpuCanvas = document.createElement('canvas');
        gpuCanvas.width = canvas.width; gpuCanvas.height = canvas.height;
        gpuCanvas.style.width = canvas.style.width;
        gpuCanvas.style.height = canvas.style.height;
        gpuCanvas.style.position = 'absolute';
        gpuCanvas.style.left = '0'; gpuCanvas.style.top = '0';
        gpuCanvas.style.display = 'none';
        graphContainer.appendChild(gpuCanvas);
        this.gpuCanvas = gpuCanvas;

        // Wait for the GPU renderer script to load (it was kicked off in the
        // constructor via _loadGpuRenderer). On macOS it's typically already
        // loaded by the time the user expands the plugin UI, but we wait
        // explicitly to handle the race where UI opens before the script
        // resolves. drawGraph() falls back to Canvas 2D until this resolves.
        const gpuLogToMain = (level, text) => {
            if (typeof window !== 'undefined' && window.electronAPI && window.electronAPI.logToMain) {
                window.electronAPI.logToMain(level, 'SpectrumAnalyzer', text);
            }
        };
        if (this._gpuDisabled) {
            gpuLogToMain('info', 'WebGPU disabled by ?gpu=0 flag, using Canvas 2D');
        } else if (typeof window === 'undefined') {
            // headless / non-browser context — no GPU
        } else if (this._gpu || this._gpuPending) {
            // already initialised or in-flight (createUI may be called twice)
        } else {
            this._gpuPending = true;
            const startInit = () => {
                if (!window.SpectrumAnalyzerGpuRenderer) {
                    this._gpuPending = false;
                    gpuLogToMain('warn', 'GPU renderer class not available after script load');
                    return;
                }
                if (!window.SpectrumAnalyzerGpuRenderer.isSupported()) {
                    this._gpuPending = false;
                    gpuLogToMain('info', 'navigator.gpu unavailable, using Canvas 2D');
                    return;
                }
                const renderer = new window.SpectrumAnalyzerGpuRenderer(gpuCanvas);
                renderer.init().then((ok) => {
                    this._gpuPending = false;
                    if (!ok) {
                        gpuLogToMain('warn', 'GPU init returned false, using Canvas 2D');
                        return;
                    }
                    this._gpu = renderer;
                    this._gpuReinitConsecutiveFailures = 0;
                    renderer.onDeviceLost = (reason) => this._handleGpuDeviceLost(reason);
                    this._gpuConfigureNow();
                    // Label overlay (axis text + dB labels) lives on a sibling
                    // canvas stacked over the GPU one. It is redrawn only when
                    // the parameters that affect its content change.
                    // The CSS rule '.plugin-parameter-ui canvas' applies a
                    // #1a1a1a background to every canvas; we override it here
                    // so the GPU canvas underneath is visible through the
                    // label layer.
                    const label = document.createElement('canvas');
                    label.width = canvas.width; label.height = canvas.height;
                    label.style.width = canvas.style.width;
                    label.style.height = canvas.style.height;
                    label.style.position = 'absolute';
                    label.style.left = '0'; label.style.top = '0';
                    label.style.pointerEvents = 'none';
                    label.style.backgroundColor = 'transparent';
                    graphContainer.appendChild(label);
                    this.labelCanvas = label;
                    // Reveal the GPU layer (gpuCanvas + label) now that the
                    // renderer is live; the 2D base canvas stays underneath.
                    this._setGpuLayerVisible(true);
                    if (typeof this._drawStaticOverlay === 'function') {
                        this._drawStaticOverlay();
                    }
                    const msg = 'WebGPU renderer active';
                    console.log('[SpectrumAnalyzer]', msg);
                    gpuLogToMain('info', msg);
                }).catch((err) => {
                    this._gpuPending = false;
                    gpuLogToMain('warn', 'GPU init threw: ' + (err && err.message ? err.message : String(err)));
                });
            };

            if (window.SpectrumAnalyzerGpuRenderer) {
                startInit();
            } else if (this._gpuLoadPromise) {
                this._gpuLoadPromise.then((loaded) => {
                    if (!loaded) {
                        this._gpuPending = false;
                        return;
                    }
                    startInit();
                });
            } else {
                this._gpuPending = false;
                gpuLogToMain('warn', 'GPU script load not initiated');
            }
        }

        const resetButton = document.createElement('button');
        resetButton.className = 'analyzer-reset-button'; resetButton.textContent = 'Reset';
        const resetHandler = () => {
            const defaultDBRange = -96;
            const defaultPoints = 12; // Reset to 12 as per constructor/reset method
            
            // Update UI elements before calling internal reset
            const dbRangeSlider = container.querySelector(`input[type="range"][min="-144"]`); // Example selector
            if(dbRangeSlider) dbRangeSlider.value = defaultDBRange;
            // Update associated span for dbRangeSlider if you have one.

            pointsSlider.value = defaultPoints;
            pointsValue.value = 1 << defaultPoints;

            this.reset(); // This will call setDBRange and setPoints
        };
        resetButton.addEventListener('click', resetHandler);
        this.boundEventListeners.set(resetButton, resetHandler);
        graphContainer.appendChild(resetButton);
        container.appendChild(graphContainer);

        if (this.observer == null) {
            this.observer = new IntersectionObserver(this.handleIntersect.bind(this));
        }
        this.observer.observe(this.canvas);
        return container;
    }

    handleIntersect(entries) {
        entries.forEach(entry => {
            this.isVisible = entry.isIntersecting;
            if (this.isVisible) {
                this.startAnimation();
            } else {
                this.stopAnimation();
            }
        });
    }

    startAnimation() {
        if (this.animationFrameId) return;
        const animate = () => {
            if (!this.isVisible) {
                this.stopAnimation();
                return;
            }
            this.drawGraph();
            this.animationFrameId = requestAnimationFrame(animate);
        };
        animate();
    }

    stopAnimation() {
        if (this.animationFrameId) {
            cancelAnimationFrame(this.animationFrameId);
            this.animationFrameId = null;
        }
    }

    cleanup() {
        this.stopAnimation(); // Stop animation first
        if (this.observer && this.canvas) { // Check if canvas exists before trying to unobserve
            this.observer.unobserve(this.canvas);
        }
        // Cleanup event listeners
        this.boundEventListeners.forEach((handler, element) => {
            // Determine event type if not stored (assuming 'input' or 'click' primarily)
            // A more robust way is to store {event: 'input', handler: handler}
            element.removeEventListener('input', handler);
            element.removeEventListener('click', handler);
        });
        this.boundEventListeners.clear();
        this.lastProcessTime = performance.now() / 1000;
        // Free the main-thread WASM instance's State so its linear memory is
        // not retained until JS GC. free_state lives on the Instance exports
        // (this._wasm.ex), not the Module.
        if (this._wasm && this._wasm.ex) {
            try { this._wasm.ex.free_state?.(this._wasm.sp); } catch (_) { /* ignore */ }
        }
        this._wasm = null;
        this._wasmPt = 0;
        if (this._gpu) {
            try { this._gpu.destroy(); } catch (_) { /* ignore */ }
            this._gpu = null;
        }
        this._setGpuLayerVisible(false);
    }

    drawGraph() {
        if (!this.canvas) return;

        // GPU path: replaces the entire Canvas 2D draw below. On any error
        // the renderer is destroyed and we fall through to the 2D path,
        // which keeps the visualisation alive for the rest of the session.
        if (this._gpu) {
            try {
                this._gpu.render(this.spectrum, this.peaks);
                return;
            } catch (err) {
                console.warn('[SpectrumAnalyzer] GPU render failed, falling back to Canvas 2D:',
                    err && err.message ? err.message : String(err));
                if (typeof window !== 'undefined' && window.electronAPI && window.electronAPI.logToMain) {
                    window.electronAPI.logToMain('warn', 'SpectrumAnalyzer',
                        'GPU render failed, falling back to Canvas 2D');
                }
                try { this._gpu.destroy(); } catch (_) { /* ignore */ }
                this._gpu = null;
                // The 2D canvas is a SEPARATE element that WebGPU never
                // claimed, so hiding the GPU layer reveals a fully working
                // Canvas 2D surface. Fall through and draw this frame on it.
                this._setGpuLayerVisible(false);
            }
        }

        const ctx = this.canvas.getContext('2d', { alpha: false });
        if (!ctx) return; // 2D unexpectedly unavailable — skip this frame.
        const width = this.canvas.width;
        const height = this.canvas.height;

        ctx.fillStyle = '#000000';
        ctx.fillRect(0, 0, width, height);

        ctx.strokeStyle = '#333';
        ctx.lineWidth = 2;

        // --- Dynamic Frequency Axis Scaling ---
        const minDisplayFreq = 20; // Hz
        const nyquistFreq = this.sampleRate / 2;
        // Max display frequency is Nyquist, but ensure it's at least minDisplayFreq
        let maxDisplayFreq = 40000; // Fixed max display frequency

        if (this.sampleRate <= 0 || nyquistFreq <= minDisplayFreq) { // Not enough range or invalid sampleRate
            ctx.fillStyle = '#fff';
            ctx.font = '28px Arial';
            ctx.textAlign = 'center';
            ctx.fillText('Invalid Sample Rate or Range', width / 2, height / 2);
            return;
        }

        const logMinDisplayFreq = Math.log10(minDisplayFreq);
        const logMaxDisplayFreq = Math.log10(maxDisplayFreq);
        const logFreqRange = logMaxDisplayFreq - logMinDisplayFreq;

        if (logFreqRange <= 0) { // Avoid division by zero or negative log range
             ctx.fillStyle = '#fff'; ctx.font = '28px Arial'; ctx.textAlign = 'center';
             ctx.fillText('Invalid Frequency Range for Log Scale', width / 2, height / 2);
             return;
        }

        // Vertical grid lines (frequency) - Dynamic
        let baseGridFreqs = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]; // Common audio freqs
        // Add Nyquist to the list if it's not too close to another major tick, or for the max label
        // Filter and ensure min/max are present
        let gridFreqsToDraw = baseGridFreqs.filter(f => f >= minDisplayFreq && f <= maxDisplayFreq);
        if (!gridFreqsToDraw.includes(minDisplayFreq) && minDisplayFreq > 0) gridFreqsToDraw.unshift(minDisplayFreq);
        if (!gridFreqsToDraw.includes(maxDisplayFreq)) gridFreqsToDraw.push(maxDisplayFreq);
        gridFreqsToDraw = [...new Set(gridFreqsToDraw)].sort((a, b) => a - b); // Unique & sorted

        gridFreqsToDraw.forEach(freq => {
            const x = width * (Math.log10(freq) - logMinDisplayFreq) / logFreqRange;
            if (x >=0 && x <= width) { // Draw only if within canvas
                ctx.beginPath();
                ctx.moveTo(x, 0);
                ctx.lineTo(x, height);
                ctx.stroke();

                if (freq !== minDisplayFreq && freq !== maxDisplayFreq && x > width*0.02 && x < width*0.98) { // Avoid clutter at edges
                    ctx.fillStyle = '#666';
                    ctx.font = '24px Arial';
                    ctx.textAlign = 'center';
                    ctx.fillText(freq >= 1000 ? `${Math.round(freq / 100)/10}k` : freq, x, height - 80);
                }
            }
        });

        // Horizontal grid lines (dB) - No change to this logic
        const dbStep = 12;
        for (let db = 0; db >= this.dr; db -= dbStep) {
            const y = height * (db / this.dr);
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(width, y);
            ctx.stroke();
            if (db !== 0 && db !== this.dr) {
                ctx.fillStyle = '#666'; ctx.font = '24px Arial'; ctx.textAlign = 'right';
                ctx.fillText(`${db}dB`, 160, y + 12);
            }
        }

        // Draw axis labels
        ctx.fillStyle = '#fff'; ctx.font = '28px Arial'; ctx.textAlign = 'center';
        ctx.fillText('Frequency (Hz)', width / 2, height - 10);
        ctx.save();
        ctx.translate(40, height / 2); ctx.rotate(-Math.PI / 2);
        ctx.fillText('Level (dB)', 0, 0);
        ctx.restore();

        // Draw spectrum
        const fftSize = 1 << this.pt;
        const binCount = fftSize >> 1;
        const xToLevels = new Map();
        
        for (let i = 0; i < binCount; i++) {
            const freq = (i * this.sampleRate) / fftSize; // Correct bin frequency calculation

            if (freq < minDisplayFreq || freq > maxDisplayFreq || logFreqRange <=0 ) continue;

            const currentFreqClamped = Math.max(minDisplayFreq, Math.min(freq, maxDisplayFreq));
            const x = Math.round(width * (Math.log10(currentFreqClamped) - logMinDisplayFreq) / logFreqRange);
            
            const spectrumLevel = this.spectrum[i] > 0 ? 0 : this.spectrum[i];
            const peakLevel = this.peaks[i] > 0 ? 0 : this.peaks[i];

            if (!xToLevels.has(x)) {
                xToLevels.set(x, [spectrumLevel, peakLevel]);
            } else {
                const [currentSpectrum, currentPeak] = xToLevels.get(x);
                xToLevels.set(x, [
                    currentSpectrum > spectrumLevel ? currentSpectrum : spectrumLevel,
                    currentPeak > peakLevel ? currentPeak : peakLevel
                ]);
            }
        }
        
        // Sort map entries by x-coordinate for correct line drawing
        const sortedXToLevels = new Map([...xToLevels.entries()].sort((a, b) => a[0] - b[0]));

        // Draw spectrum line
        ctx.beginPath();
        ctx.strokeStyle = '#008800'; ctx.lineWidth = 4;
        let first = true;
        for (const [x, [spectrumLevel]] of sortedXToLevels) {
            const y = height * (spectrumLevel / this.dr);
            if (first) {
                ctx.moveTo(x, y);
                first = false;
            } else {
                ctx.lineTo(x, y);
            }
        }
        ctx.stroke();

        // Draw peak hold line
        ctx.beginPath();
        ctx.strokeStyle = '#00ff00'; ctx.lineWidth = 2;
        first = true;
        for (const [x, [, peakLevel]] of sortedXToLevels) {
            const y = height * (peakLevel / this.dr);
            if (first) {
                ctx.moveTo(x, y);
                first = false;
            } else {
                ctx.lineTo(x, y);
            }
        }
        ctx.stroke();
    }
}

// Register plugin (assuming PluginBase and window context for browser)
if (typeof window !== 'undefined' && typeof PluginBase !== 'undefined') {
    window.SpectrumAnalyzerPlugin = SpectrumAnalyzerPlugin;
}