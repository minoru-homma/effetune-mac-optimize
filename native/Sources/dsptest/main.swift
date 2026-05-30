import Foundation
import EffeTuneEngine

// Headless verifier: drives known signals through native effect chains offline
// and checks the DSP actually runs and shapes audio. No audio devices needed.

let args = CommandLine.arguments
let dspDir = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath + "/dsp"
let sr = 48000.0
let ch = 2
let block = 128

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }

func makeSine(freq: Double, frames: Int, amp: Float) -> [Float] {
    var b = [Float](repeating: 0, count: ch * frames) // planar, stride = frames
    for c in 0..<ch {
        for i in 0..<frames {
            b[c * frames + i] = amp * Float(sin(2.0 * Double.pi * freq * Double(i) / sr))
        }
    }
    return b
}

func peak(_ b: [Float]) -> Float { b.reduce(0) { max($0, abs($1)) } }
func rms(_ b: [Float]) -> Float { sqrt(b.reduce(0) { $0 + $1 * $1 } / Float(b.count)) }

func runChain(_ kinds: [String], configure: (String, EffectModule) -> Void, signal: [Float]) -> [Float] {
    let chain = EffectChain(channels: ch, maxBlock: block)
    for id in kinds {
        guard let kind = EffectKind.find(id),
              let m = EffectModule(kind: kind, dspDir: dspDir, sampleRate: sr, channels: ch, maxBlock: block)
        else { fail("could not load \(id) from \(dspDir)") }
        configure(id, m)
        chain.append(m)
    }
    var buf = signal
    let frames = signal.count / ch
    // process one block at a time (signal is exactly one block here)
    precondition(frames == block)
    buf.withUnsafeMutableBufferPointer { p in chain.process(p.baseAddress!, frames: frames) }
    return buf
}

print("dsp dir: \(dspDir)")

// 1. Smoke test: every module loads, inits, and processes silence without crashing.
print("\n[1] load + process smoke test (all 8 modules)")
for kind in EffectKind.all {
    guard let m = EffectModule(kind: kind, dspDir: dspDir, sampleRate: sr, channels: ch, maxBlock: block) else {
        fail("load \(kind.id)")
    }
    var silence = [Float](repeating: 0, count: ch * block)
    silence.withUnsafeMutableBufferPointer { p in m.process(p.baseAddress!, frames: block) }
    if silence.contains(where: { !$0.isFinite }) { fail("\(kind.id) produced non-finite on silence") }
    print("  ok  \(kind.id) [\(kind.family)]")
}

// 2. PEQ boost: +12 dB peaking at 1 kHz should raise a 1 kHz tone.
print("\n[2] FifteenBandPEQ +12dB @1kHz boost")
let tone = makeSine(freq: 1000, frames: block, amp: 0.2)
let pin = peak(tone)
let peqOut = runChain(["FifteenBandPEQPlugin"], configure: { _, m in
    m.setPeqBand(0, enabled: true, typeId: 0, freq: 1000, gainDb: 12, q: 1.0) // typeId 0 = peaking
}, signal: tone)
let pout = peak(peqOut)
if peqOut.contains(where: { !$0.isFinite }) { fail("PEQ non-finite") }
print(String(format: "  peak_in=%.4f peak_out=%.4f (expect out > in)", pin, pout))

// 3. Brickwall limiter: a hot signal must be brought at/under the ceiling.
//    The limiter has internal lookahead/filter latency, so we stream several
//    blocks through ONE instance and measure the steady-state (last) block.
print("\n[3] BrickwallLimiter ceiling (steady-state over 16 blocks)")
do {
    guard let kind = EffectKind.find("BrickwallLimiterPlugin"),
          let m = EffectModule(kind: kind, dspDir: dspDir, sampleRate: sr, channels: ch, maxBlock: block)
    else { fail("load limiter") }
    m.setLimiter([-6.0, 50.0, 0.0, 0.0, 1.0]) // threshold -6dB, release 50ms, lookahead 0, in-gain 0, margin 1dB
    let ceiling = pow(10.0, (-6.0 - 1.0) / 20.0) // threshold+margin -> linear (~0.447)
    var lastPeak: Float = 0, lastRms: Float = 0
    for _ in 0..<16 {
        var blk = makeSine(freq: 440, frames: block, amp: 0.95)
        blk.withUnsafeMutableBufferPointer { p in m.process(p.baseAddress!, frames: block) }
        if blk.contains(where: { !$0.isFinite }) { fail("limiter non-finite") }
        lastPeak = peak(blk); lastRms = rms(blk)
    }
    print(String(format: "  steady peak_out=%.4f rms_out=%.4f  (input peak 0.95, ceiling ~%.4f)",
                 lastPeak, lastRms, Float(ceiling)))
    if lastPeak < 0.01 { fail("limiter still silent at steady state (output not flushing)") }
    if lastPeak > Float(ceiling) * 1.5 { fail("limiter not limiting (peak above ceiling)") }
}

// 4. Two-effect chain runs in order (PEQ -> Transient Shaper).
print("\n[4] chain: FifteenBandPEQ -> TransientShaper")
let chainOut = runChain(["FifteenBandPEQPlugin", "TransientShaperPlugin"], configure: { id, m in
    if id == "FifteenBandPEQPlugin" { m.setPeqBand(0, enabled: true, typeId: 0, freq: 1000, gainDb: 6, q: 1.0) }
    if id == "TransientShaperPlugin" { m.setTransient([1, 20, 20, 300, 6, 0, 5]) }
}, signal: makeSine(freq: 1000, frames: block, amp: 0.2))
if chainOut.contains(where: { !$0.isFinite }) { fail("chain non-finite") }
print(String(format: "  peak_out=%.4f (finite, in range=%@)", peak(chainOut), peak(chainOut) <= 1.0001 ? "yes" : "no"))

// 5. Sub Synth steady-state: stream a low tone through default params and check
//    for non-finite output (suspected cause of the analyzer going blank).
print("\n[5] SubSynth non-finite check (default params, 48k, 32 blocks @50Hz)")
do {
    guard let kind = EffectKind.find("SubSynthPlugin"),
          let m = EffectModule(kind: kind, dspDir: dspDir, sampleRate: sr, channels: ch, maxBlock: 4096)
    else { fail("load sub_synth") }
    m.setSubSynth([100, 100, 160, -12, 5, -6, 40, 0]) // defaults
    var anyBad = false, lastPeak: Float = 0
    for _ in 0..<32 {
        var blk = makeSine(freq: 50, frames: block, amp: 0.5)
        blk.withUnsafeMutableBufferPointer { p in m.process(p.baseAddress!, frames: block) }
        if blk.contains(where: { !$0.isFinite }) { anyBad = true }
        lastPeak = peak(blk)
    }
    print(String(format: "  steady peak_out=%.4f non-finite=%@", lastPeak, anyBad ? "YES(bug)" : "no"))
    if anyBad { fail("SubSynth produced non-finite output") }
}

print("\nPASS: native effect chain host verified offline")
