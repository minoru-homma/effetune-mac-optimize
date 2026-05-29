import Foundation
import WebKit

/// Serves the EffeTune web UI from disk over a custom `effetune://` scheme.
///
/// We can't use file:// — WKWebView blocks `fetch()` of local resources from a
/// file origin, which hangs `plugin-manager.js` (`fetch('plugins/plugins.txt')`)
/// at the loading spinner. A custom scheme is a normal web origin, so fetch and
/// ES-module loading work as on the web, without opening a network port.
final class WebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "effetune"
    static let baseURL = "effetune://app/"

    private let root: String
    init(root: String) {
        // Canonical absolute root so we can reject path traversal.
        self.root = (root as NSString).standardizingPath
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }
        var rel = url.path
        if rel.isEmpty || rel == "/" { rel = "/effetune.html" }

        let full = (root + rel as NSString).standardizingPath
        // Keep requests inside the web root.
        guard full == root || full.hasPrefix(root + "/"),
              let data = FileManager.default.contents(atPath: full) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(resp)
            task.didReceive(Data("not found: \(rel)".utf8))
            task.didFinish()
            return
        }

        let mime = WebSchemeHandler.mime(forExtension: (full as NSString).pathExtension)
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
        ]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8" // required for ES modules
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "txt":         return "text/plain; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "wasm":        return "application/wasm"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "map":         return "application/json"
        default:            return "application/octet-stream"
        }
    }
}
