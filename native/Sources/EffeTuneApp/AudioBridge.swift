import Foundation
import WebKit
import EffeTuneEngine

/// Receives commands from the WKWebView (window.webkit.messageHandlers.effetune)
/// and drives the native CoreAudio engine + effect chain.
///
/// Protocol (JS -> native), JSON dictionaries:
///   { cmd:"start",  sampleRate, channels, bufferFrames }
///   { cmd:"stop" }
///   { cmd:"setPipeline", dspDir, channels, effects:[EffectDesc] }
///   { cmd:"setParam", index, effect:EffectDesc }
///
/// EffectDesc = { type:<EffectKind.id>, enabled:Bool, payload:{…} } where payload
/// is shaped per effect type (the JS side owns the plugin parameter schema and
/// normalizes to these orders — see js/native-bridge.js).
public final class AudioBridge: NSObject, WKScriptMessageHandler {
    private let engine = CoreAudioEngine()
    private var dspDir: String
    private var channels = 2

    public init(dspDir: String) {
        self.dspDir = dspDir
    }

    public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let cmd = dict["cmd"] as? String else { return }
        switch cmd {
        case "start":
            let sr = (dict["sampleRate"] as? Double) ?? 48000
            let ch = (dict["channels"] as? Int) ?? 2
            let bf = UInt32((dict["bufferFrames"] as? Int) ?? 128)
            channels = ch
            engine.configure(sampleRate: sr, channels: ch, bufferFrames: bf)
            do { try engine.start() }
            catch { FileHandle.standardError.write(Data("engine start failed: \(error)\n".utf8)) }
        case "stop":
            engine.stop()
        case "setPipeline":
            if let dir = dict["dspDir"] as? String { dspDir = dir }
            if let ch = dict["channels"] as? Int { channels = ch }
            rebuildChain((dict["effects"] as? [[String: Any]]) ?? [])
        case "updateParams":
            // In-place: apply payloads to the existing chain when structure is
            // unchanged (param drags). Falls back to a rebuild on any mismatch so
            // effect DSP state (envelopes, filters) survives slider moves.
            let descs = (dict["effects"] as? [[String: Any]]) ?? []
            guard let chain = engine.chain, descs.count == chain.effects.count else {
                rebuildChain(descs); break
            }
            for (i, desc) in descs.enumerated() {
                let m = chain.effects[i]
                guard (desc["type"] as? String) == m.kind.id else { rebuildChain(descs); return }
                m.enabled = (desc["enabled"] as? Bool) ?? true
                apply(desc, to: m)
            }
        default:
            break
        }
    }

    /// Build a fresh chain off the audio thread, then hand it to the engine.
    /// Keeps ALL supported effects (disabled ones bypassed) so positions stay
    /// aligned with the JS pipeline for the in-place updateParams path.
    private func rebuildChain(_ descs: [[String: Any]]) {
        let chain = EffectChain(channels: channels, maxBlock: Int(engine.bufferFrames))
        for desc in descs {
            guard let typeId = desc["type"] as? String,
                  let kind = EffectKind.find(typeId),
                  let m = EffectModule(kind: kind, dspDir: dspDir,
                                       sampleRate: engine.sampleRate, channels: channels,
                                       maxBlock: Int(engine.bufferFrames))
            else { continue }
            m.enabled = (desc["enabled"] as? Bool) ?? true
            apply(desc, to: m)
            chain.append(m)
        }
        engine.chain = chain // see EffectChain note: production needs a lock-free swap
    }

    /// Decode an EffectDesc payload and push it into the module's setters.
    private func apply(_ desc: [String: Any], to m: EffectModule) {
        let payload = (desc["payload"] as? [String: Any]) ?? [:]
        func floats(_ key: String) -> [Float] {
            (payload[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
        }
        switch m.kind.id {
        case "TransientShaperPlugin": m.setTransient(floats("params"))
        case "AutoLevelerPlugin":     m.setAutoLeveler(floats("params"))
        case "SubSynthPlugin":        m.setSubSynth(floats("params"))
        case "BrickwallLimiterPlugin":m.setLimiter(floats("params"))
        case "FifteenBandPEQPlugin", "FiveBandPEQPlugin":
            if let bands = payload["bands"] as? [[String: Any]] {
                for (i, b) in bands.enumerated() {
                    m.setPeqBand(i,
                                 enabled: (b["enabled"] as? Bool) ?? true,
                                 typeId: (b["typeId"] as? Int) ?? 0,
                                 freq: ((b["freq"] as? NSNumber)?.floatValue) ?? 1000,
                                 gainDb: ((b["gain"] as? NSNumber)?.floatValue) ?? 0,
                                 q: ((b["q"] as? NSNumber)?.floatValue) ?? 1)
                }
            }
        case "MultibandCompressorPlugin":
            let x = floats("crossovers")
            if x.count == 4 { m.setMultibandCrossovers(x[0], x[1], x[2], x[3]) }
            if let bands = payload["bands"] as? [[String: Any]] {
                for (i, b) in bands.enumerated() {
                    let p = (b["params"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
                    if p.count == 6 { m.setMultibandBand(i, p) }
                }
            }
        default:
            break // SpectrumAnalyzer: no params to push
        }
    }
}
