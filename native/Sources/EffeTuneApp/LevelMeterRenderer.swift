import Foundation
import Metal
import QuartzCore
import AppKit
import EffeTuneEngine

/// Native renderer for the Level Meter. The meter is tiny (1024×64) and full of
/// dynamic text (per-channel dB readout) + the OVERLOAD indicator, so it's drawn
/// with CoreGraphics straight into the IOSurface each frame (no JS, no IPC) —
/// cheaper than the JS canvas + its WebContent/compositor cost. Peak-hold and
/// fall-rate replicate level_meter.js (FALL_RATE 20 dB/s, hold 1 s, overload 5 s).
final class LevelMeterRenderer: AnalyzerRenderer {
    var layer: CALayer { presenter.layer }
    private let ctx: MetalContext
    private let presenter: SurfacePresenter

    private let dbStart: Float = -96, dbRange: Float = 96
    private let fallRate: Float = 20, peakHold: Double = 1.0, overloadTime: Double = 5.0
    private var lv: [Float] = [], pl: [Float] = [], ph: [Double] = []
    private var overload = false, overloadAt: Double = 0
    private var lastTime: Double = 0

    private var cg: CGContext?
    private var cgW = 0, cgH = 0
    private var srcTex: MTLTexture?
    private let minFrameInterval = 1.0 / 30.0
    private var lastPosition = -1
    private var lastRenderTime: Double = 0

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.presenter = SurfacePresenter(device: ctx.device, format: ctx.pixelFormat)
    }

    private func ampToDB(_ a: Float) -> Float { a <= 1e-8 ? -144 : max(-144, 20 * log10f(a)) }

    func render(module: EffectModule, params: [String: Float], sampleRate: Double) {
        let now = CACurrentMediaTime()
        if lastRenderTime > 0 && now - lastRenderTime < minFrameInterval - 0.002 { return }
        let pos = module.spectrumPosition
        if pos == lastPosition { return }
        lastPosition = pos
        let dt = lastTime > 0 ? Float(now - lastTime) : Float(minFrameInterval)
        lastRenderTime = now; lastTime = now

        let window = max(1, Int(sampleRate / 30))
        let peaks = module.channelPeaks(window: window)
        let nch = peaks.count
        guard nch > 0 else { return }
        if lv.count != nch { lv = [Float](repeating: -144, count: nch); pl = lv; ph = [Double](repeating: 0, count: nch) }

        var maxPeak: Float = 0
        for ch in 0..<nch {
            let dbLevel = ampToDB(peaks[ch])
            lv[ch] = max(dbLevel, max(-144, lv[ch] - fallRate * dt))
            if dbLevel > pl[ch] { pl[ch] = dbLevel; ph[ch] = now }
            else if now > ph[ch] + peakHold { pl[ch] = max(pl[ch] - fallRate * dt, lv[ch]) }
            if peaks[ch] > maxPeak { maxPeak = peaks[ch] }
        }
        if maxPeak > 1.0 { overload = true; overloadAt = now }
        else if now > overloadAt + overloadTime { overload = false }

        let scale = presenter.layer.contentsScale
        let drawW = Int((presenter.layer.bounds.width * scale).rounded())
        let drawH = Int((presenter.layer.bounds.height * scale).rounded())
        guard drawW > 1, drawH > 0 else { return }

        guard let cg = ensureContext(drawW, drawH), let src = srcTex, let data = cg.data else { return }
        draw(cg, w: drawW, h: drawH, nch: nch)
        src.replace(region: MTLRegionMake2D(0, 0, drawW, drawH), mipmapLevel: 0, withBytes: data, bytesPerRow: drawW * 4)

        guard let target = presenter.target(width: drawW, height: drawH),
              let cmd = ctx.queue.makeCommandBuffer() else { return }
        // Blit via vs_blit (same orientation handling as the other backdrops).
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let rp = cmd.makeRenderCommandEncoder(descriptor: pass) {
            rp.setRenderPipelineState(ctx.blitPipeline)
            rp.setFragmentTexture(src, index: 0)
            rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            rp.endEncoding()
        }
        presenter.present(cmd)
        cmd.commit()
    }

    private func ensureContext(_ w: Int, _ h: Int) -> CGContext? {
        if cg != nil && cgW == w && cgH == h { return cg }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        srcTex = ctx.device.makeTexture(descriptor: d)
        cgW = w; cgH = h
        return cg
    }

    private func draw(_ cg: CGContext, w wi: Int, h hi: Int, nch: Int) {
        let ns = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let w = CGFloat(wi), h = CGFloat(hi)
        let scale = h / 64.0
        NSColor.black.setFill(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))

        // dB grid (every 3 dB) + labels (every 12 dB).
        NSColor(white: 1, alpha: 0.2).setStroke()
        let gridAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10 * scale), .foregroundColor: NSColor(white: 1, alpha: 0.5)]
        var db = -96
        while db <= 0 {
            let x = w * (CGFloat(db) + 96) / 96
            let p = NSBezierPath(); p.lineWidth = max(1, scale)
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: h)); p.stroke()
            if db % 12 == 0 && db != 0 && db != -96 {
                let s = "\(db)" as NSString
                let sz = s.size(withAttributes: gridAttrs)
                s.draw(at: NSPoint(x: x - sz.width / 2, y: h - 12 * scale), withAttributes: gridAttrs)
            }
            db += 3
        }

        let xOf: (Float) -> CGFloat = { CGFloat(w) * CGFloat(($0 - self.dbStart) / self.dbRange) }
        let x12 = xOf(-12), x6 = xOf(-6)
        let green = NSColor(red: 0, green: 0.5, blue: 0, alpha: 1)
        let yellow = NSColor(red: 0.5, green: 0.5, blue: 0, alpha: 1)
        let red = NSColor(red: 0.5, green: 0, blue: 0, alpha: 1)
        let perCh = h / CGFloat(nch)
        let chH = perCh - (nch > 1 ? 2 : 0)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale), .foregroundColor: NSColor.white]

        for ch in 0..<nch {
            let y = CGFloat(ch) * perCh + 1
            let lw = max(0, xOf(lv[ch]))
            func zone(_ a: CGFloat, _ b: CGFloat, _ c: NSColor) {
                let x1 = min(lw, b)
                if x1 > a { c.setFill(); NSBezierPath.fill(NSRect(x: a, y: y, width: x1 - a, height: chH)) }
            }
            zone(0, x12, green)
            if lw > x12 { zone(x12, x6, yellow) }
            if lw > x6 { zone(x6, w, red) }
            // Peak-hold marker.
            let px = xOf(pl[ch])
            NSColor.white.setFill(); NSBezierPath.fill(NSRect(x: px - 1, y: y, width: 2, height: chH))
            // Per-channel dB readout (right-aligned), for ≤4 channels.
            if nch <= 4 {
                let s = String(format: "%.1f dB", pl[ch]) as NSString
                let sz = s.size(withAttributes: textAttrs)
                s.draw(at: NSPoint(x: w - 10 * scale - sz.width, y: y + chH / 2 - sz.height / 2), withAttributes: textAttrs)
            }
        }

        // OVERLOAD indicator (red, top-left) when any channel exceeded 0 dBFS.
        if overload {
            let s = "OVERLOAD" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 12 * scale), .foregroundColor: NSColor.red]
            s.draw(at: NSPoint(x: 10 * scale, y: 2 * scale), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
