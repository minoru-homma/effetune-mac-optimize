import AppKit
import WebKit
import AVFoundation
import EffeTuneEngine

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
        NLog.reset("EffeTune native launch")
        // Force the microphone TCC prompt up front; input capture fails silently
        // without it. (Non-sandboxed app uses the Info.plist usage description.)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            nlog("microphone access granted=\(granted)")
        }
        // Dev fallbacks assume the binary runs from <repo>/native/.build/...; allow env override.
        let cwd = FileManager.default.currentDirectoryPath
        let repoRoot = (cwd as NSString).deletingLastPathComponent // best-effort; env preferred
        let webRoot = resolveDir(env: "EFFETUNE_WEBROOT", bundleSub: "web", devFallback: repoRoot)
        let dspDir  = resolveDir(env: "EFFETUNE_DSPDIR",  bundleSub: "dsp", devFallback: "\(cwd)/dsp")

        bridge = AudioBridge(dspDir: dspDir)

        let config = WKWebViewConfiguration()
        // Serve the UI over a custom scheme (file:// would block fetch()).
        config.setURLSchemeHandler(WebSchemeHandler(root: webRoot), forURLScheme: WebSchemeHandler.scheme)
        let ucc = WKUserContentController()
        ucc.add(bridge, name: "effetune")
        // Tell the renderer it is running inside the native host BEFORE app.js runs.
        let marker = """
        window.__effetuneNativeHost = true;
        window.__effetuneNativePost = function (m) { window.webkit.messageHandlers.effetune.postMessage(m); };
        (function () {
          var post = window.__effetuneNativePost;
          ['log', 'warn', 'error'].forEach(function (level) {
            var orig = console[level].bind(console);
            console[level] = function () {
              try {
                var parts = Array.prototype.map.call(arguments, function (a) {
                  try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); }
                });
                post({ cmd: 'log', level: level, text: parts.join(' ') });
              } catch (e) {}
              orig.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (e) {
            post({ cmd: 'log', level: 'error', text: 'window.onerror: ' + e.message + ' @ ' + e.filename + ':' + e.lineno });
          });
          window.addEventListener('unhandledrejection', function (e) {
            post({ cmd: 'log', level: 'error', text: 'unhandledrejection: ' + (e.reason && e.reason.message ? e.reason.message : e.reason) });
          });
        })();
        """
        ucc.addUserScript(WKUserScript(source: marker, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        bridge.webView = webView
        setupMenu()

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
            webView.load(URLRequest(url: URL(string: WebSchemeHandler.baseURL + "effetune.html")!))
        } else {
            let html = "<h2 style='font-family:sans-serif'>EffeTune native host</h2>" +
                       "<p>UI not found. Set EFFETUNE_WEBROOT to the repo root (found: \(webRoot)).</p>"
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // Minimal native menu: app menu (Quit) + Audio > Configure Audio… which asks
    // the renderer to open its audio config dialog (device pickers, sample rate).
    private func setupMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About EffeTune", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit EffeTune", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let imp = NSMenuItem(title: "Import Preset…", action: #selector(importPreset), keyEquivalent: "o")
        imp.target = self
        fileMenu.addItem(imp)
        let exp = NSMenuItem(title: "Export Preset…", action: #selector(exportPreset), keyEquivalent: "s")
        exp.target = self
        fileMenu.addItem(exp)
        fileItem.submenu = fileMenu

        let audioItem = NSMenuItem()
        main.addItem(audioItem)
        let audioMenu = NSMenu(title: "Audio")
        let cfg = NSMenuItem(title: "Configure Audio…", action: #selector(openAudioConfig), keyEquivalent: ",")
        cfg.target = self
        audioMenu.addItem(cfg)
        audioItem.submenu = audioMenu

        // Standard Edit menu so copy/paste/text editing work in the web UI.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = main
    }

    @objc private func openAudioConfig() {
        webView.evaluateJavaScript("window.__effetuneOpenAudioConfig && window.__effetuneOpenAudioConfig();")
    }
    @objc private func exportPreset() {
        webView.evaluateJavaScript("window.electronIntegration && window.electronIntegration.exportPreset && window.electronIntegration.exportPreset();")
    }
    @objc private func importPreset() {
        webView.evaluateJavaScript("window.electronIntegration && window.electronIntegration.importPreset && window.electronIntegration.importPreset();")
    }
}
