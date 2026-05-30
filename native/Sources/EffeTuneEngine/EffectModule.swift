import Foundation

/// ABI families. The first three are Rust DSP dylibs; `jsTap` is a dylib-less
/// display-only analyzer (Level Meter, Spectrogram, …) that taps the audio and
/// lets its JS `onMessage` render — no native DSP.
public enum EffectFamily {
    case io          // shared in-place buffer: io_ptr + process_block
    case splitInOut  // separate buffers: input_ptr/output_ptr + process_block
    case analyzer    // Rust analyzer (Spectrum); we tap audio for the JS FFT
    case jsTap       // pure JS analyzer; native only taps the audio
}

/// Identity + ABI metadata for each effect. `id` matches the EffeTune plugin
/// class identity used by the UI/presets; `dylib` is the file in native/dsp/.
public struct EffectKind {
    public let id: String
    public let dylib: String
    public let family: EffectFamily
    public let channels: Int

    public static let all: [EffectKind] = [
        EffectKind(id: "FifteenBandPEQPlugin",      dylib: "libfifteen_band_peq.dylib",     family: .io,         channels: 8),
        EffectKind(id: "FiveBandPEQPlugin",         dylib: "libfive_band_peq.dylib",        family: .io,         channels: 8),
        EffectKind(id: "TransientShaperPlugin",     dylib: "libtransient_shaper.dylib",     family: .io,         channels: 8),
        EffectKind(id: "SubSynthPlugin",            dylib: "libsub_synth.dylib",            family: .io,         channels: 8),
        EffectKind(id: "AutoLevelerPlugin",         dylib: "libauto_leveler.dylib",         family: .io,         channels: 8),
        EffectKind(id: "BrickwallLimiterPlugin",    dylib: "libbrickwall_limiter.dylib",    family: .splitInOut, channels: 8),
        EffectKind(id: "MultibandCompressorPlugin", dylib: "libmultiband_compressor.dylib", family: .splitInOut, channels: 8),
        EffectKind(id: "SpectrumAnalyzerPlugin",    dylib: "libspectrum_analyzer.dylib",    family: .analyzer,   channels: 2),
        // Display-only JS analyzers (no Rust): native taps the audio, JS renders.
        EffectKind(id: "LevelMeterPlugin",          dylib: "",                              family: .jsTap,      channels: 8),
        EffectKind(id: "SpectrogramPlugin",         dylib: "",                              family: .jsTap,      channels: 2),
        EffectKind(id: "OscilloscopePlugin",        dylib: "",                              family: .jsTap,      channels: 8),
        EffectKind(id: "StereoMeterPlugin",         dylib: "",                              family: .jsTap,      channels: 2),
    ]

    public static func find(_ id: String) -> EffectKind? { all.first { $0.id == id } }
}

// C ABI function-pointer types. Each Rust module exports these via #[no_mangle]
// extern "C"; init/set arity differs per module so we resolve by kind.
private typealias FnInitIO        = @convention(c) (Float, UInt32, UInt32) -> OpaquePointer?
private typealias FnInitLimiter   = @convention(c) (Float, UInt32, UInt32, UInt32) -> OpaquePointer?
private typealias FnInitMultiband = @convention(c) (Float, UInt32, UInt32, Float, Float, Float, Float) -> OpaquePointer?
private typealias FnInitAnalyzer  = @convention(c) (UInt32) -> OpaquePointer?
private typealias FnFree          = @convention(c) (OpaquePointer?) -> Void
private typealias FnPtr           = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<Float>?
private typealias FnProcess       = @convention(c) (OpaquePointer?, UInt32) -> Void

/// One effect instance. For dylib families it owns a dlopen handle + Rust state;
/// for `.jsTap` it owns only a per-channel audio tap.
public final class EffectModule {
    public let kind: EffectKind
    /// When false the chain passes audio through untouched (kept in the array so
    /// positions stay aligned with the JS pipeline for in-place param updates).
    public var enabled = true
    public var pluginId: String?

    private let handle: UnsafeMutableRawPointer?
    private var state: OpaquePointer?
    private let freeFn: FnFree?
    private let processFn: FnProcess?
    private let analyzeFn: FnProcess?
    private let ioFn: FnPtr?
    private let inputFn: FnPtr?
    private let outputFn: FnPtr?

    private let sampleRate: Double
    private let channels: Int
    private let maxBlock: Int

