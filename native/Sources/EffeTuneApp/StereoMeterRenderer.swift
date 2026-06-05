import Foundation
import Metal
import QuartzCore
import AppKit
import EffeTuneEngine

/// Native Metal renderer for the Stereo Meter (Lissajous point cloud + smoothed
/// 360° peak curve over a diamond grid). Mirrors plugins/analyzer/stereo_meter.js.
final class StereoMeterRenderer: AnalyzerRenderer {
    var layer: CALayer { presenter.layer }
    private let ctx: MetalContext
    private let presenter: SurfacePresenter

    private let window = 8192
    private var scatterBuf: MTLBuffer?      // float2 × window
    private var peakBuf: MTLBuffer?         // float2 × 361 (closed curve)
    private var scatterCount = 0
    private var smoothed = [Float](repeating: 0, count: 360)
    private var backdropTex: MTLTexture?
    private var backdropKey = ""

    private let minFrameInterval = 1.0 / 30.0
    private var lastPosition = -1
    private var lastRenderTime: Double = 0

    private struct ScatterParams { var w: Float = 0, h: Float = 0; var count: UInt32 = 0; var psize: Float = 1 }
    private struct PixParams { var w: Float = 0, h: Float = 0, p0: Float = 0, p1: Float = 0
                               var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 1 }

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.presenter = SurfacePresenter(device: ctx.device, format: ctx.pixelFormat)
    }

    func render(module: EffectModule, params: [String: Float], sampleRate: Double) {
        let now = CACurrentMediaTime()
        if lastRenderTime > 0 && now - lastRenderTime < minFrameInterval - 0.002 { return }
        let pos = module.spectrumPosition
        if pos == lastPosition { return }
        lastPosition = pos
        lastRenderTime = now

        guard let snap = module.stereoSnapshot(window: window) else { return }
        let scale = presenter.layer.contentsScale
        let drawW = Int((presenter.layer.bounds.width * scale).rounded())
        let drawH = Int((presenter.layer.bounds.height * scale).rounded())
        guard drawW > 1, drawH > 0 else { return }

        let cx = Float(drawW) / 2, cy = Float(drawH) / 2
        let radius = Float(min(drawW, drawH)) * 0.45
        let n = snap.x.count

        // Scatter screen positions (chronological → vertex index = age).
        if scatterCount != n || scatterBuf == nil {
            scatterBuf = ctx.device.makeBuffer(length: max(1, n) * 8, options: .storageModeShared); scatterCount = n
        }
        if peakBuf == nil { peakBuf = ctx.device.makeBuffer(length: 361 * 8, options: .storageModeShared) }
        guard let sb = scatterBuf, let pb = peakBuf else { return }
        let sp = sb.contents().bindMemory(to: SIMD2<Float>.self, capacity: n)
        for i in 0..<n {
            sp[i] = SIMD2<Float>(cx + snap.x[i] * 0.5 * radius, cy - snap.y[i] * 0.5 * radius)
        }

        // Gaussian-smooth the 360° peak histogram (sigma 5°), build a closed curve.
        let sigma: Float = 5, range = 15
        for i in 0..<360 {
            var sum: Float = 0, wsum: Float = 0
            for j in -range...range {
                let a = ((i + j) % 360 + 360) % 360
                let wgt = expf(-Float(j * j) / (2 * sigma * sigma))
                sum += snap.peak[a] * wgt; wsum += wgt
            }
            smoothed[i] = wsum > 0 ? sum / wsum : 0
        }
        let pp = pb.contents().bindMemory(to: SIMD2<Float>.self, capacity: 361)
        for i in 0..<360 {
            let rad = Float(i) * .pi / 180
            let r = smoothed[i] * 0.5 * radius
            pp[i] = SIMD2<Float>(cx + cosf(rad) * r, cy + sinf(rad) * r)
        }
        pp[360] = pp[0]

        // Correlation + inter-channel energy difference (from L=(y-x)/2, R=(x+y)/2).
        var sumLR: Float = 0, sumL2: Float = 0, sumR2: Float = 0
        for i in 0..<n {
            let L = (snap.y[i] - snap.x[i]) * 0.5, R = (snap.x[i] + snap.y[i]) * 0.5
            sumLR += L * R; sumL2 += L * L; sumR2 += R * R
        }
        let correlation = (sumL2 > 0 && sumR2 > 0) ? sumLR / sqrtf(sumL2 * sumR2) : 0
        let energyDiff = 10 * log10f(sumR2 + 1e-12) - 10 * log10f(sumL2 + 1e-12)

        let key = "\(drawW)x\(drawH)"
        if key != backdropKey { rebuildBackdrop(width: drawW, height: drawH); backdropKey = key }

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
            // Point cloud.
            var scp = ScatterParams(w: Float(drawW), h: Float(drawH), count: UInt32(n),
                                    psize: Float(max(1.0, Double(drawW) / 480.0)))
            rp.setRenderPipelineState(ctx.scatterPipeline)
            rp.setVertexBytes(&scp, length: MemoryLayout<ScatterParams>.stride, index: 0)
            rp.setVertexBuffer(sb, offset: 0, index: 1)
            rp.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
            // Smoothed peak curve (white).
            var pix = PixParams(w: Float(drawW), h: Float(drawH), r: 1, g: 1, b: 1, a: 1)
            rp.setRenderPipelineState(ctx.pixLinePipeline)
            rp.setVertexBytes(&pix, length: MemoryLayout<PixParams>.stride, index: 0)
            rp.setVertexBuffer(pb, offset: 0, index: 1)
            rp.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: 361)

            // Correlation bar (left edge, green) + energy-difference bar (bottom).
            let bar = Float(16) * Float(min(drawW, drawH)) / 480
            let corrH = abs(correlation) * cy
            if correlation >= 0 { fillRect(rp, w: Float(drawW), h: Float(drawH), x0: 0, x1: bar, y0: cy - corrH, y1: cy, r: 0, g: 0.5, b: 0) }
            else { fillRect(rp, w: Float(drawW), h: Float(drawH), x0: 0, x1: bar, y0: cy, y1: cy + corrH, r: 0, g: 0.5, b: 0) }
            let eMax: Float = 18
            let eClamped = max(-eMax, min(eMax, energyDiff))
            let halfW = Float(drawW) / 2
            let eLen = eClamped / eMax * halfW
            let eY = Float(drawH) - bar
            if eLen >= 0 { fillRect(rp, w: Float(drawW), h: Float(drawH), x0: cx, x1: cx + eLen, y0: eY, y1: eY + bar, r: 0, g: 0.5, b: 0) }
            else { fillRect(rp, w: Float(drawW), h: Float(drawH), x0: cx + eLen, x1: cx, y0: eY, y1: eY + bar, r: 0, g: 0.5, b: 0) }
            rp.endEncoding()
        }
        presenter.present(cmd)
        cmd.commit()
    }

    private func fillRect(_ rp: MTLRenderCommandEncoder, w: Float, h: Float,
                          x0: Float, x1: Float, y0: Float, y1: Float, r: Float, g: Float, b: Float) {
        guard x1 > x0, y1 > y0 else { return }
        var p = PixParams(w: w, h: h, r: r, g: g, b: b, a: 1)
        var v: [SIMD2<Float>] = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x0, y1),
                                 SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
        rp.setRenderPipelineState(ctx.pixLinePipeline)
        rp.setVertexBytes(&p, length: MemoryLayout<PixParams>.stride, index: 0)
        rp.setVertexBytes(&v, length: MemoryLayout<SIMD2<Float>>.stride * 6, index: 1)
        rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // Diamond + axes + 45° lines + L/R labels (reference canvas = 480×480).
    private func rebuildBackdrop(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        let ns = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let w = Double(width), h = Double(height)
        let cx = w / 2, cy = h / 2
        let radius = Double(min(width, height)) * 0.45
        let scale = Double(min(width, height)) / 480.0
        NSColor.black.setFill(); NSBezierPath.fill(NSRect(x: 0, y: 0, width: w, height: h))

        NSColor(white: 0.2, alpha: 1).setStroke()  // #333
        let diamond = NSBezierPath(); diamond.lineWidth = max(1, scale)
        diamond.move(to: NSPoint(x: cx, y: cy - radius))
        diamond.line(to: NSPoint(x: cx + radius, y: cy))
        diamond.line(to: NSPoint(x: cx, y: cy + radius))
        diamond.line(to: NSPoint(x: cx - radius, y: cy))
        diamond.close(); diamond.stroke()
        let axes = NSBezierPath(); axes.lineWidth = max(1, scale)
        axes.move(to: NSPoint(x: cx, y: cy - radius)); axes.line(to: NSPoint(x: cx, y: cy + radius))
        axes.move(to: NSPoint(x: cx - radius, y: cy)); axes.line(to: NSPoint(x: cx + radius, y: cy))
        axes.stroke()
        let diag = NSBezierPath(); diag.lineWidth = max(1, scale)
        for angle in stride(from: 45, to: 360, by: 90) {
            let rad = Double(angle) * .pi / 180
            let x = cos(rad), y = sin(rad)
            let s = min(abs(radius / x), abs(radius / y))
            diag.move(to: NSPoint(x: cx, y: cy)); diag.line(to: NSPoint(x: cx + x * s, y: cy + y * s))
        }
        diag.stroke()

        let labelOffset = 96.0 * scale
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14 * scale), .foregroundColor: NSColor(white: 0.4, alpha: 1)]
        func label(_ s: String, _ x: Double, _ y: Double) {
            let ns = s as NSString
            let sz = ns.size(withAttributes: attrs)
            ns.draw(at: NSPoint(x: x - sz.width / 2, y: y - sz.height / 2), withAttributes: attrs)
        }
        label("L+", cx - radius + labelOffset, cy - radius + labelOffset)
        label("R-", cx - radius + labelOffset, cy + radius - labelOffset)
        label("R+", cx + radius - labelOffset, cy - radius + labelOffset)
        label("L-", cx + radius - labelOffset, cy + radius - labelOffset)

        // Static ticks/labels for the correlation (left) + energy (bottom) bars.
        let gray = NSColor(white: 0.5, alpha: 1)
        gray.setStroke()
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale), .foregroundColor: gray]
        let corrTickX = 2.0 * scale
        for tick in [0.5, 0.0, -0.5] {
            let yt = cy - tick * cy
            let p = NSBezierPath(); p.lineWidth = max(1, scale)
            p.move(to: NSPoint(x: corrTickX + 16 * scale, y: yt)); p.line(to: NSPoint(x: corrTickX + 21 * scale, y: yt)); p.stroke()
            (String(format: "%.1f", tick) as NSString).draw(at: NSPoint(x: corrTickX + 23 * scale, y: yt - 7 * scale), withAttributes: tickAttrs)
        }
        let eMax = 18.0, halfW = w / 2, eTickY = h - 2 * scale
        for tick in [-12.0, -6, 0, 6, 12] {
            let xt = cx + (tick / eMax) * halfW
            let p = NSBezierPath(); p.lineWidth = max(1, scale)
            p.move(to: NSPoint(x: xt, y: eTickY - 21 * scale)); p.line(to: NSPoint(x: xt, y: eTickY - 16 * scale)); p.stroke()
            let s = "\(Int(tick))dB" as NSString
            let sz = s.size(withAttributes: tickAttrs)
            s.draw(at: NSPoint(x: xt - sz.width / 2, y: eTickY - 21 * scale - 14 * scale), withAttributes: tickAttrs)
        }
        // Axis labels.
        let white: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14 * scale), .foregroundColor: NSColor.white]
        let bal = "LR Balance" as NSString
        let bsz = bal.size(withAttributes: white)
        bal.draw(at: NSPoint(x: w / 2 - bsz.width / 2, y: h - 2 * scale - bsz.height), withAttributes: white)
        cg.saveGState()
        cg.translateBy(x: 16 * scale, y: cy)
        cg.rotate(by: -.pi / 2)
        let cor = "LR Correlation" as NSString
        let csz = cor.size(withAttributes: white)
        cor.draw(at: NSPoint(x: -csz.width / 2, y: 0), withAttributes: white)
        cg.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        guard let data = cg.data else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = ctx.device.makeTexture(descriptor: desc) else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        backdropTex = tex
    }
}
