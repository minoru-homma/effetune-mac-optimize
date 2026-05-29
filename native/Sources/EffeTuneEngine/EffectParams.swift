import Foundation

// Per-effect parameter marshalling. Each Rust module's setter is a fixed-arity
// extern "C" function; the JS/preset parameter ids map to these argument orders.
// These typed wrappers ARE the marshalling table the native<->JS bridge will use.

private typealias Set7  = @convention(c) (OpaquePointer?, Float, Float, Float, Float, Float, Float, Float) -> Void
private typealias Set8  = @convention(c) (OpaquePointer?, Float, Float, Float, Float, Float, Float, Float, Float) -> Void
private typealias Set5  = @convention(c) (OpaquePointer?, Float, Float, Float, Float, Float) -> Void
private typealias SetBand = @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, Float, Float, Float) -> Void
private typealias SetBandComp = @convention(c) (OpaquePointer?, UInt32, Float, Float, Float, Float, Float, Float) -> Void
private typealias SetXover = @convention(c) (OpaquePointer?, Float, Float, Float, Float) -> Void

extension EffectModule {
    private func fn5(_ name: String) -> Set5? { symbol(name).map { unsafeBitCast($0, to: Set5.self) } }
    private func fn7(_ name: String) -> Set7? { symbol(name).map { unsafeBitCast($0, to: Set7.self) } }
    private func fn8(_ name: String) -> Set8? { symbol(name).map { unsafeBitCast($0, to: Set8.self) } }

    /// Transient Shaper: fastAtk, fastRel, slowAtk, slowRel, transientGain, sustainGain, smoothing (all ms / dB)
    public func setTransient(_ p: [Float]) {
        guard p.count == 7, let f = fn7("set_params") else { return }
        f(statePtr, p[0], p[1], p[2], p[3], p[4], p[5], p[6])
    }

    /// Auto Leveler: targetLufs, windowMs, maxGainDb, minGainDb, attackMs, releaseMs, noiseGateDb
    public func setAutoLeveler(_ p: [Float]) {
        guard p.count == 7, let f = fn7("set_params") else { return }
        f(statePtr, p[0], p[1], p[2], p[3], p[4], p[5], p[6])
    }

    /// Sub Synth: subLvl, dryLvl, subLpfFreq, subLpfSlope, subHpfFreq, subHpfSlope, dryHpfFreq, dryHpfSlope
    public func setSubSynth(_ p: [Float]) {
        guard p.count == 8, let f = fn8("set_params") else { return }
        f(statePtr, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])
    }

    /// Brickwall Limiter: thresholdDb, releaseMs, lookaheadMs, inputGainDb, marginDb
    public func setLimiter(_ p: [Float]) {
        guard p.count == 5, let f = fn5("set_params") else { return }
        f(statePtr, p[0], p[1], p[2], p[3], p[4])
    }

    /// PEQ band (5- and 15-band share `set_band`): band index, enabled, typeId, freqHz, gainDb, q
    public func setPeqBand(_ band: Int, enabled: Bool, typeId: Int, freq: Float, gainDb: Float, q: Float) {
        guard let s = symbol("set_band") else { return }
        let f = unsafeBitCast(s, to: SetBand.self)
        f(statePtr, UInt32(band), enabled ? 1 : 0, UInt32(typeId), freq, gainDb, q)
    }

    /// Multiband Compressor crossovers: f1..f4 (Hz)
    public func setMultibandCrossovers(_ f1: Float, _ f2: Float, _ f3: Float, _ f4: Float) {
        guard let s = symbol("set_crossover_freqs") else { return }
        unsafeBitCast(s, to: SetXover.self)(statePtr, f1, f2, f3, f4)
    }

    /// Multiband Compressor band: index, thresholdDb, ratio, attackMs, releaseMs, kneeDb, makeupDb
    public func setMultibandBand(_ band: Int, _ p: [Float]) {
        guard p.count == 6, let s = symbol("set_band_params") else { return }
        let f = unsafeBitCast(s, to: SetBandComp.self)
        f(statePtr, UInt32(band), p[0], p[1], p[2], p[3], p[4], p[5])
    }
}
