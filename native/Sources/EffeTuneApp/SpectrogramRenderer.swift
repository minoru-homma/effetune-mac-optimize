import Foundation
import Metal
import QuartzCore
import AppKit
import IOSurface
import EffeTuneEngine

/// Triple-buffered IOSurface presentation for a plain CALayer. Bypasses
/// CAMetalLayer's CAMetalDrawable / FramePacing path. Shared by analyzer renderers.
final class SurfacePresenter {
    let layer = CALayer()
    private let device: MTLDevice
    private let format: MTLPixelFormat
    private struct S { let surf: IOSurfaceRef; let tex: MTLTexture }
    private var surfaces: [S] = []
    private var w = 0, h = 0, idx = 0
    private var current: S?

    init(device: MTLDevice, format: MTLPixelFormat) {
        self.device = device; self.format = format
        layer.isOpaque = true
        layer.contentsGravity = .resize
    }

    /// The render target for this frame at `width`×`height` px (rebuilds on resize).
    func target(width: Int, height: Int) -> MTLTexture? {
        if width != w || height != h || surfaces.isEmpty { rebuild(width: width, height: height) }
        guard !surfaces.isEmpty else { return nil }
        let s = surfaces[idx % surfaces.count]; idx += 1; current = s
        return s.tex
    }

    /// Hand the just-rendered surface to the layer once the GPU finishes.
    func present(_ cmd: MTLCommandBuffer) {
        guard let s = current else { return }
        let lyr = layer
        cmd.addCompletedHandler { _ in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            lyr.contents = s.surf
            CATransaction.commit()
        }
    }

    private func rebuild(width: Int, height: Int) {
        surfaces.removeAll()
        let props: [CFString: Any] = [
            kIOSurfaceWidth: width, kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: width * 4,
            kIOSurfacePixelFormat: 0x42475241,  // 'BGRA'
        ]
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        for _ in 0..<3 {
            guard let surf = IOSurfaceCreate(props as CFDictionary),
                  let tex = device.makeTexture(descriptor: desc, iosurface: surf, plane: 0) else { continue }
            surfaces.append(S(surf: surf, tex: tex))
        }
        w = width; h = height; idx = 0
    }
}

/// Native Metal renderer for the Spectrogram. Replaces the per-frame JS FFT +
/// `putImageData` (the heaviest CPU analyzer draw) with a native FFT + a scrolling
/// GPU heatmap. Mirrors plugins/analyzer/spectrogram.js.
final class SpectrogramRenderer: AnalyzerRenderer {
    var layer: CALayer { presenter.layer }
    private let ctx: MetalContext
    private let presenter: SurfacePresenter

    // FFT state (rebuilt when the window/pt size changes).
    private var fftN = 0
    private var ptBits = 0
    private var cosT: [Float] = [], sinT: [Float] = [], win: [Float] = []
    private var re: [Float] = [], im: [Float] = []
    private var spectrum: [Float] = []
    private let corrDC = Float(10 * log10(4.0))
    private let corrAC = Float(10 * log10(16.0))

    // Scrolling heatmap history (1024 time columns × 256 freq rows).
    private let cols = 1024, rows = 256
    private var heatmap: MTLTexture?
    private var head = 0
    private var column = [UInt8](repeating: 0, count: 256 * 4)

    // Static grid/label overlay (transparent), rebuilt on size / sampleRate change.
    private var overlayTex: MTLTexture?
    private var overlayKey = ""

    private let minFrameInterval = 1.0 / 30.0
    private var lastPosition = -1
    private var lastRenderTime: Double = 0

