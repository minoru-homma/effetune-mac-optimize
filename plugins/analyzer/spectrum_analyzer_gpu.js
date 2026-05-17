// SpectrumAnalyzerGpuRenderer
//
// WebGPU-based renderer for the Spectrum Analyzer plugin. Replaces the heavy
// Canvas 2D drawGraph path (log-x compression + Map/sort + per-bin lineTo) with
// a GPU pipeline:
//
//   spectrum/peaks (Float32Array, dB)
//      → writeBuffer  → srcSpectrum / srcPeaks (storage buffers)
//      → compute pass: log-x reduce         → compactSpectrum / compactPeaks
//      → render pass : clear + grid + spectrum line + peak line
//      → swap chain
//
// FFT and peak-hold update remain in WASM on the main thread; this renderer
// only consumes their outputs. Grid lines are drawn here on the GPU; axis
// text labels are drawn by the plugin onto a separate stacked Canvas 2D
// overlay (only refreshed when parameters change).
//
// All failures (no navigator.gpu, adapter null, device lost, validation errors
// during render) are caught: init() returns false, render() throws — and the
// plugin's drawGraph() falls back to the Canvas 2D implementation in either
// case.

const SPECTRUM_PARAMS_BYTES = 48;   // see WGSL Params struct below
const LINE_PARAMS_BYTES = 32;       // see WGSL LineParams struct below
const GRID_PARAMS_BYTES = 32;       // see WGSL GridParams struct below

const COMPUTE_WGSL = /* wgsl */ `
struct Params {
    halfFft: u32,
    width: u32,
    height: u32,
    sampleRate: f32,
    logMin: f32,
    logRange: f32,
    dr: f32,
    minFreq: f32,
    maxFreq: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> srcSpectrum: array<f32>;
@group(0) @binding(2) var<storage, read> srcPeaks: array<f32>;
@group(0) @binding(3) var<storage, read_write> compactSpectrum: array<f32>;
@group(0) @binding(4) var<storage, read_write> compactPeaks: array<f32>;

@compute @workgroup_size(64)
fn cs_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let x = gid.x;
    if (x >= params.width) { return; }

    let widthF = f32(params.width);
    let xf = f32(x);

    // Frequency window for this column
    let leftLog = params.logMin + max(0.0, (xf - 0.5)) / widthF * params.logRange;
    let rightLog = params.logMin + min(widthF, (xf + 0.5)) / widthF * params.logRange;
    let freqLo = pow(10.0, leftLog);
    let freqHi = pow(10.0, rightLog);

    // Convert to bin range; halfFft*2 == fftSize
    let fftSize = f32(params.halfFft) * 2.0;
    let binLoF = freqLo * fftSize / params.sampleRate;
    let binHiF = freqHi * fftSize / params.sampleRate;
    let halfFftMinus1 = f32(params.halfFft) - 1.0;
    var binLo = i32(ceil(binLoF));
    var binHi = i32(floor(binHiF));
    if (binLo < 0) { binLo = 0; }
    if (binHi > i32(halfFftMinus1)) { binHi = i32(halfFftMinus1); }

    var spectrumMax = -200.0;
    var peakMax = -200.0;

    if (binLo > binHi) {
        // Sparse low-frequency end (bin density < 1 per pixel column).
        // Linear-interpolate the surrounding bins by the column's centre
        // frequency so the curve stays smooth across pixels that share the
        // same nearest bin. This matches the visual continuity of the JS
        // path (which connects bin → x dots with straight lines).
        let centreBinF = clamp((binLoF + binHiF) * 0.5, 0.0, halfFftMinus1);
        let lo = u32(floor(centreBinF));
        let hi = u32(min(f32(lo) + 1.0, halfFftMinus1));
        let t = centreBinF - floor(centreBinF);
        spectrumMax = mix(srcSpectrum[lo], srcSpectrum[hi], t);
        peakMax = mix(srcPeaks[lo], srcPeaks[hi], t);
    } else {
        for (var b = binLo; b <= binHi; b = b + 1) {
            let s = srcSpectrum[u32(b)];
            let p = srcPeaks[u32(b)];
            if (s > spectrumMax) { spectrumMax = s; }
            if (p > peakMax) { peakMax = p; }
        }
    }

    if (spectrumMax > 0.0) { spectrumMax = 0.0; }
    if (peakMax > 0.0) { peakMax = 0.0; }

    compactSpectrum[x] = spectrumMax;
    compactPeaks[x] = peakMax;
}
`;

