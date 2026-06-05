import Foundation
import Metal
import QuartzCore
import AppKit
import IOSurface
import EffeTuneEngine

/// Shared Metal device/queue/pipelines for the analyzer overlay. Built once;
/// all per-analyzer renderers reference it. Returns nil if Metal is unavailable
/// (the overlay then stays dormant and the JS Canvas path keeps working).
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let computePipeline: MTLComputePipelineState
    let linePipeline: MTLRenderPipelineState
    let blitPipeline: MTLRenderPipelineState
    let heatPipeline: MTLRenderPipelineState        // spectrogram heatmap
    let blitBlendPipeline: MTLRenderPipelineState   // grid/label overlay (premultiplied alpha)
    let scopePipeline: MTLRenderPipelineState       // oscilloscope waveform
    let scatterPipeline: MTLRenderPipelineState     // stereo meter point cloud
    let pixLinePipeline: MTLRenderPipelineState     // generic pixel-space polyline
    let pixelFormat: MTLPixelFormat = .bgra8Unorm

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        do {
            let lib = try dev.makeLibrary(source: MetalContext.shaderSource, options: nil)
            guard let cs = lib.makeFunction(name: "cs_reduce"),
                  let vs = lib.makeFunction(name: "vs_line"),
                  let fs = lib.makeFunction(name: "fs_line"),
                  let vb = lib.makeFunction(name: "vs_blit"),
                  let fb = lib.makeFunction(name: "fs_blit") else { return nil }
            computePipeline = try dev.makeComputePipelineState(function: cs)
            let rp = MTLRenderPipelineDescriptor()
            rp.vertexFunction = vs
            rp.fragmentFunction = fs
            rp.colorAttachments[0].pixelFormat = pixelFormat
            rp.colorAttachments[0].isBlendingEnabled = false  // lines replace the backdrop
            linePipeline = try dev.makeRenderPipelineState(descriptor: rp)

            // Opaque backdrop blit (bg + grid + labels rendered once into a texture).
            let bp = MTLRenderPipelineDescriptor()
            bp.vertexFunction = vb
            bp.fragmentFunction = fb
            bp.colorAttachments[0].pixelFormat = pixelFormat
            bp.colorAttachments[0].isBlendingEnabled = false
            blitPipeline = try dev.makeRenderPipelineState(descriptor: bp)

            // Spectrogram heatmap (opaque).
            let hp = MTLRenderPipelineDescriptor()
            hp.vertexFunction = vb
            hp.fragmentFunction = lib.makeFunction(name: "fs_heat")
            hp.colorAttachments[0].pixelFormat = pixelFormat
            hp.colorAttachments[0].isBlendingEnabled = false
            heatPipeline = try dev.makeRenderPipelineState(descriptor: hp)

            // Grid/label overlay over the heatmap (premultiplied alpha).
            let op = MTLRenderPipelineDescriptor()
            op.vertexFunction = vb
            op.fragmentFunction = fb
            op.colorAttachments[0].pixelFormat = pixelFormat
            op.colorAttachments[0].isBlendingEnabled = true
            op.colorAttachments[0].rgbBlendOperation = .add
            op.colorAttachments[0].alphaBlendOperation = .add
            op.colorAttachments[0].sourceRGBBlendFactor = .one
            op.colorAttachments[0].sourceAlphaBlendFactor = .one
            op.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            op.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blitBlendPipeline = try dev.makeRenderPipelineState(descriptor: op)

            // Oscilloscope waveform line.
            let sp = MTLRenderPipelineDescriptor()
            sp.vertexFunction = lib.makeFunction(name: "vs_scope")
            sp.fragmentFunction = fs
            sp.colorAttachments[0].pixelFormat = pixelFormat
            sp.colorAttachments[0].isBlendingEnabled = false
            scopePipeline = try dev.makeRenderPipelineState(descriptor: sp)

            // Stereo meter scatter (points).
            let scp = MTLRenderPipelineDescriptor()
            scp.vertexFunction = lib.makeFunction(name: "vs_scatter")
            scp.fragmentFunction = lib.makeFunction(name: "fs_pt")
            scp.colorAttachments[0].pixelFormat = pixelFormat
            scp.colorAttachments[0].isBlendingEnabled = false
            scatterPipeline = try dev.makeRenderPipelineState(descriptor: scp)

            // Generic pixel-space polyline.
            let plp = MTLRenderPipelineDescriptor()
            plp.vertexFunction = lib.makeFunction(name: "vs_pixline")
            plp.fragmentFunction = fs
            plp.colorAttachments[0].pixelFormat = pixelFormat
            plp.colorAttachments[0].isBlendingEnabled = false
            pixLinePipeline = try dev.makeRenderPipelineState(descriptor: plp)
        } catch {
            nlog("MetalContext init failed: \(error)")
            return nil
        }
        device = dev
        queue = q
    }

    // Ported from plugins/analyzer/spectrum_analyzer_gpu.js (COMPUTE_WGSL +
    // LINE_WGSL). Grid is intentionally omitted: the transparent overlay lets the
    // DOM canvas draw the static grid + axis labels underneath.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint  halfFft;
        uint  width;
        uint  height;
        float sampleRate;
        float logMin;
        float logRange;
        float dr;
        float minFreq;
        float maxFreq;
    };

    kernel void cs_reduce(uint gid [[thread_position_in_grid]],
                          constant Params& p          [[buffer(0)]],
                          device const float* srcSpec [[buffer(1)]],
                          device const float* srcPeak [[buffer(2)]],
                          device float* compactSpec   [[buffer(3)]],
                          device float* compactPeak   [[buffer(4)]]) {
        uint x = gid;
        if (x >= p.width) { return; }
        float widthF = float(p.width);
        float xf = float(x);
        float leftLog  = p.logMin + max(0.0, (xf - 0.5)) / widthF * p.logRange;
        float rightLog = p.logMin + min(widthF, (xf + 0.5)) / widthF * p.logRange;
        float freqLo = pow(10.0, leftLog);
        float freqHi = pow(10.0, rightLog);
        float fftSize = float(p.halfFft) * 2.0;
        float binLoF = freqLo * fftSize / p.sampleRate;
        float binHiF = freqHi * fftSize / p.sampleRate;
        float halfFftMinus1 = float(p.halfFft) - 1.0;
        int binLo = int(ceil(binLoF));
        int binHi = int(floor(binHiF));
        if (binLo < 0) { binLo = 0; }
        if (binHi > int(halfFftMinus1)) { binHi = int(halfFftMinus1); }
        float specMax = -200.0;
        float peakMax = -200.0;
        if (binLo > binHi) {
            float centreBinF = clamp((binLoF + binHiF) * 0.5, 0.0, halfFftMinus1);
            uint lo = uint(floor(centreBinF));
            uint hi = uint(min(float(lo) + 1.0, halfFftMinus1));
            float t = centreBinF - floor(centreBinF);
            specMax = mix(srcSpec[lo], srcSpec[hi], t);
            peakMax = mix(srcPeak[lo], srcPeak[hi], t);
        } else {
            for (int b = binLo; b <= binHi; b = b + 1) {
                float s = srcSpec[uint(b)];
                float pk = srcPeak[uint(b)];
                if (s > specMax) { specMax = s; }
                if (pk > peakMax) { peakMax = pk; }
            }
        }
        if (specMax > 0.0) { specMax = 0.0; }
        if (peakMax > 0.0) { peakMax = 0.0; }
        compactSpec[x] = specMax;
        compactPeak[x] = peakMax;
    }

    struct LineParams {
        uint  width;
        uint  height;
        float dr;
        float thickness;
        float4 color;
    };

    struct VOut {
        float4 pos [[position]];
        float4 col;
    };

    vertex VOut vs_line(uint vid [[vertex_id]],
                        constant LineParams& p     [[buffer(0)]],
                        device const float* compact [[buffer(1)]]) {
        uint segIdx = vid / 6u;
        uint cornerIdx = vid % 6u;
        uint endIdx = 0u;
        float side = -1.0;
        if (cornerIdx == 0u)      { endIdx = 0u; side = -1.0; }
        else if (cornerIdx == 1u) { endIdx = 1u; side = -1.0; }
        else if (cornerIdx == 2u) { endIdx = 0u; side =  1.0; }
        else if (cornerIdx == 3u) { endIdx = 1u; side = -1.0; }
        else if (cornerIdx == 4u) { endIdx = 0u; side =  1.0; }
        else                      { endIdx = 1u; side =  1.0; }
        float widthF = float(p.width);
        float heightF = float(p.height);
        float v0 = compact[segIdx];
        float v1 = compact[segIdx + 1u];
        float value = compact[segIdx + endIdx];
        float x0Pix = float(segIdx);
        float x1Pix = float(segIdx + 1u);
        float xPix = float(segIdx + endIdx);
        float y0Pix = heightF * (v0 / p.dr);
        float y1Pix = heightF * (v1 / p.dr);
        float yPix = heightF * (value / p.dr);
        float dx = x1Pix - x0Pix;
        float dy = y1Pix - y0Pix;
        float len = sqrt(dx * dx + dy * dy);
        float nx = 0.0;
        float ny = 0.0;
        if (len > 0.0001) { nx = -dy / len; ny = dx / len; }
        float halfT = p.thickness * 0.5;
        float offX = nx * halfT * side;
        float offY = ny * halfT * side;
        float finalX = xPix + offX;
        float finalY = yPix + offY;
        float clipX = (finalX / widthF) * 2.0 - 1.0;
        float clipY = -((finalY / heightF) * 2.0 - 1.0);
        VOut out;
        out.pos = float4(clipX, clipY, 0.0, 1.0);
        out.col = p.color;
        return out;
    }

    fragment float4 fs_line(VOut in [[stage_in]]) {
        return in.col;
    }

    // Fullscreen blit of the static backdrop texture (background + grid + labels).
    struct TexVOut { float4 pos [[position]]; float2 uv; };
    vertex TexVOut vs_blit(uint vid [[vertex_id]]) {
        float2 p[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                        float2(1,-1),  float2(1,1),  float2(-1,1) };
        float2 pos = p[vid];
        TexVOut o;
        o.pos = float4(pos, 0, 1);
        o.uv = float2((pos.x + 1.0) * 0.5, (pos.y + 1.0) * 0.5);
        return o;
    }
    fragment float4 fs_blit(TexVOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::nearest);
        return tex.sample(s, in.uv);
    }

    // Spectrogram heatmap: sample a 1024-wide ring-buffer history texture so the
    // newest column (just written at `head`) is at the right edge, and flip the
    // vertical axis so high frequency (texture row 0) is at the top.
    struct HeatParams { uint head; uint width; };
    fragment float4 fs_heat(TexVOut in [[stage_in]],
                            constant HeatParams& hp [[buffer(0)]],
                            texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::nearest);
        float W = float(hp.width);
        uint xi = min(uint(in.uv.x * W), hp.width - 1u);
        uint col = (hp.head + 1u + xi) % hp.width;
        float u = (float(col) + 0.5) / W;
        return tex.sample(s, float2(u, 1.0 - in.uv.y));
    }

    // Oscilloscope waveform: a centered polyline of `count` samples mapped to
    // x in [leftMargin, width], y = centerY - sample*factor*(height/2).
    struct ScopeParams {
        uint  width; uint height; uint count; uint leftMargin;
        float centerY; float factor; float thickness; float _pad;
        float4 color;
    };
    vertex VOut vs_scope(uint vid [[vertex_id]],
                         constant ScopeParams& p   [[buffer(0)]],
                         device const float* wave  [[buffer(1)]]) {
        uint segIdx = vid / 6u;
        uint corner = vid % 6u;
        uint endIdx = 0u; float side = -1.0;
        if (corner == 0u)      { endIdx = 0u; side = -1.0; }
        else if (corner == 1u) { endIdx = 1u; side = -1.0; }
        else if (corner == 2u) { endIdx = 0u; side =  1.0; }
        else if (corner == 3u) { endIdx = 1u; side = -1.0; }
        else if (corner == 4u) { endIdx = 0u; side =  1.0; }
        else                   { endIdx = 1u; side =  1.0; }
        float wF = float(p.width), hF = float(p.height);
        float lm = float(p.leftMargin), span = wF - lm;
        float cnt = max(2.0, float(p.count));
        float halfH = hF * 0.5;
        float x0 = lm + (float(segIdx)      / (cnt - 1.0)) * span;
        float x1 = lm + (float(segIdx + 1u) / (cnt - 1.0)) * span;
        float xP = lm + (float(segIdx + endIdx) / (cnt - 1.0)) * span;
        float y0 = p.centerY - wave[segIdx]          * p.factor * halfH;
        float y1 = p.centerY - wave[segIdx + 1u]     * p.factor * halfH;
        float yP = p.centerY - wave[segIdx + endIdx] * p.factor * halfH;
        float dx = x1 - x0, dy = y1 - y0;
        float len = sqrt(dx * dx + dy * dy);
        float nx = 0.0, ny = 0.0;
        if (len > 0.0001) { nx = -dy / len; ny = dx / len; }
        float halfT = p.thickness * 0.5;
        float fx = xP + nx * halfT * side;
        float fy = yP + ny * halfT * side;
        VOut out;
        out.pos = float4((fx / wF) * 2.0 - 1.0, -((fy / hF) * 2.0 - 1.0), 0.0, 1.0);
        out.col = p.color;
        return out;
    }

    // Stereo meter point cloud: pixel-space points, green brightness ramps with
    // vertex index (older→darker, matching stereo_meter.js).
    struct ScatterParams { float w; float h; uint count; float psize; };
    struct PtOut { float4 pos [[position]]; float4 col; float ps [[point_size]]; };
    vertex PtOut vs_scatter(uint vid [[vertex_id]],
                            constant ScatterParams& p [[buffer(0)]],
                            device const float2* pts  [[buffer(1)]]) {
        float2 q = pts[vid];
        PtOut o;
        o.pos = float4((q.x / p.w) * 2.0 - 1.0, -((q.y / p.h) * 2.0 - 1.0), 0.0, 1.0);
        float t = p.count > 1u ? float(vid) / (float(p.count) - 1.0) : 1.0;
        o.col = float4(0.0, t, 0.0, 1.0);
        o.ps = p.psize;
        return o;
    }
    fragment float4 fs_pt(PtOut in [[stage_in]]) { return in.col; }

    // Generic pixel-space polyline (e.g. stereo peak curve, meter shapes).
    struct PixParams { float w; float h; float _p0; float _p1; float4 color; };
    vertex VOut vs_pixline(uint vid [[vertex_id]],
                           constant PixParams& p     [[buffer(0)]],
                           device const float2* pts  [[buffer(1)]]) {
        float2 q = pts[vid];
        VOut o;
        o.pos = float4((q.x / p.w) * 2.0 - 1.0, -((q.y / p.h) * 2.0 - 1.0), 0.0, 1.0);
        o.col = p.color;
        return o;
    }
    """
}

/// Per-analyzer Metal renderer for the Spectrum Analyzer. Pulls (spectrum, peaks)
/// directly from the native EffectModule each frame — no JS/IPC round trip.
///
/// Presentation: instead of CAMetalLayer (whose CAMetalDrawable + CoreAnimation
/// "FramePacing" path profiled as the dominant CPU cost), we render into our own
/// IOSurface-backed textures (triple-buffered) and hand each finished surface to
/// a plain CALayer via `.contents`, bypassing that machinery entirely.
final class SpectrumRenderer: AnalyzerRenderer {
    let layer: CALayer
    private let ctx: MetalContext

    // Triple-buffered IOSurface render targets, rebuilt on size change.
    private struct Surface { let surface: IOSurfaceRef; let texture: MTLTexture }
    private var surfaces: [Surface] = []
    private var surfaceW = 0
    private var surfaceH = 0
    private var frameIndex = 0

    // Source dB halves (fixed FFT size 4096 → half = 2048; see EffectModule.spectrumComputed).
    private let half = 2048
    private var bufSrcSpec: MTLBuffer
    private var bufSrcPeak: MTLBuffer
    // Width-sized compact buffers, rebuilt when the drawable width changes.
    private var compactWidth = 0
    private var bufCompactSpec: MTLBuffer?
    private var bufCompactPeak: MTLBuffer?

    // Static backdrop (background + grid + axis labels) rendered once via
    // CoreGraphics into a texture; redrawn only when size or dB range changes.
    // Opaque so the WindowServer skips compositing the WebView underneath.
    private var backdropTex: MTLTexture?
    private var backdropKey = ""

    private let minFreq: Float = 20
    private let maxFreq: Float = 40000

    // Cap the render rate. The CVDisplayLink fires at the display refresh (120 Hz
    // on ProMotion) but the spectrum doesn't need more than ~30 Hz — upstream's
    // meter push used 30 Hz ("visually smooth enough; 60 Hz doubled the cost for
    // little benefit"). `lastPosition` additionally drops us to 0 work when the
    // engine is stopped (the tap counter stops advancing).
    private let minFrameInterval = 1.0 / 30.0
    private var lastPosition = -1
    private var lastRenderTime: Double = 0

    init(ctx: MetalContext) {
        self.ctx = ctx
        let layer = CALayer()
        // Opaque: Metal draws the whole graph (bg + grid + labels + curves).
        layer.isOpaque = true
        layer.contentsGravity = .resize
        self.layer = layer
        bufSrcSpec = ctx.device.makeBuffer(length: half * 4, options: .storageModeShared)!
        bufSrcPeak = ctx.device.makeBuffer(length: half * 4, options: .storageModeShared)!
    }

    /// (Re)allocate the triple-buffered IOSurface render targets at `w`×`h` pixels.
    private func rebuildSurfaces(width w: Int, height h: Int) {
        surfaces.removeAll()
        let props: [CFString: Any] = [
            kIOSurfaceWidth: w,
            kIOSurfaceHeight: h,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: w * 4,
            kIOSurfacePixelFormat: 0x42475241,  // 'BGRA'
        ]
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        for _ in 0..<3 {
            guard let surf = IOSurfaceCreate(props as CFDictionary),
                  let tex = ctx.device.makeTexture(descriptor: desc, iosurface: surf, plane: 0) else { continue }
            surfaces.append(Surface(surface: surf, texture: tex))
        }
        surfaceW = w; surfaceH = h
    }

    /// Render one frame from the module's natively-computed spectrum. Skips work
    /// when no new audio has been captured since the last frame; the peak-hold
    /// decay is driven by the real elapsed time between renders (JS 20·dt fall).
    func render(module: EffectModule, params: [String: Float], sampleRate: Double) {
        let dr = params["dr"] ?? -96
        let now = CACurrentMediaTime()
        // 30 Hz cap (small tolerance so we don't skip the frame that lands a hair
        // under the interval on a 120 Hz vsync grid).
        if lastRenderTime > 0 && now - lastRenderTime < minFrameInterval - 0.002 { return }
        let pos = module.spectrumPosition
        if pos == lastPosition { return }   // engine stopped → nothing new to draw
        lastPosition = pos
        let dt = lastRenderTime > 0 ? Float(now - lastRenderTime) : Float(minFrameInterval)
        lastRenderTime = now

        guard let r = module.spectrumComputed(decay: 20.0 * max(dt, 0)) else { return }
        // Upload source dB halves.
        r.spectrum.withUnsafeBytes { bufSrcSpec.contents().copyMemory(from: $0.baseAddress!, byteCount: min($0.count, half * 4)) }
        r.peaks.withUnsafeBytes { bufSrcPeak.contents().copyMemory(from: $0.baseAddress!, byteCount: min($0.count, half * 4)) }
        // Pixel size = layer bounds (points) × contentsScale, set by the overlay.
        let scale = layer.contentsScale
        let drawW = Int((layer.bounds.width * scale).rounded())
        let drawH = Int((layer.bounds.height * scale).rounded())
        guard drawW > 1, drawH > 0 else { return }

        if surfaceW != drawW || surfaceH != drawH || surfaces.isEmpty {
            rebuildSurfaces(width: drawW, height: drawH)
        }
        if compactWidth != drawW || bufCompactSpec == nil {
            compactWidth = drawW
            bufCompactSpec = ctx.device.makeBuffer(length: drawW * 4, options: .storageModePrivate)
            bufCompactPeak = ctx.device.makeBuffer(length: drawW * 4, options: .storageModePrivate)
        }
        // Rebuild the static backdrop only when geometry / dB range changes.
        let key = "\(drawW)x\(drawH)@\(dr)"
        if key != backdropKey { rebuildBackdrop(width: drawW, height: drawH, dr: dr); backdropKey = key }

        guard let compactSpec = bufCompactSpec, let compactPeak = bufCompactPeak,
              !surfaces.isEmpty,
              let cmd = ctx.queue.makeCommandBuffer() else { return }
        let target = surfaces[frameIndex % surfaces.count]
        frameIndex += 1

        var params = makeParams(width: UInt32(drawW), height: UInt32(drawH), dr: dr, sampleRate: Float(sampleRate))

        // Compute pass: log-x reduce halfFft bins → drawW columns.
        if let cp = cmd.makeComputeCommandEncoder() {
            cp.setComputePipelineState(ctx.computePipeline)
            cp.setBytes(&params, length: MemoryLayout<SpectrumParams>.stride, index: 0)
            cp.setBuffer(bufSrcSpec, offset: 0, index: 1)
            cp.setBuffer(bufSrcPeak, offset: 0, index: 2)
            cp.setBuffer(compactSpec, offset: 0, index: 3)
            cp.setBuffer(compactPeak, offset: 0, index: 4)
            let tg = MTLSize(width: 64, height: 1, depth: 1)
            let groups = MTLSize(width: (drawW + 63) / 64, height: 1, depth: 1)
            cp.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            cp.endEncoding()
        }

        // Render pass into the IOSurface texture: opaque bg + grid + labels + curves.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let rp = cmd.makeRenderCommandEncoder(descriptor: pass) {
            // Backdrop (opaque bg + grid + labels) as a fullscreen textured quad.
            if let bg = backdropTex {
                rp.setRenderPipelineState(ctx.blitPipeline)
                rp.setFragmentTexture(bg, index: 0)
                rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            rp.setRenderPipelineState(ctx.linePipeline)
            let segCount = drawW - 1
            // Spectrum line: #008800, 4px (scaled to drawable resolution).
            var specLine = makeLineParams(width: UInt32(drawW), height: UInt32(drawH), dr: dr,
                                          thickness: 4.0, r: 0x00/255.0, g: 0x88/255.0, b: 0x00/255.0)
            rp.setVertexBytes(&specLine, length: MemoryLayout<LineParams>.stride, index: 0)
            rp.setVertexBuffer(compactSpec, offset: 0, index: 1)
            rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: segCount * 6)
            // Peak line: #00ff00, 2px.
            var peakLine = makeLineParams(width: UInt32(drawW), height: UInt32(drawH), dr: dr,
                                          thickness: 2.0, r: 0x00/255.0, g: 0xff/255.0, b: 0x00/255.0)
            rp.setVertexBytes(&peakLine, length: MemoryLayout<LineParams>.stride, index: 0)
            rp.setVertexBuffer(compactPeak, offset: 0, index: 1)
            rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: segCount * 6)
            rp.endEncoding()
        }
        // Hand the finished surface to the CALayer once the GPU is done writing it.
        // Triple buffering means the compositor reads an older surface meanwhile.
        let surf = target.surface
        let lyr = layer
        cmd.addCompletedHandler { _ in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lyr.contents = surf
            CATransaction.commit()
        }
        cmd.commit()
    }

    // MARK: uniform staging (layouts match the MSL structs above)

    private struct SpectrumParams {
        var halfFft: UInt32 = 0, width: UInt32 = 0, height: UInt32 = 0
        var sampleRate: Float = 0, logMin: Float = 0, logRange: Float = 0
        var dr: Float = 0, minFreq: Float = 0, maxFreq: Float = 0
    }
    private struct LineParams {
        var width: UInt32 = 0, height: UInt32 = 0
        var dr: Float = 0, thickness: Float = 0
        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 1
    }

    private func makeParams(width: UInt32, height: UInt32, dr: Float, sampleRate: Float) -> SpectrumParams {
        let logMin = log10f(minFreq)
        let logRange = max(1e-6, log10f(maxFreq) - logMin)
        return SpectrumParams(halfFft: UInt32(half), width: width, height: height,
                              sampleRate: sampleRate, logMin: logMin, logRange: logRange,
                              dr: dr, minFreq: minFreq, maxFreq: maxFreq)
    }
    private func makeLineParams(width: UInt32, height: UInt32, dr: Float, thickness: Float,
                                r: Float, g: Float, b: Float) -> LineParams {
        // `thickness` (4 / 2) is defined in the JS renderer's 2048-wide backing
        // space; scale it to the actual drawable width so the line keeps the same
        // on-screen weight at any DPR (matches spectrum_analyzer_gpu.js exactly
        // when drawable width == 2048).
        let ref = Float(width) / 2048.0
        return LineParams(width: width, height: height, dr: dr, thickness: thickness * ref,
                          r: r, g: g, b: b, a: 1)
    }

    // MARK: static backdrop (background + grid + axis labels)

    /// Render the opaque backdrop once per (size, dB range) into a BGRA texture via
    /// CoreGraphics. Mirrors the JS Canvas grid/labels (spectrum_analyzer.js) so the
    /// native graph looks the same; redrawn only when geometry / dB range changes.
    private func rebuildBackdrop(width: Int, height: Int, dr: Float) {
        guard width > 0, height > 0 else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: cs, bitmapInfo: info) else { return }
        // flipped:true → draw in top-left coordinates, matching the Canvas code.
        let ns = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns

        let w = CGFloat(width), h = CGFloat(height)
        let scale = max(0.25, w / 2048.0)   // backdrop authored against the 2048px reference
        NSColor.black.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))

        let minF = 20.0, maxF = 40000.0
        let logMin = log10(minF), logRange = log10(maxF) - logMin
        let lineW = max(1.0, 2.0 * scale)
        NSColor(white: 0.2, alpha: 1).setStroke()   // #333

        let labelFont = NSFont.systemFont(ofSize: 24 * scale)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor(white: 0.4, alpha: 1)]

        var freqs: [Double] = [20,50,100,200,500,1000,2000,5000,10000,20000].filter { $0 >= minF && $0 <= maxF }
        if !freqs.contains(minF) { freqs.insert(minF, at: 0) }
        if !freqs.contains(maxF) { freqs.append(maxF) }
        for f in freqs {
            let x = w * CGFloat((log10(f) - logMin) / logRange)
            if x < 0 || x > w { continue }
            let p = NSBezierPath(); p.lineWidth = lineW
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: h)); p.stroke()
            if f != minF && f != maxF && x > w * 0.02 && x < w * 0.98 {
                let label = (f >= 1000 ? "\((f/1000).cleanString)k" : "\(Int(f))") as NSString
                let sz = label.size(withAttributes: labelAttrs)
                label.draw(at: NSPoint(x: x - sz.width / 2, y: h - 80 * scale), withAttributes: labelAttrs)
            }
        }

        let drD = Double(dr)
        if drD < 0 {
            var db = 0.0
            while db >= drD {
                let y = h * CGFloat(db / drD)
                let p = NSBezierPath(); p.lineWidth = lineW
                p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: w, y: y)); p.stroke()
                if db != 0 && db != drD {
                    let s = "\(Int(db))dB" as NSString
                    let sz = s.size(withAttributes: labelAttrs)
                    s.draw(at: NSPoint(x: 160 * scale - sz.width, y: y - sz.height / 2), withAttributes: labelAttrs)
                }
                db -= 12
            }
        }

        let titleFont = NSFont.systemFont(ofSize: 28 * scale)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.white]
        let ft = "Frequency (Hz)" as NSString
        let fts = ft.size(withAttributes: titleAttrs)
        ft.draw(at: NSPoint(x: w / 2 - fts.width / 2, y: h - 4 * scale - fts.height), withAttributes: titleAttrs)

        NSGraphicsContext.restoreGraphicsState()

        guard let data = cg.data else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = ctx.device.makeTexture(descriptor: desc) else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: width * 4)
        backdropTex = tex
    }
}

extension Double {
    // 2.0 -> "2", 2.5 -> "2.5" (matches the JS `${f/1000}k` label formatting).
    var cleanString: String {
        self == rounded() ? String(Int(self)) : String(self)
    }
}