    // Per-channel audio tap (analyzer + jsTap). Fixed max ring so changing the
    // analysis window never reallocates under the RT writer. 16384 covers the
    // Oscilloscope's max window (0.1s × 96kHz = 9600 samples).
    private let tapMax = 16384
    private var tapCh: [UnsafeMutablePointer<Float>] = []
    private var tapPos = 0
    public var spectrumWindow = 4096   // mono-FFT window for Spectrum/Spectrogram
    public var spectrumPosition = 0    // running counter (measurements.bufferPosition)
    private var nanLogged = false
    /// When false, the RT audio tap is skipped (analyzer not visible) — audio
    /// still passes through untouched. Toggled by the bridge per visibility.
    public var tapActive = true

    public init?(kind: EffectKind, dspDir: String, sampleRate: Double, channels: Int, maxBlock: Int) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.channels = min(channels, kind.channels)
        self.maxBlock = maxBlock

        // Dylib-less analyzer: just a per-channel tap.
        if kind.family == .jsTap {
            handle = nil; freeFn = nil; state = nil
            processFn = nil; analyzeFn = nil; ioFn = nil; inputFn = nil; outputFn = nil
            allocateTap()
            return
        }

        let path = (dspDir as NSString).appendingPathComponent(kind.dylib)
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            FileHandle.standardError.write(Data("dlopen failed for \(path): \(String(cString: dlerror()))\n".utf8))
            return nil
        }
        handle = h
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(h, name) }
        guard let freePtr = sym("free_state") else { return nil }
        freeFn = unsafeBitCast(freePtr, to: FnFree.self)

        switch kind.family {
        case .io:
            guard let ip = sym("init"), let proc = sym("process_block"), let io = sym("io_ptr") else { return nil }
            processFn = unsafeBitCast(proc, to: FnProcess.self)
            ioFn = unsafeBitCast(io, to: FnPtr.self)
            analyzeFn = nil; inputFn = nil; outputFn = nil
            state = unsafeBitCast(ip, to: FnInitIO.self)(Float(sampleRate), UInt32(self.channels), UInt32(maxBlock))
        case .splitInOut:
            guard let ip = sym("init"), let proc = sym("process_block"),
                  let inp = sym("input_ptr"), let outp = sym("output_ptr") else { return nil }
            processFn = unsafeBitCast(proc, to: FnProcess.self)
            inputFn = unsafeBitCast(inp, to: FnPtr.self)
            outputFn = unsafeBitCast(outp, to: FnPtr.self)
            ioFn = nil; analyzeFn = nil
            if kind.id == "MultibandCompressorPlugin" {
                state = unsafeBitCast(ip, to: FnInitMultiband.self)(Float(sampleRate), UInt32(self.channels), UInt32(maxBlock), 100, 500, 2000, 8000)
            } else { // BrickwallLimiter: os_factor default 1
                state = unsafeBitCast(ip, to: FnInitLimiter.self)(Float(sampleRate), UInt32(self.channels), UInt32(maxBlock), 1)
            }
        case .analyzer:
            guard let ip = sym("init"), let an = sym("analyze"), let inp = sym("input_ptr") else { return nil }
            analyzeFn = unsafeBitCast(an, to: FnProcess.self)
            inputFn = unsafeBitCast(inp, to: FnPtr.self)
            processFn = nil; ioFn = nil; outputFn = nil
            state = unsafeBitCast(ip, to: FnInitAnalyzer.self)(12) // FFT exponent (2^12)
            allocateTap()
        case .jsTap:
            return nil // handled above
        }
        if state == nil { return nil }
    }

    private func allocateTap() {
        tapCh = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: tapMax)
            p.initialize(repeating: 0, count: tapMax)
            return p
        }
    }

    deinit {
        if let s = state, let free = freeFn { free(s) }
        tapCh.forEach { $0.deallocate() }
        if let h = handle { dlclose(h) }
    }

    /// Resolve an exported symbol (dylib families only) for kind-specific setters.
    public func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let h = handle else { return nil }
        return dlsym(h, name)
    }
    public var statePtr: OpaquePointer? { state }

    /// Scalar meters in the JS `measurements` shape, or nil if none.
    public func meters() -> [String: Double]? {
        typealias GetF = @convention(c) (OpaquePointer?) -> Float
        func f(_ name: String) -> Double? {
            guard let s = symbol(name) else { return nil }
            return Double(unsafeBitCast(s, to: GetF.self)(state))
        }
        switch kind.id {
        case "TransientShaperPlugin":
            guard let g = f("last_gain_db") else { return nil }
            return ["gain": g]
        case "AutoLevelerPlugin":
            guard let i = f("last_input_lufs"), let o = f("last_output_lufs") else { return nil }
            return ["inputLufs": i, "outputLufs": o]
        default:
            return nil
        }
    }

    /// Multiband Compressor per-band gain reduction (5 values), or nil.
    public func multibandGainReductions() -> [Float]? {
        guard kind.id == "MultibandCompressorPlugin", let s = symbol("gain_reductions_ptr") else { return nil }
        guard let p = unsafeBitCast(s, to: FnPtr.self)(state) else { return nil }
        return (0..<5).map { p[$0].isFinite ? p[$0] : 0 }
    }

    /// Process `frames` of planar (channel-major, stride = frames) audio in place.
    public func process(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let n = channels * frames
        switch kind.family {
        case .io:
            guard let io = ioFn?(state), let proc = processFn else { return }
            io.update(from: buf, count: n)
            proc(state, UInt32(frames))
            buf.update(from: io, count: n)
            sanitize(buf, n)
        case .splitInOut:
            guard let inp = inputFn?(state), let outp = outputFn?(state), let proc = processFn else { return }
            inp.update(from: buf, count: n)
            proc(state, UInt32(frames))
            buf.update(from: outp, count: n)
            sanitize(buf, n)
        case .analyzer, .jsTap:
            // Capture per-channel samples; audio passes through unchanged.
            // Skip the capture entirely when the analyzer isn't visible.
            if !tapActive { return }
            if tapCh.count < channels { return }
            // Chunked copy (≤2 segments around the wrap) instead of per-sample modulo.
            let start = tapPos % tapMax
            let first = min(frames, tapMax - start)
            for c in 0..<channels {
                let src = buf + c * frames
                tapCh[c].advanced(by: start).update(from: src, count: first)
                if first < frames {
                    tapCh[c].update(from: src + first, count: frames - first)
                }
            }
            tapPos = (tapPos + frames) % tapMax
            spectrumPosition += frames
        }
    }

    /// Replace non-finite output with 0 so one bad effect can't push NaN/Inf
    /// into the speakers or downstream analyzers. Logs the culprit once.
    private func sanitize(_ buf: UnsafeMutablePointer<Float>, _ n: Int) {
        var bad = false
        for i in 0..<n where !buf[i].isFinite { buf[i] = 0; bad = true }
        if bad && !nanLogged { nanLogged = true; nlog("non-finite output from \(kind.id) — sanitized to 0") }
    }

    private func ringStart(_ nWin: Int) -> Int { (tapPos - nWin + tapMax) % tapMax }

    /// Mono-averaged last `spectrumWindow` samples for Spectrum/Spectrogram FFT.
    public func spectrumSnapshot() -> [Float]? {
        guard !tapCh.isEmpty else { return nil }
        let nWin = min(spectrumWindow, tapMax)
        let inv = 1.0 / Float(tapCh.count)
        var out = [Float](repeating: 0, count: nWin)
        let start = ringStart(nWin)
        for i in 0..<nWin {
            let idx = (start + i) % tapMax
            var s: Float = 0
            for ring in tapCh { s += ring[idx] }
            let v = s * inv
            out[i] = v.isFinite ? v : 0
        }
        return out
    }

    /// Run the Rust FFT (Spectrum Analyzer dylib) on the captured window and
    /// return the (spectrum dB, peaks dB) halves directly, so the JS analyzer can
    /// just draw — no per-frame FFT in the web view, and half the bytes to send.
    /// `decay` is the per-update peak fall (JS uses 20·deltaTime).
    public func spectrumComputed(decay: Float) -> (spectrum: [Float], peaks: [Float])? {
        typealias FnAnalyze = @convention(c) (OpaquePointer?, UInt32) -> Void
        typealias FnDecay   = @convention(c) (OpaquePointer?, Float) -> Void
        guard kind.id == "SpectrumAnalyzerPlugin",
              let snap = spectrumSnapshot(),
              let inPtr = symbol("input_ptr"), let anPtr = symbol("analyze"),
              let specPtr = symbol("spectrum_ptr"), let pkPtr = symbol("peaks_ptr"),
              let upPtr = symbol("update_peaks") else { return nil }
        let fftSize = snap.count
        // The Rust state is init'd at pt=12 (4096). If the UI picked another FFT
        // size, fall back to the time-domain path (JS FFT) to avoid a size mismatch.
        guard fftSize == 4096 else { return nil }
        let half = fftSize / 2
        guard let input = unsafeBitCast(inPtr, to: FnPtr.self)(state) else { return nil }
        // The snapshot is chronological (oldest-first), so buffer_position = 0
        // matches the Rust window read (mirrors the JS WASM path).
        input.update(from: snap, count: fftSize)
        unsafeBitCast(anPtr, to: FnAnalyze.self)(state, 0)
        unsafeBitCast(upPtr, to: FnDecay.self)(state, decay)
        guard let sp = unsafeBitCast(specPtr, to: FnPtr.self)(state),
              let pk = unsafeBitCast(pkPtr, to: FnPtr.self)(state) else { return nil }
        var spectrum = [Float](repeating: 0, count: half)
        var peaks = [Float](repeating: 0, count: half)
        for i in 0..<half {
            spectrum[i] = sp[i].isFinite ? sp[i] : -144
            peaks[i] = pk[i].isFinite ? pk[i] : -144
        }
        return (spectrum, peaks)
    }

    /// The full per-sample mono ring (ring order) + write head, for the
    /// Oscilloscope, which indexes the ring by absolute position.
    public func monoRingSnapshot() -> (buffer: [Float], position: Int)? {
        guard !tapCh.isEmpty else { return nil }
        let inv = 1.0 / Float(tapCh.count)
        var out = [Float](repeating: 0, count: tapMax)
        for i in 0..<tapMax {
            var s: Float = 0
            for ring in tapCh { s += ring[i] }
            let v = s * inv
            out[i] = v.isFinite ? v : 0
        }
        return (out, tapPos)
    }

    // Oscilloscope auto-sweep trigger: a fresh trigger index every `autoSec`.
    private var oscTriggerIndex = 0
    private var oscLastTriggerSample = -1 << 30
    public func oscilloscopeTriggerIndex(autoSec: Double) -> Int {
        let span = max(1, Int(sampleRate * autoSec))
        if spectrumPosition - oscLastTriggerSample >= span {
            oscTriggerIndex = tapPos
            oscLastTriggerSample = spectrumPosition
        }
        return oscTriggerIndex
    }

    /// Stereo Meter data over the last `window` samples: x=R-L, y=L+R Lissajous
    /// plus a 360-bin angle peak histogram (peak-over-window; decay is implicit).
    public func stereoSnapshot(window: Int) -> (x: [Float], y: [Float], peak: [Float], position: Int)? {
        guard !tapCh.isEmpty else { return nil }
        let n = min(max(window, 1), tapMax)
        let left = tapCh[0]
        let right = tapCh.count > 1 ? tapCh[1] : tapCh[0]
        let start = ringStart(n)
        var x = [Float](repeating: 0, count: n)
        var y = [Float](repeating: 0, count: n)
        var peak = [Float](repeating: 0, count: 360)
        let radToDeg: Float = 180.0 / .pi
        for i in 0..<n {
            let idx = (start + i) % tapMax
            let l = left[idx], r = right[idx]
            let xv = r - l, yv = l + r
            x[i] = xv.isFinite ? xv : 0
            y[i] = yv.isFinite ? yv : 0
            let angle = -atan2(yv, xv) * radToDeg
            let bin = ((Int(angle.rounded()) % 360) + 360) % 360
            let mag = (xv * xv + yv * yv).squareRoot()
            if mag.isFinite && mag > peak[bin] { peak[bin] = mag }
        }
        return (x, y, peak, n - 1)
    }

    /// Per-channel peak (linear) over the last `window` samples. For Level Meter.
    public func channelPeaks(window: Int) -> [Float] {
        guard !tapCh.isEmpty else { return [] }
        let nWin = min(max(window, 1), tapMax)
        let start = ringStart(nWin)
        return tapCh.map { ring in
            var peak: Float = 0
            for i in 0..<nWin {
                let v = abs(ring[(start + i) % tapMax])
                if v.isFinite && v > peak { peak = v }
            }
            return peak
        }
    }
}
