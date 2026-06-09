import AppKit
import Metal
import QuartzCore
import CoreVideo
import EffeTuneEngine

/// One analyzer's native renderer. Owns a transparent CAMetalLayer positioned
/// over the matching DOM element; `render` pulls data straight from the native
/// EffectModule (no JS/IPC).
protocol AnalyzerRenderer: AnyObject {
    var layer: CALayer { get }
    func render(module: EffectModule, params: [String: Float], sampleRate: Double)
}

/// Transparent NSView stacked above the WKWebView. Hosts the analyzer
/// CAMetalLayers and passes all mouse events through to the web view beneath.
final class OverlayHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

/// Manages native Metal overlays for analyzers and a single CVDisplayLink that
/// drives their rendering. Geometry is fed from JS (`setOverlayRect`), data is
/// pulled from the engine each display-synced frame.
///
/// Pilot scope: Spectrum Analyzer only. Adding an analyzer type = a new
/// AnalyzerRenderer + a `makeRenderer` case.
final class AnalyzerOverlay {
    private weak var hostView: OverlayHostView?
    private let ctx: MetalContext?

    private final class Entry {
        let id: String
        let type: String
        let renderer: AnalyzerRenderer
        var params: [String: Float]
        init(id: String, type: String, renderer: AnalyzerRenderer, params: [String: Float]) {
            self.id = id; self.type = type; self.renderer = renderer; self.params = params
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var displayLink: CVDisplayLink?

    /// Resolve the live EffectModule for a plugin id (set by AudioBridge).
    var moduleProvider: ((String) -> EffectModule?)?
    /// Current engine sample rate (set by AudioBridge).
    var sampleRateProvider: (() -> Double)?

    // Max drawable scale (1.0 = CSS resolution). Lower = cheaper present on Retina.
    static let maxDrawableScale: CGFloat = {
        if let s = ProcessInfo.processInfo.environment["EFFETUNE_OVERLAY_SCALE"], let v = Double(s), v > 0 {
            return CGFloat(v)
        }
        return 1.0
    }()

    init(hostView: OverlayHostView) {
        self.hostView = hostView
        self.ctx = MetalContext()
        if ctx == nil { nlog("AnalyzerOverlay: Metal unavailable, native overlay disabled") }
    }

    /// True if this id is rendered natively → the bridge skips its meter push.
    func hasActiveEntry(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[id] != nil
    }

    private func makeRenderer(type: String, ctx: MetalContext) -> AnalyzerRenderer? {
        switch type {
        case "SpectrumAnalyzerPlugin": return SpectrumRenderer(ctx: ctx)
        case "SpectrogramPlugin": return SpectrogramRenderer(ctx: ctx)
        case "OscilloscopePlugin": return OscilloscopeRenderer(ctx: ctx)
        case "StereoMeterPlugin": return StereoMeterRenderer(ctx: ctx)
        case "LevelMeterPlugin": return LevelMeterRenderer(ctx: ctx)
        default: return nil   // not yet ported; JS keeps drawing it
        }
    }

    /// Upsert an analyzer overlay at the given web-viewport rect (CSS px, top-left
    /// origin). Called on the main thread from the bridge.
    func setRect(id: String, type: String, x: Double, y: Double, w: Double, h: Double, params: [String: Float]) {
        guard let ctx = ctx, let host = hostView, w > 0, h > 0 else { return }
        let entry: Entry
        if let existing = entries[id], existing.type == type {
            existing.params = params
            entry = existing
        } else {
            entries[id]?.renderer.layer.removeFromSuperlayer()
            guard let renderer = makeRenderer(type: type, ctx: ctx) else { return }
            let e = Entry(id: id, type: type, renderer: renderer, params: params)
            host.wantsLayer = true
            host.layer?.addSublayer(renderer.layer)
            lock.lock(); entries[id] = e; lock.unlock()
            entry = e
            nlog("overlay: native render START id=\(id) \(type) (meter push suppressed)")
        }

        // Cap the drawable resolution. On a Retina (2×) display the per-frame
        // present/composite cost scales with pixel area, so rendering the spectrum
        // at the native 2× (4× the pixels) dominated CPU. A thin line graph looks
        // fine at 1× (CSS resolution); cap there. Tunable via EFFETUNE_OVERLAY_SCALE.
        let maxScale = AnalyzerOverlay.maxDrawableScale
        let scale = min(host.window?.backingScaleFactor ?? 1.0, maxScale)
        let hostH = host.bounds.height
        let layer = entry.renderer.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // immediate move (no scroll lag from CA animation)
        layer.frame = CGRect(x: x, y: hostH - y - h, width: w, height: h) // y-flip to AppKit
        layer.contentsScale = scale             // renderer derives pixel size from bounds × scale
        CATransaction.commit()

        startLinkIfNeeded()
    }

    /// Remove an analyzer overlay (hidden / collapsed / removed). Main thread.
    func remove(id: String) {
        lock.lock()
        let e = entries.removeValue(forKey: id)
        let empty = entries.isEmpty
        lock.unlock()
        e?.renderer.layer.removeFromSuperlayer()
        if e != nil { nlog("overlay: native render STOP id=\(id)") }
        if empty { stopLink() }
    }

    func removeAll() {
        lock.lock()
        let all = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        all.forEach { $0.renderer.layer.removeFromSuperlayer() }
        stopLink()
    }

    // MARK: CVDisplayLink

    // ONE persistent display link for the overlay's lifetime; we only Start/Stop
    // it. (Recreating per visibility toggle leaked CoreVideo IO threads.)
    private var linkRunning = false

    private func startLinkIfNeeded() {
        if displayLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let dl = link else { return }
            let ctxPtr = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(dl, { (_, _, _, _, _, userInfo) -> CVReturn in
                let overlay = Unmanaged<AnalyzerOverlay>.fromOpaque(userInfo!).takeUnretainedValue()
                overlay.renderTick()
                return kCVReturnSuccess
            }, ctxPtr)
            displayLink = dl
        }
        if let dl = displayLink, !linkRunning { CVDisplayLinkStart(dl); linkRunning = true }
    }

    private func stopLink() {
        if let dl = displayLink, linkRunning { CVDisplayLinkStop(dl); linkRunning = false }
    }

    /// Display-synced render of every active overlay. Runs on the CVDisplayLink
    /// thread; touches only thread-safe reads (snapshotted entry list, engine
    /// chain reference, immutable per-frame layer geometry).
    /// autoreleasepool is required: Metal API calls (makeCommandBuffer etc.) return
    /// ObjC autoreleased objects. The CVDisplayLink thread has no RunLoop to drain
    /// the pool automatically, so without this wrapper they accumulate indefinitely.
    private func renderTick() {
        autoreleasepool {
            lock.lock(); let items = Array(entries.values); lock.unlock()
            if items.isEmpty { return }
            let sr = sampleRateProvider?() ?? 48000
            for e in items {
                guard let module = moduleProvider?(e.id) else { continue }
                e.renderer.render(module: module, params: e.params, sampleRate: sr)
            }
        }
    }
}