const LINE_WGSL = /* wgsl */ `
struct LineParams {
    width: u32,
    height: u32,
    dr: f32,
    thickness: f32,
    color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> params: LineParams;
@group(0) @binding(1) var<storage, read> compact: array<f32>;

struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) col: vec4<f32>,
};

// Each segment uses 6 vertices forming 2 triangles:
//   corners 0..5 → (endIdx, side):
//     0: (0, -1)  1: (1, -1)  2: (0, +1)
//     3: (1, -1)  4: (0, +1)  5: (1, +1)
@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VOut {
    let segIdx = vid / 6u;
    let cornerIdx = vid % 6u;

    var endIdx: u32 = 0u;
    var side: f32 = -1.0;
    if (cornerIdx == 0u) { endIdx = 0u; side = -1.0; }
    else if (cornerIdx == 1u) { endIdx = 1u; side = -1.0; }
    else if (cornerIdx == 2u) { endIdx = 0u; side =  1.0; }
    else if (cornerIdx == 3u) { endIdx = 1u; side = -1.0; }
    else if (cornerIdx == 4u) { endIdx = 0u; side =  1.0; }
    else                      { endIdx = 1u; side =  1.0; }

    let widthF = f32(params.width);
    let heightF = f32(params.height);

    let v0 = compact[segIdx];
    let v1 = compact[segIdx + 1u];
    let value = compact[segIdx + endIdx];

    let x0Pix = f32(segIdx);
    let x1Pix = f32(segIdx + 1u);
    let xPix = f32(segIdx + endIdx);

    let y0Pix = heightF * (v0 / params.dr);
    let y1Pix = heightF * (v1 / params.dr);
    let yPix = heightF * (value / params.dr);

    // Pixel-space perpendicular for thickness
    let dx = x1Pix - x0Pix;
    let dy = y1Pix - y0Pix;
    let len = sqrt(dx * dx + dy * dy);
    var nx = 0.0;
    var ny = 0.0;
    if (len > 0.0001) {
        nx = -dy / len;
        ny =  dx / len;
    }
    let halfT = params.thickness * 0.5;
    let offX = nx * halfT * side;
    let offY = ny * halfT * side;

    let finalX = xPix + offX;
    let finalY = yPix + offY;

    let clipX = (finalX / widthF) * 2.0 - 1.0;
    let clipY = -((finalY / heightF) * 2.0 - 1.0);

    var out: VOut;
    out.pos = vec4<f32>(clipX, clipY, 0.0, 1.0);
    out.col = params.color;
    return out;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
    return in.col;
}
`;

const GRID_WGSL = /* wgsl */ `
struct GridParams {
    width: u32,
    height: u32,
    _pad0: u32,
    _pad1: u32,
    color: vec4<f32>,
};

// One vec4 per instance: (x_pixel, y_pixel, w_pixel, h_pixel) of the rectangle.
@group(0) @binding(0) var<uniform> params: GridParams;
@group(0) @binding(1) var<storage, read> rects: array<vec4<f32>>;

@vertex
fn vs_main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> @builtin(position) vec4<f32> {
    let r = rects[iid];
    // 6 vertices per quad: (0,0)(1,0)(0,1)(1,0)(0,1)(1,1)
    var dx: f32 = 0.0;
    var dy: f32 = 0.0;
    if (vid == 1u || vid == 3u || vid == 5u) { dx = 1.0; }
    if (vid == 2u || vid == 4u || vid == 5u) { dy = 1.0; }
    let pixX = r.x + dx * r.z;
    let pixY = r.y + dy * r.w;
    let widthF = f32(params.width);
    let heightF = f32(params.height);
    let clipX = (pixX / widthF) * 2.0 - 1.0;
    let clipY = -((pixY / heightF) * 2.0 - 1.0);
    return vec4<f32>(clipX, clipY, 0.0, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    return params.color;
}
`;

class SpectrumAnalyzerGpuRenderer {
    static isSupported() {
        return typeof navigator !== 'undefined'
            && !!navigator.gpu
            && typeof HTMLCanvasElement !== 'undefined';
    }

