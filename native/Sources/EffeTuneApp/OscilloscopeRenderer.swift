import Foundation
import Metal
import QuartzCore
import AppKit
import EffeTuneEngine

/// Native Metal renderer for the Oscilloscope. Replaces the JS per-frame waveform
/// line draw (Canvas 2D) with a GPU polyline over a native grid; pulls the mono
/// ring directly from the EffectModule. Mirrors plugins/analyzer/oscilloscope.js.
/// v1: free-running (shows the latest Display-Time window; no edge trigger yet).
final class OscilloscopeRenderer: AnalyzerRenderer {
    var layer: CALayer { presenter.layer }
    private let ctx: MetalContext
    private let presenter: SurfacePresenter

    private var bufWave: MTLBuffer?
    private var waveCount = 0
    private var backdropTex: MTLTexture?
    private var backdropKey = ""

    private let minFrameInterval = 1.0 / 30.0
    private var lastPosition = -1
    private var lastRenderTime: Double = 0

    private struct ScopeParams {
        var width: UInt32 = 0, height: UInt32 = 0, count: UInt32 = 0, leftMargin: UInt32 = 0
        var centerY: Float = 0, factor: Float = 0, thickness: Float = 0, pad: Float = 0
        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 1
    }

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.presenter = SurfacePresenter(device: ctx.device, format: ctx.pixelFormat)
    }

    func render(module: EffectModule, params: [String: Float], sampleRate: Double) {
        let dt = Double(params["dt"] ?? 0.01)        // display time (s)
        let dl = params["dl"] ?? 0                   // display level (dB)
        let vo = params["vo"] ?? 0                   // vertical offset (-1..1)
        let tl = params["tl"] ?? 0                   // trigger level (-1..1)
        let teRising = (params["te"] ?? 1) >= 0.5    // edge: rising vs falling
        let normalMode = (params["tm"] ?? 0) >= 0.5  // Normal (freeze w/o trigger) vs Auto
        let now = CACurrentMediaTime()
        if lastRenderTime > 0 && now - lastRenderTime < minFrameInterval - 0.002 { return }
        let pos = module.spectrumPosition
        if pos == lastPosition { return }
        lastPosition = pos
        lastRenderTime = now

        guard let snap = module.monoRingSnapshot() else { return }
        let ring = snap.buffer, cap = ring.count
        let displaySamples = max(2, min(Int(sampleRate * dt), cap))

        let scale = presenter.layer.contentsScale
        let drawW = Int((presenter.layer.bounds.width * scale).rounded())
        let drawH = Int((presenter.layer.bounds.height * scale).rounded())
        guard drawW > 1, drawH > 0 else { return }

        // Edge trigger: anchor the display at the most recent rising/falling
        // crossing of `tl` whose full window still fits in the ring, so periodic
        // signals stay stationary. Auto = free-run if none found; Normal = freeze.
        let base = snap.position - displaySamples       // latest trigger that keeps the window
        var start = (base + cap) % cap                   // free-run fallback
        var found = false
        let searchBack = min(cap - displaySamples - 2, Int(sampleRate * 0.1))
        var k = 0
        while k < searchBack {
            let i = ((base - k) % cap + cap) % cap
            let prev = ring[((i - 1) % cap + cap) % cap], cur = ring[i]
            if teRising ? (prev < tl && cur >= tl) : (prev > tl && cur <= tl) { start = i; found = true; break }
            k += 1
        }
        if normalMode && !found { return }   // freeze: keep the previously shown surface

        // Resample `displaySamples` from the trigger to drawW points.
        let M = drawW
        if waveCount != M || bufWave == nil {
            bufWave = ctx.device.makeBuffer(length: M * 4, options: .storageModeShared); waveCount = M
        }
        guard let wave = bufWave else { return }
        let wp = wave.contents().bindMemory(to: Float.self, capacity: M)
        let denom = Double(max(1, M - 1))
        for x in 0..<M {
            let off = Int((Double(x) / denom * Double(displaySamples - 1)).rounded())
            wp[x] = ring[(start + off) % cap]
        }

        let key = "\(drawW)x\(drawH)|\(dl)|\(vo)|\(dt)|\(Int(sampleRate))"
        if key != backdropKey { rebuildBackdrop(width: drawW, height: drawH, dl: dl, vo: vo, dt: dt); backdropKey = key }

        guard let target = presenter.target(width: drawW, height: drawH),
              let cmd = ctx.queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let rp = cmd.makeRenderCommandEncoder(descriptor: pass) {
            if let bg = backdropTex {
                rp.setRenderPipelineState(ctx.blitPipeline)
                rp.setFragmentTexture(bg, index: 0)
                rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            let factor = Float(1.0 / pow(10.0, Double(dl) / 20.0))
            let lm = UInt32((80.0 * Double(drawW) / 1024.0).rounded())
            var p = ScopeParams()
            p.width = UInt32(drawW); p.height = UInt32(drawH); p.count = UInt32(M); p.leftMargin = lm
            p.centerY = Float(drawH) / 2 - vo * Float(drawH) / 2
            p.factor = factor
            p.thickness = Float(max(1.0, 2.0 * Double(drawW) / 1024.0))
            p.r = 0; p.g = 1; p.b = 0; p.a = 1   // #0f0
            rp.setRenderPipelineState(ctx.scopePipeline)
            rp.setVertexBytes(&p, length: MemoryLayout<ScopeParams>.stride, index: 0)
            rp.setVertexBuffer(wave, offset: 0, index: 1)
            rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: (M - 1) * 6)
            rp.endEncoding()
        }
        presenter.present(cmd)
        cmd.commit()
    }

    // Black background + amplitude grid (nice-number ticks) + time grid + labels.
    // Ported from oscilloscope.js drawWaveform (reference canvas = 1024×480).
    private func rebuildBackdrop(width: Int, height: Int, dl: Float, vo: Float, dt: Double) {
        guard width > 0, height > 0 else { return }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        let ns = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let w = Double(width), h = Double(height)
        let scale = w / 1024.0
        NSColor.black.setFill(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))

        let leftMargin = 80.0 * scale
        let factor = 1.0 / pow(10.0, Double(dl) / 20.0)
        let centerY = h / 2 - Double(vo) * h / 2
        let halfH = h / 2

        let gridColor = NSColor(white: 0.2, alpha: 1)  // #333
        let labelColor = NSColor(white: 0.4, alpha: 1) // #666
        let labelFont = NSFont.systemFont(ofSize: 12 * scale)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: labelColor]

        // Amplitude grid (nice-number ticks over the visible range).
        gridColor.setStroke()
        let ampTop = centerY / (halfH * factor)
        let ampBottom = (centerY - h) / (halfH * factor)
        let visMin = min(ampTop, ampBottom), visMax = max(ampTop, ampBottom)
        let rawStep = (visMax - visMin) / 20.0
        if rawStep > 0 {
            let expo = floor(log10(rawStep))
            let frac = rawStep / pow(10.0, expo)
            let nice: Double = frac < 1.5 ? 1 : (frac < 3 ? 2 : (frac < 7 ? 5 : 10))
            let step = nice * pow(10.0, expo)
            let decimals = expo < 0 ? Int(-expo) : 0
            var tick = ceil(visMin / step) * step
            let end = floor(visMax / step) * step
            while tick <= end + step * 0.5 {
                let y = centerY - tick * factor * halfH
                let p = NSBezierPath(); p.lineWidth = max(1, scale)
                p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: w, y: y)); p.stroke()
                if y - 6 * scale >= 0 && y + 6 * scale <= h {
                    let tv = abs(tick) < step / 1e6 ? 0.0 : tick   // avoid "-0.0"
                    let s = String(format: "%.\(decimals)f", tv) as NSString
                    s.draw(at: NSPoint(x: 4 * scale, y: y - 7 * scale), withAttributes: labelAttrs)
                }
                tick += step
            }
        }

        // Time grid (10 divisions) + time labels.
        gridColor.setStroke()
        for i in 0...10 {
            let x = leftMargin + (w - leftMargin) * Double(i) / 10.0
            let p = NSBezierPath(); p.lineWidth = max(1, scale)
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: h)); p.stroke()
            if i != 0 && i != 10 {
                let tms = Double(i) / 10.0 * dt * 1000.0
                let s = String(format: "%.2f ms", tms) as NSString
                let sz = s.size(withAttributes: labelAttrs)
                s.draw(at: NSPoint(x: x - sz.width / 2, y: h - 40 * scale), withAttributes: labelAttrs)
            }
        }

        // Axis titles.
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14 * scale), .foregroundColor: NSColor.white]
        let tt = "Time (ms)" as NSString
        let tts = tt.size(withAttributes: titleAttrs)
        tt.draw(at: NSPoint(x: leftMargin + (w - leftMargin) / 2 - tts.width / 2, y: h - 10 * scale - tts.height), withAttributes: titleAttrs)

        NSGraphicsContext.restoreGraphicsState()
        guard let data = cg.data else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = ctx.device.makeTexture(descriptor: desc) else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        backdropTex = tex
    }
}
