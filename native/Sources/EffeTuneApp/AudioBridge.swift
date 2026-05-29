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
    private var inputUID: String?
    private var outputUID: String?
    private var sampleRate: Double = 48000
    private var bufferFrames = 128
    public weak var webView: WKWebView?

    public init(dspDir: String) {
        self.dspDir = dspDir
    }

    public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let cmd = dict["cmd"] as? String else { return }
        switch cmd {
        case "log":
            nlog("[js:\((dict["level"] as? String) ?? "log")] \((dict["text"] as? String) ?? "")")
        case "listDevices":
            sendDeviceList()
        case "start":
            applyDeviceConfig(dict)
            startEngine()
        case "setDevices":
            // Reconfigure devices/format and restart; JS resends the pipeline after.
            applyDeviceConfig(dict)
            startEngine()
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

    private func applyDeviceConfig(_ dict: [String: Any]) {
        if let dir = dict["dspDir"] as? String { dspDir = dir }
        sampleRate = (dict["sampleRate"] as? Double) ?? sampleRate
        channels = (dict["channels"] as? Int) ?? channels
        bufferFrames = (dict["bufferFrames"] as? Int) ?? bufferFrames
        if dict.keys.contains("inputDeviceId")  { inputUID  = dict["inputDeviceId"]  as? String }
        if dict.keys.contains("outputDeviceId") { outputUID = dict["outputDeviceId"] as? String }
    }

    private func startEngine() {
        engine.configure(sampleRate: sampleRate, channels: channels,
                         bufferFrames: UInt32(bufferFrames), inputUID: inputUID, outputUID: outputUID)
        do { try engine.start() }
        catch { FileHandle.standardError.write(Data("engine start failed: \(error)\n".utf8)) }
    }

    /// Push the CoreAudio device list to the renderer (window.__effetuneOnDevices).
    private func sendDeviceList() {
        let devices = AudioDevices.list()
        guard let data = try? JSONEncoder().encode(devices),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__effetuneOnDevices && window.__effetuneOnDevices(\(json));")
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