    static _describeAdapter(adapter) {
        const i = (adapter && adapter.info) ? adapter.info : {};
        const parts = [i.vendor, i.architecture, i.device, i.description].filter(Boolean);
        return (parts.join(' / ') || 'no adapter info')
            + (adapter && adapter.isFallbackAdapter ? ' [fallback]' : '');
    }

    // A software/fallback WebGPU adapter (SwiftShader, llvmpipe, Microsoft
    // Basic Render, …) is the root cause of the "all-black" bug: its device is
    // recycled roughly once a second, so init succeeds but the canvas is then
    // permanently lost. Refuse it so the plugin uses the (always-working)
    // dedicated Canvas 2D fallback instead of looping on device loss.
    static _isSoftwareAdapter(adapter) {
        if (!adapter) return true;
        if (adapter.isFallbackAdapter === true) return true;
        const i = adapter.info || {};
        const hay = [i.vendor, i.architecture, i.device, i.description]
            .filter(Boolean).join(' ').toLowerCase();
        if (!hay) return false; // no info exposed — don't over-reject a real GPU
        if (/swiftshader|llvmpipe|lavapipe|softpipe|basic render|microsoft basic|warp/.test(hay)) {
            return true;
        }
        // SwiftShader frequently reports vendor "google" with a software arch.
        return /\bgoogle\b/.test(hay) && /swiftshader|software/.test(hay);
    }

    constructor(canvas) {
        this.canvas = canvas;
        this.adapter = null; // retained so the device is not GC-lost ("destroyed")
        this.device = null;
        this.context = null;
        this.format = null;
        this._destroyed = false;
        this._configured = false;
        // Optional callback invoked once when the GPUDevice is lost
        // unexpectedly (GPU process recycle, sleep/wake, driver update, GC).
        // The owner (plugin) uses it to re-initialise WebGPU rather than
        // permanently dropping to a (poisoned) Canvas 2D fallback.
        this.onDeviceLost = null;

        // Per-(pt, width) resources
        this._halfFft = 0;
        this._width = 0;
        this._height = 0;
        this._sampleRate = 48000;
        this._dr = -96;
        this._minFreq = 20;
        this._maxFreq = 40000;

        // GPU buffers
        this.bufParams = null;       // 48 B uniform
        this.bufLineSpec = null;     // 32 B uniform (spectrum line)
        this.bufLinePeak = null;     // 32 B uniform (peak line)
        this.bufGrid = null;         // 32 B uniform (grid)
        this.bufSrcSpec = null;      // halfFft * 4
        this.bufSrcPeak = null;      // halfFft * 4
        this.bufCompactSpec = null;  // width * 4
        this.bufCompactPeak = null;  // width * 4
        this.bufGridRects = null;    // grid_count * 16

        // Pipelines + bind groups
        this.pipeCompute = null;
        this.bgCompute = null;
        this.pipeLine = null;
        this.bgLineSpec = null;
        this.bgLinePeak = null;
        this.pipeGrid = null;
        this.bgGrid = null;

        // Cached uniform CPU staging
        this._paramsArrU = new ArrayBuffer(SPECTRUM_PARAMS_BYTES);
        this._paramsArrU32 = new Uint32Array(this._paramsArrU);
        this._paramsArrF32 = new Float32Array(this._paramsArrU);
        this._lineSpecArr = new ArrayBuffer(LINE_PARAMS_BYTES);
        this._lineSpecU32 = new Uint32Array(this._lineSpecArr);
        this._lineSpecF32 = new Float32Array(this._lineSpecArr);
        this._linePeakArr = new ArrayBuffer(LINE_PARAMS_BYTES);
        this._linePeakU32 = new Uint32Array(this._linePeakArr);
        this._linePeakF32 = new Float32Array(this._linePeakArr);
        this._gridArr = new ArrayBuffer(GRID_PARAMS_BYTES);
        this._gridU32 = new Uint32Array(this._gridArr);
        this._gridF32 = new Float32Array(this._gridArr);

        // Grid rectangle list (built in configure)
        this._gridCount = 0;
    }