    init(ctx: MetalContext) {
        self.ctx = ctx
        self.presenter = SurfacePresenter(device: ctx.device, format: ctx.pixelFormat)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat, width: cols, height: rows, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        heatmap = ctx.device.makeTexture(descriptor: d)
        // Clear to opaque black so unwritten columns aren't garbage.
        if let hm = heatmap {
            var black = [UInt8](repeating: 0, count: cols * rows * 4)
            for i in stride(from: 3, to: black.count, by: 4) { black[i] = 255 }
            black.withUnsafeBytes { p in
                hm.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0,
                           withBytes: p.baseAddress!, bytesPerRow: cols * 4)
            }
        }
    }

    func render(module: EffectModule, params: [String: Float], sampleRate: Double) {
        let dr = params["dr"] ?? -96
        let now = CACurrentMediaTime()
        if lastRenderTime > 0 && now - lastRenderTime < minFrameInterval - 0.002 { return }
        let pos = module.spectrumPosition
        if pos == lastPosition { return }
        lastPosition = pos
        lastRenderTime = now

        guard let snap = module.spectrumSnapshot(), snap.count >= 2,
              (snap.count & (snap.count - 1)) == 0 else { return }   // power of two
        if snap.count != fftN { rebuildFFT(snap.count) }
        computeColumn(snap: snap, dr: dr, sampleRate: sampleRate)

        // Write the new column at `head`, advance the ring.
        if let hm = heatmap {
            column.withUnsafeBytes { p in
                hm.replace(region: MTLRegionMake2D(head, 0, 1, rows), mipmapLevel: 0,
                           withBytes: p.baseAddress!, bytesPerRow: 4)
            }
        }
        head = (head + 1) % cols

        let scale = presenter.layer.contentsScale
        let drawW = Int((presenter.layer.bounds.width * scale).rounded())
        let drawH = Int((presenter.layer.bounds.height * scale).rounded())
        guard drawW > 1, drawH > 0, let hm = heatmap else { return }

        let key = "\(drawW)x\(drawH)@\(Int(sampleRate))"
        if key != overlayKey { rebuildOverlay(width: drawW, height: drawH, sampleRate: sampleRate); overlayKey = key }

        guard let target = presenter.target(width: drawW, height: drawH),
              let cmd = ctx.queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let rp = cmd.makeRenderCommandEncoder(descriptor: pass) {
            // Heatmap (opaque, scrolling).
            rp.setRenderPipelineState(ctx.heatPipeline)
            var hparm: [UInt32] = [UInt32(head), UInt32(cols)]
            rp.setFragmentBytes(&hparm, length: 8, index: 0)
            rp.setFragmentTexture(hm, index: 0)
            rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            // Grid + labels overlay (premultiplied alpha over the heatmap).
            if let ov = overlayTex {
                rp.setRenderPipelineState(ctx.blitBlendPipeline)
                rp.setFragmentTexture(ov, index: 0)
                rp.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            rp.endEncoding()
        }
        presenter.present(cmd)
        cmd.commit()
    }

    // MARK: FFT (ported from spectrogram.js so dB output matches exactly)

    private func rebuildFFT(_ n: Int) {
        fftN = n; ptBits = Int(log2(Double(n)).rounded())
        cosT = [Float](repeating: 0, count: n); sinT = cosT; win = cosT
        for i in 0..<n {
            let a = -2.0 * Double.pi * Double(i) / Double(n)
            cosT[i] = Float(cos(a)); sinT[i] = Float(sin(a))
            win[i] = Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n))))
        }
        re = [Float](repeating: 0, count: n); im = re
        spectrum = [Float](repeating: -144, count: n / 2)
    }

    private func reverseBits(_ x0: Int, _ bits: Int) -> Int {
        var x = x0, r = 0
        for _ in 0..<bits { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }

    private func computeColumn(snap: [Float], dr: Float, sampleRate: Double) {
        let n = fftN, half = n / 2
        for i in 0..<n { re[i] = snap[i] * win[i]; im[i] = 0 }
        // FFT (in place)
        for i in 0..<n { let j = reverseBits(i, ptBits); if j > i { re.swapAt(i, j); im.swapAt(i, j) } }
        var size = 2, stage = 1
        while size <= n {
            let halfS = size >> 1, shift = ptBits - stage
            var i = 0
            while i < n {
                var j = i, k = 0
                while j < i + halfS {
                    let ti = (k << shift) & (n - 1)
                    let c = cosT[ti], s = sinT[ti]
                    let tr = re[j + halfS] * c - im[j + halfS] * s
                    let tii = re[j + halfS] * s + im[j + halfS] * c
                    re[j + halfS] = re[j] - tr; im[j + halfS] = im[j] - tii
                    re[j] += tr; im[j] += tii
                    j += 1; k += 1
                }
                i += size
            }
            size <<= 1; stage += 1
        }
        let fftNorm = Float(-20 * log10(Double(n)))
        for i in 0..<half {
            let power = re[i] * re[i] + im[i] * im[i]
            var db = 10 * log10f(power + 1e-24) + (i == 0 ? corrDC : corrAC) + fftNorm
            if db < -144 { db = -144 }
            spectrum[i] = db
        }
        // Map 256 rows (high freq at top) to color.
        let logMin = log10(20.0), logRange = log10(40000.0) - logMin
        let nyquist = sampleRate / 2
        for y in 0..<rows {
            var db: Float = -144
            if logRange > 0 && sampleRate > 0 {
                let freq = pow(10.0, log10(40000.0) - (Double(y) / Double(rows - 1)) * logRange)
                if freq >= 20 && freq <= nyquist {
                    let binF = freq * Double(n) / sampleRate
                    let b1 = Int(binF)
                    if b1 < half {
                        let b2 = min(b1 + 1, half - 1)
                        let frac = Float(binF - Double(b1))
                        db = spectrum[b1] + (spectrum[b2] - spectrum[b1]) * frac
                    }
                }
            }
            let (r, g, b) = dbToColor(db, dr: dr)
            let o = y * 4
            column[o] = b; column[o + 1] = g; column[o + 2] = r; column[o + 3] = 255
        }
    }

    // 7-stop colormap, brightness 0.75 (matches spectrogram.js dbToColor).
    private static let stops: [(Float, Float, Float, Float)] = [
        (0.000, 0, 0, 0), (0.166, 0, 0, 255), (0.333, 0, 255, 255), (0.500, 0, 255, 0),
        (0.666, 255, 255, 0), (0.833, 255, 0, 0), (1.000, 255, 255, 255),
    ]
    private func dbToColor(_ db0: Float, dr: Float) -> (UInt8, UInt8, UInt8) {
        let db = db0 > 0 ? 0 : db0
        let norm = (db - dr) / (-dr)
        let v = max(0, min(1, norm))
        let s = SpectrogramRenderer.stops
        var lo = s[0], hi = s[s.count - 1]
        for i in 0..<(s.count - 1) where v >= s[i].0 && v <= s[i + 1].0 { lo = s[i]; hi = s[i + 1]; break }
        let range = hi.0 - lo.0
        let t = range == 0 ? 0 : (v - lo.0) / range
        let bright: Float = 0.75
        let r = UInt8((lo.1 + (hi.1 - lo.1) * t) * bright)
        let g = UInt8((lo.2 + (hi.2 - lo.2) * t) * bright)
        let b = UInt8((lo.3 + (hi.3 - lo.3) * t) * bright)
        return (r, g, b)
    }

    // MARK: grid + axis labels overlay (transparent, drawn once per size/SR)

    private func rebuildOverlay(width: Int, height: Int, sampleRate: Double) {
        guard width > 0, height > 0 else { return }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        let ns = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let w = CGFloat(width), h = CGFloat(height)
        let scale = max(0.25, w / 2048.0)   // labels/grid authored against the 2048px reference
        cg.clear(CGRect(x: 0, y: 0, width: w, height: h))   // transparent base

        let minF = 20.0, maxF = 40000.0
        let logMin = log10(minF), logRange = log10(maxF) - logMin
        let nyq = sampleRate / 2
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24 * scale), .foregroundColor: NSColor(white: 0.8, alpha: 1)]
        NSColor(white: 0.53, alpha: 1).setStroke()   // #888
        if sampleRate > 0 && nyq > minF {
            var freqs = [20.0, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000].filter { $0 >= minF && $0 <= maxF }
            if !freqs.contains(minF) { freqs.append(minF) }
            if !freqs.contains(maxF) { freqs.append(maxF) }
            freqs = Array(Set(freqs)).sorted()
            for f in freqs {
                // freqToY: high freq -> y 0 (top), low -> 255 (bottom); scaled to h.
                let yRow = 255.0 - (255.0 * (log10(max(minF, min(f, maxF))) - logMin) / logRange)
                let y = (yRow / 255.0) * h
                let p = NSBezierPath(); p.lineWidth = max(1, 2 * scale)
                p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: w, y: y)); p.stroke()
                if y > 15 * scale && y < h - 15 * scale {
                    let s = (f >= 1000 ? "\((f/1000).cleanString)k" : "\(Int(f))") as NSString
                    s.draw(at: NSPoint(x: 8 * scale, y: y - 14 * scale), withAttributes: labelAttrs)
                }
            }
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28 * scale), .foregroundColor: NSColor.white]
        let t = "Time" as NSString
        let ts = t.size(withAttributes: titleAttrs)
        t.draw(at: NSPoint(x: w / 2 - ts.width / 2, y: h - 10 * scale - ts.height), withAttributes: titleAttrs)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = cg.data else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = ctx.device.makeTexture(descriptor: desc) else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4)
        overlayTex = tex
    }
}
