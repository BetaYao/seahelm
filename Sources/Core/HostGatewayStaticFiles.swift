import Foundation

/// Static hosting for the browser client, served from the Host Gateway's own port.
///
/// Same-origin is not a convenience here, it is what makes the client work at all:
/// an `https://` page may not open a `ws://` socket, and `SubtleCrypto` — which the
/// pairing HKDF needs — exists only in a secure context. Page and socket therefore
/// have to arrive over one origin, so whatever secures the socket secures the page.
struct HostGatewayStaticFiles {
    /// Directory holding `index.html` and its assets; nil disables static hosting.
    let root: URL?

    init(root: URL?) {
        self.root = root
    }

    /// Bundled `seahelm-web`, or a `web_root` override pointing at a working copy.
    static func resolveRoot(override: String?) -> URL? {
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        return Bundle.main.resourceURL?.appendingPathComponent("seahelm-web")
    }

    struct Response: Equatable {
        let status: Int
        let reason: String
        let contentType: String
        let body: Data
    }

    /// Resolve an HTTP request target (`/`, `/e2ee.js`, `/x?v=1`) to a response.
    func response(method: String, target: String) -> Response {
        guard method == "GET" || method == "HEAD" else {
            return Self.plain(405, "Method Not Allowed", "method not allowed\n")
        }
        guard let root else {
            return Self.plain(404, "Not Found", "web client not bundled\n")
        }
        guard let file = Self.resolve(target: target, in: root) else {
            return Self.plain(404, "Not Found", "not found\n")
        }
        guard let data = try? Data(contentsOf: file) else {
            return Self.plain(404, "Not Found", "not found\n")
        }
        return Response(status: 200,
                        reason: "OK",
                        contentType: Self.contentType(for: file.pathExtension.lowercased()),
                        body: data)
    }

    /// Map a request target onto a file inside `root`, refusing to escape it.
    static func resolve(target: String, in root: URL) -> URL? {
        var path = target
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<cut])
        }
        path = path.removingPercentEncoding ?? path
        guard path.hasPrefix("/") else { return nil }
        if path.hasSuffix("/") { path += "index.html" }

        let base = root.standardizedFileURL
        let candidate = base.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        // `..` segments are resolved above, so a prefix check is what confines them.
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            return FileManager.default.fileExists(atPath: index.path) ? index : nil
        }
        return candidate
    }

    static func contentType(for pathExtension: String) -> String {
        switch pathExtension {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private static func plain(_ status: Int, _ reason: String, _ body: String) -> Response {
        Response(status: status,
                 reason: reason,
                 contentType: "text/plain; charset=utf-8",
                 body: Data(body.utf8))
    }

    /// Serialize to the wire. HEAD keeps the headers and drops the body.
    static func serialize(_ response: Response, includeBody: Bool) -> Data {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // The gateway is a live view of the machine; a stale cached shell is worse
        // than a re-fetch of a few hundred KB over the loopback or a tunnel.
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(response.body) }
        return data
    }
}