    async init() {
        if (!SpectrumAnalyzerGpuRenderer.isSupported()) {
            this._logWarn('init step 0: isSupported() false (navigator.gpu=' + (typeof navigator !== 'undefined' && !!navigator.gpu) + ')');
            return false;
        }
        try {
            this._logInfo('init step 1: requesting adapter');
            const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'low-power' });
            if (!adapter) {
                this._logWarn('init step 1 FAILED: requestAdapter returned null (low-power)');
                // Retry with high-performance preference
                const adapter2 = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
                if (!adapter2) {
                    this._logWarn('init step 1b FAILED: requestAdapter null (high-performance too) — WebGPU likely disabled in this build');
                    return false;
                }
                this._logInfo('init step 1b: got adapter via high-performance');
                return await this._continueInit(adapter2);
            }
            this._logInfo('init step 1: got adapter (low-power)');
            return await this._continueInit(adapter);
        } catch (err) {
            this._logWarn('init failed: ' + (err && err.message ? err.message : String(err)));
            this.device = null;
            this.context = null;
            return false;
        }
    }

    async _continueInit(adapter) {
        try {
            if (SpectrumAnalyzerGpuRenderer._isSoftwareAdapter(adapter)) {
                this._logWarn('software/fallback adapter rejected ('
                    + SpectrumAnalyzerGpuRenderer._describeAdapter(adapter)
                    + ') — using Canvas 2D to avoid the SwiftShader device-loss loop');
                this.device = null;
                this.context = null;
                return false;
            }
            this._logInfo('init step 2: requesting device (vendor=' + (adapter.info && adapter.info.vendor) + ')');
            const device = await adapter.requestDevice();
            if (!device) {
                this._logWarn('init step 2 FAILED: requestDevice returned null');
                return false;
            }
            // Retain the adapter for the device's lifetime.  Without a strong
            // reference the adapter (and with it the device) is garbage
            // collected, surfacing as an unexpected `device lost: destroyed`
            // a few seconds after init even though no code called destroy().
            this.adapter = adapter;
            this.device = device;

            device.lost.then((info) => {
                if (this._destroyed) return;
                const reason = info && info.reason ? info.reason : 'unknown';
                this._logWarn('device lost: ' + reason);
                this.device = null;
                // Notify the owner so it can re-initialise WebGPU.  Without
                // recovery the shared canvas stays claimed by the dead webgpu
                // context and Canvas 2D fallback cannot draw → permanent black.
                const cb = this.onDeviceLost;
                if (typeof cb === 'function') {
                    try { cb(reason); } catch (_) { /* ignore */ }
                }
            });

            this._logInfo('init step 3: getContext(webgpu)');
            const context = this.canvas.getContext('webgpu');
            if (!context) {
                this._logWarn('init step 3 FAILED: getContext(webgpu) returned null');
                return false;
            }
            this.context = context;

            this._logInfo('init step 4: configure context');
            this.format = navigator.gpu.getPreferredCanvasFormat();
            context.configure({ device, format: this.format, alphaMode: 'opaque' });

            this._width = this.canvas.width | 0;
            this._height = this.canvas.height | 0;

            this._logInfo('init step 5: building pipelines');
            this._buildPipelines();
            this._logInfo('init complete (format=' + this.format + ')');
            return true;
        } catch (err) {
            this._logWarn('_continueInit failed: ' + (err && err.message ? err.message : String(err)));
            this.device = null;
            this.context = null;
            return false;
        }
    }

    _logInfo(msg) {
        const tag = '[SpectrumAnalyzerGPU]';
        // eslint-disable-next-line no-console
        console.log(tag, msg);
        if (typeof window !== 'undefined' && window.electronAPI && window.electronAPI.logToMain) {
            window.electronAPI.logToMain('info', 'SpectrumAnalyzerGPU', msg);
        }
    }

    _buildPipelines() {
        const device = this.device;
        const format = this.format;

        const computeModule = device.createShaderModule({ code: COMPUTE_WGSL });
        const lineModule = device.createShaderModule({ code: LINE_WGSL });
        const gridModule = device.createShaderModule({ code: GRID_WGSL });

        // Compute pipeline
        this.pipeCompute = device.createComputePipeline({
            layout: 'auto',
            compute: { module: computeModule, entryPoint: 'cs_main' }
        });

        // Spectrum/peak line pipeline (shared)
        this.pipeLine = device.createRenderPipeline({
            layout: 'auto',
            vertex: { module: lineModule, entryPoint: 'vs_main' },
            fragment: {
                module: lineModule,
                entryPoint: 'fs_main',
                targets: [{ format }]
            },
            primitive: { topology: 'triangle-list' }
        });

        // Grid pipeline
        this.pipeGrid = device.createRenderPipeline({
            layout: 'auto',
            vertex: { module: gridModule, entryPoint: 'vs_main' },
            fragment: {
                module: gridModule,
                entryPoint: 'fs_main',
                targets: [{ format }]
            },
            primitive: { topology: 'triangle-list' }
        });
    }

    configure({ pt, sampleRate, dr, minFreq, maxFreq }) {
        if (!this.device) return;
        const halfFft = (1 << pt) >> 1;
        const width = this.canvas.width | 0;
        const height = this.canvas.height | 0;
        const needRebuild = (halfFft !== this._halfFft || width !== this._width || height !== this._height);

        this._halfFft = halfFft;
        this._width = width;
        this._height = height;
        this._sampleRate = sampleRate;
        this._dr = dr;
        this._minFreq = minFreq;
        this._maxFreq = maxFreq;

        if (needRebuild || !this.bufParams) {
            this._buildResources();
            this._buildBindGroups();
        }
        this._writeUniforms();
        this._writeGridRects();
        this._configured = true;
    }

    _buildResources() {
        const device = this.device;
        const dispose = (b) => { if (b) try { b.destroy(); } catch (_) { /* noop */ } };
        dispose(this.bufParams);
        dispose(this.bufLineSpec);
        dispose(this.bufLinePeak);
        dispose(this.bufGrid);
        dispose(this.bufSrcSpec);
        dispose(this.bufSrcPeak);
        dispose(this.bufCompactSpec);
        dispose(this.bufCompactPeak);
        dispose(this.bufGridRects);

        const halfFft = this._halfFft;
        const width = this._width;

        const U = GPUBufferUsage;
        this.bufParams = device.createBuffer({
            size: SPECTRUM_PARAMS_BYTES,
            usage: U.UNIFORM | U.COPY_DST
        });
        this.bufLineSpec = device.createBuffer({
            size: LINE_PARAMS_BYTES,
            usage: U.UNIFORM | U.COPY_DST
        });
        this.bufLinePeak = device.createBuffer({
            size: LINE_PARAMS_BYTES,
            usage: U.UNIFORM | U.COPY_DST
        });
        this.bufGrid = device.createBuffer({
            size: GRID_PARAMS_BYTES,
            usage: U.UNIFORM | U.COPY_DST
        });
        this.bufSrcSpec = device.createBuffer({
            size: halfFft * 4,
            usage: U.STORAGE | U.COPY_DST
        });
        this.bufSrcPeak = device.createBuffer({
            size: halfFft * 4,
            usage: U.STORAGE | U.COPY_DST
        });
        this.bufCompactSpec = device.createBuffer({
            size: width * 4,
            usage: U.STORAGE
        });
        this.bufCompactPeak = device.createBuffer({
            size: width * 4,
            usage: U.STORAGE
        });

        // Grid rect buffer: pre-size for up to 64 lines (10 vertical + ~10 horizontal target).
        const maxGridLines = 64;
        this.bufGridRects = device.createBuffer({
            size: maxGridLines * 16,
            usage: U.STORAGE | U.COPY_DST
        });
    }

    _buildBindGroups() {
        const device = this.device;

        this.bgCompute = device.createBindGroup({
            layout: this.pipeCompute.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: { buffer: this.bufParams } },
                { binding: 1, resource: { buffer: this.bufSrcSpec } },
                { binding: 2, resource: { buffer: this.bufSrcPeak } },
                { binding: 3, resource: { buffer: this.bufCompactSpec } },
                { binding: 4, resource: { buffer: this.bufCompactPeak } }
            ]
        });

        this.bgLineSpec = device.createBindGroup({
            layout: this.pipeLine.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: { buffer: this.bufLineSpec } },
                { binding: 1, resource: { buffer: this.bufCompactSpec } }
            ]
        });

        this.bgLinePeak = device.createBindGroup({
            layout: this.pipeLine.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: { buffer: this.bufLinePeak } },
                { binding: 1, resource: { buffer: this.bufCompactPeak } }
            ]
        });

        this.bgGrid = device.createBindGroup({
            layout: this.pipeGrid.getBindGroupLayout(0),
            entries: [
                { binding: 0, resource: { buffer: this.bufGrid } },
                { binding: 1, resource: { buffer: this.bufGridRects } }
            ]
        });
    }

    _writeUniforms() {
        const logMin = Math.log10(this._minFreq);
        const logMax = Math.log10(this._maxFreq);
        const logRange = Math.max(1e-6, logMax - logMin);

        // Params
        this._paramsArrU32[0] = this._halfFft >>> 0;
        this._paramsArrU32[1] = this._width >>> 0;
        this._paramsArrU32[2] = this._height >>> 0;
        this._paramsArrF32[3] = this._sampleRate;
        this._paramsArrF32[4] = logMin;
        this._paramsArrF32[5] = logRange;
        this._paramsArrF32[6] = this._dr;
        this._paramsArrF32[7] = this._minFreq;
        this._paramsArrF32[8] = this._maxFreq;
        this._paramsArrF32[9] = 0;
        this._paramsArrF32[10] = 0;
        this._paramsArrF32[11] = 0;
        this.device.queue.writeBuffer(this.bufParams, 0, this._paramsArrU);

        // Line params (spectrum: 4 px green; peak: 2 px brighter green)
        this._writeLineParams(this._lineSpecArr, this._lineSpecU32, this._lineSpecF32,
            4.0, 0x00 / 255, 0x88 / 255, 0x00 / 255);
        this.device.queue.writeBuffer(this.bufLineSpec, 0, this._lineSpecArr);

        this._writeLineParams(this._linePeakArr, this._linePeakU32, this._linePeakF32,
            2.0, 0x00 / 255, 0xFF / 255, 0x00 / 255);
        this.device.queue.writeBuffer(this.bufLinePeak, 0, this._linePeakArr);

        // Grid params (#333 ≈ 0.2)
        this._gridU32[0] = this._width >>> 0;
        this._gridU32[1] = this._height >>> 0;
        this._gridU32[2] = 0;
        this._gridU32[3] = 0;
        this._gridF32[4] = 0.2;
        this._gridF32[5] = 0.2;
        this._gridF32[6] = 0.2;
        this._gridF32[7] = 1.0;
        this.device.queue.writeBuffer(this.bufGrid, 0, this._gridArr);
    }

    _writeLineParams(arr, u32, f32, thicknessPx, r, g, b) {
        u32[0] = this._width >>> 0;
        u32[1] = this._height >>> 0;
        f32[2] = this._dr;
        f32[3] = thicknessPx;
        f32[4] = r;
        f32[5] = g;
        f32[6] = b;
        f32[7] = 1.0;
        // Note: arr is the same memory as u32/f32, no separate flush needed.
    }

    // Build the grid rectangle list in pixel space; mirrors the JS gridFreqs
    // pattern in spectrum_analyzer.js. We draw vertical (frequency) and
    // horizontal (dB) rules; widths are 1 device pixel for the GPU canvas at
    // its physical resolution (2048x960).
    _writeGridRects() {
        const w = this._width;
        const h = this._height;
        const logMin = Math.log10(this._minFreq);
        const logMax = Math.log10(this._maxFreq);
        const logRange = Math.max(1e-6, logMax - logMin);
        const dpr = Math.round(w / 1024);
        const lineThick = Math.max(1, dpr); // matches Canvas 2D lineWidth=2 at 2x DPR

        const rects = [];
        // Verticals: standard audio frequencies
        const freqs = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 40000];
        for (const f of freqs) {
            if (f < this._minFreq || f > this._maxFreq) continue;
            const x = Math.round(w * (Math.log10(f) - logMin) / logRange);
            rects.push(x, 0, lineThick, h);
        }
        // Horizontals: every 12 dB up to dr
        const dr = this._dr;
        for (let db = 0; db >= dr; db -= 12) {
            const y = Math.round(h * (db / dr));
            rects.push(0, y, w, lineThick);
        }

        const data = new Float32Array(rects);
        // Pad to maxGridLines × 4 floats so the storage buffer is the right size
        // (we allocated 64 instances). Excess padding is zero, never indexed
        // since draw() uses gridCount instances.
        this._gridCount = (rects.length / 4) | 0;
        this.device.queue.writeBuffer(this.bufGridRects, 0, data);
    }

    render(spectrumF32, peaksF32) {
        if (!this.device || !this.context) {
            throw new Error('GPU renderer not initialised');
        }
        if (!this._configured) {
            throw new Error('GPU renderer not configured (call configure first)');
        }

        // Detect canvas size mismatch (window resize) — rebuild compact buffers
        if ((this.canvas.width | 0) !== this._width || (this.canvas.height | 0) !== this._height) {
            this._width = this.canvas.width | 0;
            this._height = this.canvas.height | 0;
            this._buildResources();
            this._buildBindGroups();
            this._writeUniforms();
            this._writeGridRects();
        }

        // Refresh source data each frame. spectrumF32.byteLength may exceed
        // halfFft*4 (host ArrayBuffer reused by WASM); only the first
        // halfFft*4 bytes are meaningful.
        const halfBytes = this._halfFft * 4;
        if (spectrumF32 && spectrumF32.byteLength >= halfBytes) {
            this.device.queue.writeBuffer(this.bufSrcSpec, 0, spectrumF32.buffer,
                spectrumF32.byteOffset, halfBytes);
        }
        if (peaksF32 && peaksF32.byteLength >= halfBytes) {
            this.device.queue.writeBuffer(this.bufSrcPeak, 0, peaksF32.buffer,
                peaksF32.byteOffset, halfBytes);
        }

        const encoder = this.device.createCommandEncoder();

        // Compute pass: log-x reduce
        {
            const cp = encoder.beginComputePass();
            cp.setPipeline(this.pipeCompute);
            cp.setBindGroup(0, this.bgCompute);
            const wgCount = Math.ceil(this._width / 64);
            cp.dispatchWorkgroups(wgCount);
            cp.end();
        }

        // Render pass: clear + grid + spectrum line + peak line
        {
            const view = this.context.getCurrentTexture().createView();
            const rp = encoder.beginRenderPass({
                colorAttachments: [{
                    view,
                    clearValue: { r: 0, g: 0, b: 0, a: 1 },
                    loadOp: 'clear',
                    storeOp: 'store'
                }]
            });

            // Grid
            if (this._gridCount > 0) {
                rp.setPipeline(this.pipeGrid);
                rp.setBindGroup(0, this.bgGrid);
                rp.draw(6, this._gridCount, 0, 0);
            }

            // Spectrum line
            const segCount = Math.max(0, this._width - 1);
            if (segCount > 0) {
                rp.setPipeline(this.pipeLine);
                rp.setBindGroup(0, this.bgLineSpec);
                rp.draw(segCount * 6, 1, 0, 0);

                rp.setBindGroup(0, this.bgLinePeak);
                rp.draw(segCount * 6, 1, 0, 0);
            }

            rp.end();
        }

        this.device.queue.submit([encoder.finish()]);
    }

    destroy() {
        this._destroyed = true;
        const dispose = (b) => { if (b) try { b.destroy(); } catch (_) { /* noop */ } };
        dispose(this.bufParams);
        dispose(this.bufLineSpec);
        dispose(this.bufLinePeak);
        dispose(this.bufGrid);
        dispose(this.bufSrcSpec);
        dispose(this.bufSrcPeak);
        dispose(this.bufCompactSpec);
        dispose(this.bufCompactPeak);
        dispose(this.bufGridRects);
        if (this.device) {
            try { this.device.destroy(); } catch (_) { /* ignore */ }
        }
        this.device = null;
        this.context = null;
        this.pipeCompute = null;
        this.pipeLine = null;
        this.pipeGrid = null;
        this.bgCompute = null;
        this.bgLineSpec = null;
        this.bgLinePeak = null;
        this.bgGrid = null;
    }

    _logWarn(msg) {
        const tag = '[SpectrumAnalyzerGPU]';
        // eslint-disable-next-line no-console
        console.warn(tag, msg);
        if (typeof window !== 'undefined' && window.electronAPI && window.electronAPI.logToMain) {
            window.electronAPI.logToMain('warn', 'SpectrumAnalyzerGPU', msg);
        }
    }
}

if (typeof window !== 'undefined') {
    window.SpectrumAnalyzerGpuRenderer = SpectrumAnalyzerGpuRenderer;
}
