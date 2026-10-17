import Compression
import CryptoKit
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
    private let cache = Cache()

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

    struct RequestHeaders: Equatable {
        var acceptEncoding: String?
        var ifNoneMatch: String?
    }

    struct Response: Equatable {
        let status: Int
        let reason: String
        let contentType: String
        let body: Data
        let cacheControl: String
        let contentEncoding: String?
        let etag: String?
        let vary: String?
    }

    /// Resolve an HTTP request target (`/`, `/e2ee.js`, `/x?v=1`) to a response.
    func response(method: String, target: String) -> Response {
        response(method: method, target: target, headers: .init())
    }

    func response(method: String, target: String, headers: RequestHeaders) -> Response {
        guard method == "GET" || method == "HEAD" else {
            return Self.plain(405, "Method Not Allowed", "method not allowed\n")
        }
        guard let root else {
            return Self.plain(404, "Not Found", "web client not bundled\n")
        }
        guard let file = Self.resolve(target: target, in: root) else {
            return Self.plain(404, "Not Found", "not found\n")
        }
        let ext = file.pathExtension.lowercased()
        let wantGzip = Self.acceptsGzip(headers.acceptEncoding) && Self.gzipable(ext)
        guard let served = cache.served(file, in: root, gzip: wantGzip) else {
            return Self.plain(404, "Not Found", "not found\n")
        }

        let contentType = Self.contentType(for: ext)
        let cacheControl = Self.cacheControl(for: target, pathExtension: ext)
        let etag = served.etag

        if let inm = headers.ifNoneMatch, inm == etag {
            return Response(status: 304, reason: "Not Modified",
                            contentType: contentType, body: Data(),
                            cacheControl: cacheControl,
                            contentEncoding: nil, etag: etag, vary: nil)
        }

        var body = served.data
        var encoding: String?
        var vary: String?
        if let gz = served.gzip {
            body = gz
            encoding = "gzip"
            vary = "Accept-Encoding"
        }

        return Response(status: 200, reason: "OK",
                        contentType: contentType,
                        body: body,
                        cacheControl: cacheControl,
                        contentEncoding: encoding,
                        etag: etag,
                        vary: vary)
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

    static func cacheControl(for target: String, pathExtension: String) -> String {
        switch pathExtension {
        case "html", "htm":
            return "no-cache"
        default:
            if target.contains("?v=") || target.contains("?v&") {
                return "public, max-age=31536000, immutable"
            }
            // Revalidate, never trust a stored copy: the page is `no-cache`, so a
            // day-long max-age here paired a fresh index.html with the scripts
            // of the build before, and a page calling a function its stale
            // script lacked threw mid-render and drew an empty fleet. The ETag
            // makes the check a 304 when nothing changed. A page's own scripts
            // never land here — `Cache` serves it with them versioned — so this
            // is for what they load in turn.
            return "no-cache"
        }
    }

    static func etag(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\"\(hex)\""
    }

    static func acceptsGzip(_ acceptEncoding: String?) -> Bool {
        guard let acceptEncoding else { return false }
        let tokens = acceptEncoding.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for token in tokens {
            let parts = token.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first?.lowercased(), name == "gzip" else { continue }
            if parts.count > 1 {
                let qPart = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
                if qPart.hasPrefix("q="), let q = Double(qPart.dropFirst(2)), q == 0 {
                    continue
                }
            }
            return true
        }
        return false
    }

    static func gzipable(_ pathExtension: String) -> Bool {
        switch pathExtension {
        case "html", "htm", "js", "mjs", "css", "svg", "json", "map", "txt", "md":
            return true
        default:
            return false
        }
    }

    static func gzip(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        guard let deflated = deflateRaw(input) else { return nil }

        var out = Data()
        // RFC 1952 gzip header
        out.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00])
        out.append(contentsOf: [0, 0, 0, 0]) // mtime
        out.append(contentsOf: [0x00, 0x03]) // xfl + OS (Unix)
        out.append(deflated)
        out.append(contentsOf: crc32(input).littleEndianBytes)
        out.append(contentsOf: UInt32(truncatingIfNeeded: input.count).littleEndianBytes)
        return out
    }

    private static func deflateRaw(_ input: Data) -> Data? {
        var output = Data(count: max(input.count, 64))
        var capacity = output.count
        for _ in 0..<8 {
            let written = output.withUnsafeMutableBytes { dst -> Int in
                input.withUnsafeBytes { src -> Int in
                    guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                          let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(dstBase, capacity,
                                                     srcBase, input.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                output.removeSubrange(written...)
                return output
            }
            capacity *= 2
            output = Data(count: capacity)
        }
        return nil
    }

    private static func crc32(_ input: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in input {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func plain(_ status: Int, _ reason: String, _ body: String) -> Response {
        Response(status: status,
                 reason: reason,
                 contentType: "text/plain; charset=utf-8",
                 body: Data(body.utf8),
                 cacheControl: "no-cache",
                 contentEncoding: nil,
                 etag: nil,
                 vary: nil)
    }

    /// Serialize to the wire. HEAD keeps the headers and drops the body.
    static func serialize(_ response: Response, includeBody: Bool, connectionClose: Bool = false) -> Data {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: \(response.cacheControl)\r\n"
        if let encoding = response.contentEncoding {
            head += "Content-Encoding: \(encoding)\r\n"
        }
        if let etag = response.etag {
            head += "ETag: \(etag)\r\n"
        }
        if let vary = response.vary {
            head += "Vary: \(vary)\r\n"
        }
        head += "Connection: \(connectionClose ? "close" : "keep-alive")\r\n\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(response.body) }
        return data
    }
}

extension HostGatewayStaticFiles {
    /// What one file serves as: its bytes, their ETag, and — when the client
    /// takes it and it pays — the gzip of them.
    struct Served {
        let data: Data
        let etag: String
        let gzip: Data?
    }

    /// Files read, hashed and gzipped once rather than on every request.
    ///
    /// Each page open used to read every script off disk, SHA-256 it and gzip
    /// it again (xterm.js is ~490KB, and the CRC loop alone walks every byte).
    /// An entry stands while the file's size and mtime do, so a `web_root`
    /// working copy is still picked up the moment it is saved.
    ///
    /// A page is also served with its own scripts versioned: every quoted
    /// `./name.js` / `./name.css` it names that exists gets `?v=<etag prefix>`,
    /// which `cacheControl` answers as immutable. Without it each open
    /// revalidated a dozen scripts — a dozen round trips through the tunnel to
    /// the Mac before the page could run — and the old cure, a long max-age,
    /// paired a fresh page with the scripts of the build before. A page entry
    /// therefore also stands only while every asset it versioned is unchanged.
    final class Cache {
        private struct Stamp: Equatable {
            let size: Int
            let mtime: Date?
        }

        private struct Entry {
            let stamp: Stamp
            let data: Data
            let etag: String
            /// nil: not computed yet. `.some(nil)`: computed, did not shrink it.
            var gzip: Data??
            /// Pages only: the assets versioned into `data`, with the ETag each
            /// had when it was written in.
            var versioned: [(file: URL, etag: String)] = []
        }

        private var entries: [String: Entry] = [:]
        private let lock = NSLock()

        func served(_ file: URL, in root: URL, gzip: Bool) -> Served? {
            lock.lock()
            defer { lock.unlock() }
            let isPage = ["html", "htm"].contains(file.pathExtension.lowercased())
            guard var entry = isPage ? page(file, in: root) : asset(file) else { return nil }
            var gz: Data?
            if gzip {
                if entry.gzip == nil {
                    let packed = HostGatewayStaticFiles.gzip(entry.data)
                    entry.gzip = .some(packed.flatMap { $0.count < entry.data.count ? $0 : nil })
                    entries[file.path] = entry
                }
                gz = entry.gzip ?? nil
            }
            return Served(data: entry.data, etag: entry.etag, gzip: gz)
        }

        private func stamp(_ file: URL) -> Stamp? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  (attrs[.type] as? FileAttributeType) != .typeDirectory else { return nil }
            return Stamp(size: (attrs[.size] as? NSNumber)?.intValue ?? -1,
                         mtime: attrs[.modificationDate] as? Date)
        }

        private func asset(_ file: URL) -> Entry? {
            guard let stamp = stamp(file) else {
                entries[file.path] = nil
                return nil
            }
            if let hit = entries[file.path], hit.stamp == stamp { return hit }
            guard let data = try? Data(contentsOf: file) else { return nil }
            let entry = Entry(stamp: stamp, data: data, etag: HostGatewayStaticFiles.etag(for: data))
            entries[file.path] = entry
            return entry
        }

        private func page(_ file: URL, in root: URL) -> Entry? {
            guard let stamp = stamp(file) else {
                entries[file.path] = nil
                return nil
            }
            if let hit = entries[file.path], hit.stamp == stamp,
               hit.versioned.allSatisfy({ asset($0.file)?.etag == $0.etag }) {
                return hit
            }
            guard let raw = try? Data(contentsOf: file) else { return nil }
            var versioned: [(file: URL, etag: String)] = []
            let data = HostGatewayStaticFiles.versionAssets(in: raw, page: file, root: root) { url in
                guard let etag = self.asset(url)?.etag else { return nil }
                versioned.append((url, etag))
                return etag
            }
            var entry = Entry(stamp: stamp, data: data, etag: HostGatewayStaticFiles.etag(for: data))
            entry.versioned = versioned
            entries[file.path] = entry
            return entry
        }
    }

    /// Quoted `./…​.js|.mjs|.css` references with nothing after the extension.
    private static let assetReference = try! NSRegularExpression(
        pattern: #"(["'])(\./[A-Za-z0-9_\-./]+\.(?:js|mjs|css))\1"#)

    /// `page` with each quoted reference to an asset under `root` turned into
    /// `./name.js?v=<first 12 hex of its ETag>`. References that resolve to no
    /// file, or outside `root`, are left as they are.
    static func versionAssets(in page: Data, page file: URL, root: URL,
                              etag: (URL) -> String?) -> Data {
        guard let text = String(data: page, encoding: .utf8) else { return page }
        let base = file.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in assetReference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let refRange = match.range(at: 2)
            let ref = ns.substring(with: refRange)
            let url = base.appendingPathComponent(String(ref.dropFirst(2))).standardizedFileURL
            guard url.path.hasPrefix(rootPath + "/"), let tag = etag(url) else { continue }
            let hex = tag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let end = refRange.location + refRange.length
            out += ns.substring(with: NSRange(location: cursor, length: end - cursor))
            out += "?v=" + hex.prefix(12)
            cursor = end
        }
        guard cursor > 0 else { return page }
        out += ns.substring(from: cursor)
        return Data(out.utf8)
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
