import Foundation

/// The three ABI families exposed by the 8 Rust DSP dylibs (see native/README.md).
public enum EffectFamily {
    case io          // shared in-place buffer: io_ptr + process_block
    case splitInOut  // separate buffers: input_ptr/output_ptr + process_block
    case analyzer    // read-only meter: input_ptr + analyze (no audio output)
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

/// One loaded Rust DSP dylib + one live processing state. Loading each module as
/// its own dlopen handle keeps the colliding symbol names (`init`, `process_block`
/// …) in separate namespaces — no Rust source change needed.
public final class EffectModule {
    public let kind: EffectKind
    /// When false the chain passes audio through untouched (kept in the array so
    /// positions stay aligned with the JS pipeline for in-place param updates).
    public var enabled = true
    private let handle: UnsafeMutableRawPointer
    private var state: OpaquePointer?

    private let freeFn: FnFree
    private let processFn: FnProcess?      // nil for analyzer (uses analyzeFn)
    private let analyzeFn: FnProcess?      // analyzer only
    private let ioFn: FnPtr?               // io family
    private let inputFn: FnPtr?            // split / analyzer
    private let outputFn: FnPtr?           // split family

    private let sampleRate: Double
    private let channels: Int
    private let maxBlock: Int

    public init?(kind: EffectKind, dspDir: String, sampleRate: Double, channels: Int, maxBlock: Int) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.channels = min(channels, kind.channels)
        self.maxBlock = maxBlock

        let path = (dspDir as NSString).appendingPathComponent(kind.dylib)
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            FileHandle.standardError.write(Data("dlopen failed for \(path): \(String(cString: dlerror()))\n".utf8))
            return nil
        }
        self.handle = h

        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(h, name) }
        guard let freePtr = sym("free_state") else { return nil }
        self.freeFn = unsafeBitCast(freePtr, to: FnFree.self)

        switch kind.family {
        case .io:
            guard let ip = sym("init"), let proc = sym("process_block"), let io = sym("io_ptr") else { return nil }
            self.processFn = unsafeBitCast(proc, to: FnProcess.self)
            self.ioFn = unsafeBitCast(io, to: FnPtr.self)
            self.analyzeFn = nil; self.inputFn = nil; self.outputFn = nil
            let initFn = unsafeBitCast(ip, to: FnInitIO.self)
            self.state = initFn(Float(sampleRate), UInt32(self.channels), UInt32(maxBlock))
        case .splitInOut:
            guard let ip = sym("init"), let proc = sym("process_block"),
                  let inp = sym("input_ptr"), let outp = sym("output_ptr") else { return nil }
            self.processFn = unsafeBitCast(proc, to: FnProcess.self)
            self.inputFn = unsafeBitCast(inp, to: FnPtr.self)
            self.outputFn = unsafeBitCast(outp, to: FnPtr.self)
            self.ioFn = nil; self.analyzeFn = nil
            if kind.id == "MultibandCompressorPlugin" {
                let initFn = unsafeBitCast(ip, to: FnInitMultiband.self)
                self.state = initFn(Float(sampleRate), UInt32(self.channels), UInt32(maxBlock), 100, 500, 2000, 8000)
            } else { // BrickwallLimiter: os_factor default 1 (no oversampling)
                let initFn = unsafeBitCast(ip, to: FnInitLimiter.self)
                self.state = initFn(Float(sampleRate), UInt32(self.channels), UInt32(maxBlock), 1)
            }
        case .analyzer:
            guard let ip = sym("init"), let an = sym("analyze"), let inp = sym("input_ptr") else { return nil }
            self.analyzeFn = unsafeBitCast(an, to: FnProcess.self)
            self.inputFn = unsafeBitCast(inp, to: FnPtr.self)
            self.processFn = nil; self.ioFn = nil; self.outputFn = nil
            let initFn = unsafeBitCast(ip, to: FnInitAnalyzer.self)
            self.state = initFn(4096) // default FFT points
        }
        if state == nil { return nil }
    }

    deinit {
        if let s = state { freeFn(s) }
        dlclose(handle)
    }

    /// Resolve an arbitrary exported symbol for kind-specific param setters.
    public func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
    public var statePtr: OpaquePointer? { state }

    /// Process `frames` of planar (channel-major, stride = frames) audio in place.
    public func process(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let n = channels * frames
        switch kind.family {
        case .io:
            guard let io = ioFn?(state), let proc = processFn else { return }
            io.update(from: buf, count: n)
            proc(state, UInt32(frames))
            buf.update(from: io, count: n)
        case .splitInOut:
            guard let inp = inputFn?(state), let outp = outputFn?(state), let proc = processFn else { return }
            inp.update(from: buf, count: n)
            proc(state, UInt32(frames))
            buf.update(from: outp, count: n)
        case .analyzer:
            guard let inp = inputFn?(state), let an = analyzeFn else { return }
            inp.update(from: buf, count: n)
            an(state, 0) // read-only; buffer passes through unchanged
        }
    }
}
