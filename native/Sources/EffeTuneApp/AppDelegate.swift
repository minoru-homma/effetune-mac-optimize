import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var bridge: AudioBridge!

    // Resolve the web UI root and DSP dylib dir: env override -> app bundle -> repo dev layout.
    private func resolveDir(env: String, bundleSub: String, devFallback: String) -> String {
        if let v = ProcessInfo.processInfo.environment[env], FileManager.default.fileExists(atPath: v) { return v }
        if let res = Bundle.main.resourceURL?.appendingPathComponent(bundleSub).path,
           FileManager.default.fileExists(atPath: res) { return res }
        return devFallback
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Dev fallbacks assume the binary runs from <repo>/native/.build/...; allow env override.
        let cwd = FileManager.default.currentDirectoryPath
        let repoRoot = (cwd as NSString).deletingLastPathComponent // best-effort; env preferred
        let webRoot = resolveDir(env: "EFFETUNE_WEBROOT", bundleSub: "web", devFallback: repoRoot)
        let dspDir  = resolveDir(env: "EFFETUNE_DSPDIR",  bundleSub: "dsp", devFallback: "\(cwd)/dsp")

        bridge = AudioBridge(dspDir: dspDir)

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(bridge, name: "effetune")
        // Tell the renderer it is running inside the native host BEFORE app.js runs.
        let marker = """
        window.__effetuneNativeHost = true;
        window.__effetuneNativePost = function (m) { window.webkit.messageHandlers.effetune.postMessage(m); };
        """
        ucc.addUserScript(WKUserScript(source: marker, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        let rect = NSRect(x: 0, y: 0, width: 1280, height: 840)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "EffeTune (Native)"
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let indexPath = (webRoot as NSString).appendingPathComponent("effetune.html")
        if FileManager.default.fileExists(atPath: indexPath) {
            let url = URL(fileURLWithPath: indexPath)
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: webRoot))
        } else {
            let html = "<h2 style='font-family:sans-serif'>EffeTune native host</h2>" +
                       "<p>UI not found. Set EFFETUNE_WEBROOT to the repo root (found: \(webRoot)).</p>"
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
