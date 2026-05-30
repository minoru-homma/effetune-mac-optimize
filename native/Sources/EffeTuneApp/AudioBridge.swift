import Foundation
import WebKit
import EffeTuneEngine
import AppKit
import UniformTypeIdentifiers

import QuartzCore

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
    private var meterTimer: Timer?
    private var meterTick = 0
    // Plugin ids of analyzers whose UI is currently visible (expanded + on-screen).
    // Only these get snapshots/pushes; the meter timer idles when this is empty.
    private var activeIds: Set<String> = []

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
        case "showSaveDialog":  handleSaveDialog(dict)
        case "showOpenDialog":  handleOpenDialog(dict)
        case "saveFile":        handleSaveFile(dict)
        case "readFile":        handleReadFile(dict)
        case "saveAppState":    handleSaveAppState(dict)
        case "loadAppState":    handleLoadAppState(dict)
        case "stop":
            meterTimer?.invalidate(); meterTimer = nil
            engine.stop()
        case "setActiveAnalyzers":
            let ids = (dict["ids"] as? [Any])?.compactMap { idString($0) } ?? []
            activeIds = Set(ids)
            applyTapActive()
            updateMeterTimer()
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

    // MARK: file dialogs / IO (preset import/export). Async request/reply: JS
    // posts {cmd, reqId, ...}; native answers window.__effetuneReply(reqId, result).

    private func reply(_ reqId: Int, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__effetuneReply && window.__effetuneReply(\(reqId), \(json));")
        }
    }

    private func contentType(_ ext: String?) -> [UTType] {
        if let e = ext, let t = UTType(filenameExtension: e) { return [t] }
        return []
    }

    private func handleSaveDialog(_ dict: [String: Any]) {
        let reqId = dict["reqId"] as? Int ?? 0
        let panel = NSSavePanel()
        panel.title = dict["title"] as? String ?? "Save"
        if let name = dict["defaultName"] as? String { panel.nameFieldStringValue = name }
        panel.allowedContentTypes = contentType(dict["ext"] as? String)
        if panel.runModal() == .OK, let url = panel.url {
            reply(reqId, ["canceled": false, "filePath": url.path])
        } else { reply(reqId, ["canceled": true]) }
    }

    private func handleOpenDialog(_ dict: [String: Any]) {
        let reqId = dict["reqId"] as? Int ?? 0
        let panel = NSOpenPanel()
        panel.title = dict["title"] as? String ?? "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = contentType(dict["ext"] as? String)
        if panel.runModal() == .OK {
            reply(reqId, ["canceled": false, "filePaths": panel.urls.map { $0.path }])
        } else { reply(reqId, ["canceled": true, "filePaths": []]) }
    }

    private func handleSaveFile(_ dict: [String: Any]) {
        let reqId = dict["reqId"] as? Int ?? 0
        guard let path = dict["path"] as? String, let content = dict["content"] as? String else {
            reply(reqId, ["success": false, "error": "missing path/content"]); return
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            reply(reqId, ["success": true])
        } catch {
            reply(reqId, ["success": false, "error": error.localizedDescription])
        }
    }

    private func handleReadFile(_ dict: [String: Any]) {
        let reqId = dict["reqId"] as? Int ?? 0
        guard let path = dict["path"] as? String else {
            reply(reqId, ["success": false, "error": "missing path"]); return
        }
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            reply(reqId, ["success": true, "content": content])
        } catch {
            reply(reqId, ["success": false, "error": error.localizedDescription])
        }
    }

    // Persisted pipeline state path: ~/Library/Application Support/EffeTune/pipeline-state.json
    private func appStatePath() -> String? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("EffeTune", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("pipeline-state.json").path
    }

    private func handleSaveAppState(_ dict: [String: Any]) {
        let reqId = dict["reqId"] as? Int ?? 0
        guard let path = appStatePath(), let content = dict["content"] as? String else {
            reply(reqId, ["success": false]); return
        }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            nlog("saveAppState: \(content.count) bytes -> \(path)")
            reply(reqId, ["success": true])
        } catch { reply(reqId, ["success": false, "error": error.localizedDescription]) }
    }

    private func handleLoadAppState(_ dict: [String: Any]) {
        let reqId = dict["reqId"] as? Int ?? 0
        guard let path = appStatePath(), FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            nlog("loadAppState: no saved state")
            reply(reqId, ["success": false]); return
        }
        nlog("loadAppState: \(content.count) bytes")
        reply(reqId, ["success": true, "content": content])
    }

    // plugin.id may arrive as a JSON number or string; normalize to String.
    private func idString(_ v: Any?) -> String? {
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        return nil
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
        updateMeterTimer()
    }

    // Cheap scalar meters (a few float reads, no RT tap). Always pushed when
    // present so their graphs keep updating without a JS draw-loop hook.
    private static let scalarMeterKinds: Set<String> = [
        "TransientShaperPlugin", "AutoLevelerPlugin", "MultibandCompressorPlugin",
    ]

    private func hasScalarMeter() -> Bool {
        engine.chain?.effects.contains {
            $0.pluginId != nil && AudioBridge.scalarMeterKinds.contains($0.kind.id)
        } ?? false
    }

    /// Push meters at 60 Hz to match the 60fps draw loop (smooth). The timer runs
    /// while any analyzer is visible OR a scalar-meter effect is present; else idle.
    private func updateMeterTimer() {
        let shouldRun = !activeIds.isEmpty || hasScalarMeter()
        if shouldRun && meterTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.pushMeters() }
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
            nlog("meter timer started (active=\(activeIds.count))")
        } else if !shouldRun && meterTimer != nil {
            meterTimer?.invalidate(); meterTimer = nil
            nlog("meter timer stopped (no visible analyzers)")
        }
    }

    /// Reflect visibility onto each module's RT audio tap (skip capture when hidden).
    private func applyTapActive() {
        guard let chain = engine.chain else { return }
        for e in chain.effects {
            if let id = e.pluginId { e.tapActive = activeIds.contains(id) }
        }
    }

    private func pushMeters() {
        guard let chain = engine.chain else { return }
        let time = CACurrentMediaTime()
        var list: [[String: Any]] = []
        for e in chain.effects {
            guard let id = e.pluginId else { continue }
            // Heavy analyzers only when visible; cheap scalar meters always.
            let isScalar = AudioBridge.scalarMeterKinds.contains(e.kind.id)
            guard activeIds.contains(id) || isScalar else { continue }
            var meas: [String: Any]? = nil
            switch e.kind.id {
            case "SpectrumAnalyzerPlugin", "SpectrogramPlugin":
                // Time-domain mono window; the JS analyzer runs its own FFT.
                if let snap = e.spectrumSnapshot() {
                    meas = ["buffer": [snap], "bufferPosition": e.spectrumPosition,
                            "sampleRate": engine.sampleRate, "time": time]
                }
            case "LevelMeterPlugin":
                // Per-channel linear peak over ~1/30 s (matches the worklet window).
                let window = max(1, Int(engine.sampleRate / 30.0))
                meas = ["channels": e.channelPeaks(window: window).map { ["peak": Double($0)] },
                        "time": time]
            case "OscilloscopePlugin":
                if let mr = e.monoRingSnapshot() {
                    meas = ["buffer": mr.buffer,
                            "triggerIndex": e.oscilloscopeTriggerIndex(autoSec: 0.1),
                            "currentPosition": mr.position,
                            "sampleRate": engine.sampleRate, "time": time]
                }
            case "StereoMeterPlugin":
                if let s = e.stereoSnapshot(window: 8192) {
                    meas = ["xBuffer": s.x, "yBuffer": s.y, "peakBuffer": s.peak,
                            "currentPosition": s.position,
                            "sampleRate": engine.sampleRate, "time": time]
                }
            case "MultibandCompressorPlugin":
                if let gr = e.multibandGainReductions() {
                    meas = ["gainReductions": gr, "time": time]
                }
            default:
                if var m = e.meters() { m["time"] = time; meas = m }
            }
            if let m = meas { list.append(["id": id, "measurements": m]) }
        }
        guard !list.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else { return }
        meterTick += 1
        if meterTick % 40 == 1 {
            let ids = list.map { ($0["id"] as? String) ?? "?" }.joined(separator: ",")
            nlog("pushMeters: \(list.count) item(s) ids=[\(ids)] bytes=\(data.count)")
        }
        webView?.evaluateJavaScript("window.__effetuneOnMeters && window.__effetuneOnMeters(\(json));")
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
        // Effects must be inited with the engine's MAX block; a callback can pass
        // more than bufferFrames (esp. after sample-rate conversion) and Rust
        // process_block silently no-ops when block_size > max_block_size.
        let maxBlock = engine.maxBlock
        let chain = EffectChain(channels: channels, maxBlock: maxBlock)
        for desc in descs {
            guard let typeId = desc["type"] as? String,
                  let kind = EffectKind.find(typeId),
                  let m = EffectModule(kind: kind, dspDir: dspDir,
                                       sampleRate: engine.sampleRate, channels: channels,
                                       maxBlock: maxBlock)
            else { continue }
            m.enabled = (desc["enabled"] as? Bool) ?? true
            m.pluginId = idString(desc["id"]) // plugin.id is numeric in JS
            m.tapActive = m.pluginId.map { activeIds.contains($0) } ?? true
            apply(desc, to: m)
            chain.append(m)
        }
        let summary = chain.effects.map { "\($0.kind.id)\($0.enabled ? "" : "(off)")" }.joined(separator: ", ")
        nlog("rebuildChain: \(chain.effects.count) effect(s): [\(summary)]")
        engine.chain = chain // see EffectChain note: production needs a lock-free swap
        updateMeterTimer() // a scalar-meter effect may have been added/removed
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
                var active = 0
                for (i, b) in bands.enumerated() {
                    let en = (b["enabled"] as? Bool) ?? true
                    let g = ((b["gain"] as? NSNumber)?.floatValue) ?? 0
                    if en && g != 0 { active += 1 }
                    m.setPeqBand(i, enabled: en,
                                 typeId: (b["typeId"] as? Int) ?? 0,
                                 freq: ((b["freq"] as? NSNumber)?.floatValue) ?? 1000,
                                 gainDb: g,
                                 q: ((b["q"] as? NSNumber)?.floatValue) ?? 1)
                }
                nlog("PEQ \(m.kind.id): \(bands.count) bands, \(active) with non-zero gain")
            } else {
                nlog("PEQ \(m.kind.id): no bands payload!")
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
        case "SpectrumAnalyzerPlugin", "SpectrogramPlugin":
            if let pt = payload["pt"] as? Int { m.spectrumWindow = 1 << pt }
        default:
            break
        }
    }
}
