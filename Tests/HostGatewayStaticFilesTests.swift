import XCTest
@testable import seahelm

final class HostGatewayStaticFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hostgateway-static-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html>index</html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("var E2EE;".utf8).write(to: root.appendingPathComponent("e2ee.js"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var files: HostGatewayStaticFiles { HostGatewayStaticFiles(root: root) }

    func testRootServesIndex() {
        let response = files.response(method: "GET", target: "/",
                                      headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "<html>index</html>")
        XCTAssertEqual(response.contentType, "text/html; charset=utf-8")
    }

    func testAssetContentType() {
        let response = files.response(method: "GET", target: "/e2ee.js",
                                      headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentType, "text/javascript; charset=utf-8")
    }

    func testQueryStringIsStripped() {
        let response = files.response(method: "GET", target: "/e2ee.js?v=20260724",
                                      headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "var E2EE;")
    }

    func testMissingFileIs404() {
        XCTAssertEqual(files.response(method: "GET", target: "/nope.js").status, 404)
    }

    func testTraversalIsRefused() throws {
        // A real secret one level up: resolution must not reach it.
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let target = "/../" + outside.lastPathComponent
        XCTAssertNil(HostGatewayStaticFiles.resolve(target: target, in: root))
        XCTAssertEqual(files.response(method: "GET", target: target).status, 404)
        XCTAssertEqual(files.response(method: "GET", target: "/%2e%2e/" + outside.lastPathComponent).status, 404)
    }

    func testNonGetIsRefused() {
        XCTAssertEqual(files.response(method: "POST", target: "/").status, 405)
    }

    func testMissingRootIs404() {
        XCTAssertEqual(HostGatewayStaticFiles(root: nil).response(method: "GET", target: "/").status, 404)
    }

    func testResolveRootRejectsMissingOverride() {
        XCTAssertNil(HostGatewayStaticFiles.resolveRoot(override: "/no/such/dir/anywhere"))
        XCTAssertEqual(HostGatewayStaticFiles.resolveRoot(override: root.path)?.path, root.path)
    }

    func testSerializeHeadOmitsBodyButKeepsLength() {
        let response = files.response(method: "HEAD", target: "/",
                                      headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        let wire = String(decoding: HostGatewayStaticFiles.serialize(response, includeBody: false), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: 18\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(wire.contains("<html>"))
    }

    func testGzipWhenAccepted() {
        // Make body large enough that gzip shrinks it.
        let raw = Data(repeating: 0x61, count: 4096) // "aaaa..."
        try! raw.write(to: root.appendingPathComponent("big.js"))
        let response = files.response(
            method: "GET",
            target: "/big.js",
            headers: .init(acceptEncoding: "gzip, deflate", ifNoneMatch: nil))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentEncoding, "gzip")
        XCTAssertLessThan(response.body.count, raw.count)
        // Unversioned: revalidated, so a new page never runs an old script.
        XCTAssertEqual(response.cacheControl, "no-cache")
        XCTAssertNotNil(response.etag)
    }

    func testNoGzipWithoutAcceptEncoding() {
        let response = files.response(
            method: "GET", target: "/e2ee.js",
            headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        XCTAssertNil(response.contentEncoding)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "var E2EE;")
    }

    func testHtmlIsNoCache() {
        let response = files.response(
            method: "GET", target: "/",
            headers: .init(acceptEncoding: "gzip", ifNoneMatch: nil))
        XCTAssertEqual(response.cacheControl, "no-cache")
    }

    func testVersionedAssetIsImmutable() {
        let response = files.response(
            method: "GET", target: "/e2ee.js?v=20260724",
            headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        XCTAssertEqual(response.cacheControl, "public, max-age=31536000, immutable")
    }

    func testETagYields304() {
        let first = files.response(
            method: "GET", target: "/e2ee.js",
            headers: .init(acceptEncoding: nil, ifNoneMatch: nil))
        let etag = try! XCTUnwrap(first.etag)
        let again = files.response(
            method: "GET", target: "/e2ee.js",
            headers: .init(acceptEncoding: nil, ifNoneMatch: etag))
        XCTAssertEqual(again.status, 304)
        XCTAssertTrue(again.body.isEmpty)
    }

    // MARK: - Versioned page, cached files

    private func get(_ target: String, gzip: Bool = false, ifNoneMatch: String? = nil) -> HostGatewayStaticFiles.Response {
        files.response(method: "GET", target: target,
                       headers: .init(acceptEncoding: gzip ? "gzip" : nil, ifNoneMatch: ifNoneMatch))
    }

    private func write(_ text: String, _ name: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func version(of name: String) -> String {
        let etag = get("/\(name)").etag ?? ""
        return String(etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).prefix(12))
    }

    func testPageVersionsItsOwnScripts() throws {
        try write("""
            <script src="./e2ee.js"></script>
            <link href="./sub/a.css">
            <script>js.src = './e2ee.js'; import('./sub/a.css');</script>
            """, "index.html")
        try write("p{}", "sub/a.css")
        let page = String(decoding: get("/").body, as: UTF8.self)
        let js = version(of: "e2ee.js"), css = version(of: "sub/a.css")
        XCTAssertEqual(js.count, 12)
        XCTAssertTrue(page.contains("src=\"./e2ee.js?v=\(js)\""))
        XCTAssertTrue(page.contains("href=\"./sub/a.css?v=\(css)\""))
        XCTAssertTrue(page.contains("js.src = './e2ee.js?v=\(js)'"))
        XCTAssertTrue(page.contains("import('./sub/a.css?v=\(css)')"))
        // And what the page now asks for is cached for good.
        XCTAssertEqual(get("/e2ee.js?v=\(js)").cacheControl, "public, max-age=31536000, immutable")
    }

    func testPageLeavesUnknownAndQueriedReferencesAlone() throws {
        let html = """
            <script src="./missing.js"></script>
            <script src="./e2ee.js?r=2"></script>
            <script src="https://cdn.example/x.js"></script>
            <script src="./../outside.js"></script>
            """
        try write(html, "index.html")
        try write("x", "../outside.js")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("outside.js")) }
        XCTAssertEqual(String(decoding: get("/").body, as: UTF8.self), html)
    }

    func testEditedScriptChangesThePageAndItsETag() throws {
        try write(#"<script src="./e2ee.js"></script>"#, "index.html")
        let before = get("/")
        let oldVersion = version(of: "e2ee.js")
        // A different size, so the edit shows even where mtime is coarse.
        try write("var E2EE = 2;", "e2ee.js")
        let after = get("/")
        XCTAssertNotEqual(before.etag, after.etag)
        XCTAssertNotEqual(version(of: "e2ee.js"), oldVersion)
        XCTAssertTrue(String(decoding: after.body, as: UTF8.self).contains("e2ee.js?v=\(version(of: "e2ee.js"))"))
        // The browser's old copy of the page no longer matches.
        XCTAssertEqual(get("/", ifNoneMatch: before.etag).status, 200)
    }

    func testEditedFileIsServedFresh() throws {
        XCTAssertEqual(String(decoding: get("/e2ee.js").body, as: UTF8.self), "var E2EE;")
        try write("var E2EE = 'new';", "e2ee.js")
        XCTAssertEqual(String(decoding: get("/e2ee.js").body, as: UTF8.self), "var E2EE = 'new';")
    }

    func testDeletedFileIs404() throws {
        XCTAssertEqual(get("/e2ee.js").status, 200)
        try FileManager.default.removeItem(at: root.appendingPathComponent("e2ee.js"))
        XCTAssertEqual(get("/e2ee.js").status, 404)
    }

    func testCachedGzipStillMatchesTheFile() throws {
        try write(String(repeating: "var E2EE = 1;\n", count: 200), "e2ee.js")
        let first = get("/e2ee.js", gzip: true)
        let again = get("/e2ee.js", gzip: true)
        XCTAssertEqual(first.contentEncoding, "gzip")
        XCTAssertEqual(first.body, again.body)
        // Asked for plainly afterwards, the same entry answers uncompressed.
        XCTAssertNil(get("/e2ee.js").contentEncoding)
    }

    func testSerializeIncludesEncodingAndCache() {
        let response = HostGatewayStaticFiles.Response(
            status: 200, reason: "OK",
            contentType: "text/javascript; charset=utf-8",
            body: Data([0x1f, 0x8b]),
            cacheControl: "public, max-age=86400",
            contentEncoding: "gzip",
            etag: "\"abc\"",
            vary: "Accept-Encoding")
        let wire = String(decoding: HostGatewayStaticFiles.serialize(response, includeBody: true), as: UTF8.self)
        XCTAssertTrue(wire.contains("Content-Encoding: gzip\r\n"))
        XCTAssertTrue(wire.contains("Cache-Control: public, max-age=86400\r\n"))
        XCTAssertTrue(wire.contains("ETag: \"abc\"\r\n"))
        XCTAssertTrue(wire.contains("Vary: Accept-Encoding\r\n"))
        XCTAssertTrue(wire.contains("Connection: keep-alive\r\n"))
        XCTAssertFalse(wire.contains("Connection: close\r\n"))
    }

    func testSerializeConnectionClose() {
        let response = HostGatewayStaticFiles.Response(
            status: 200, reason: "OK",
            contentType: "text/plain; charset=utf-8",
            body: Data("ok".utf8),
            cacheControl: "no-cache",
            contentEncoding: nil,
            etag: nil,
            vary: nil)
        let wire = String(decoding: HostGatewayStaticFiles.serialize(
            response, includeBody: true, connectionClose: true), as: UTF8.self)
        XCTAssertTrue(wire.contains("Connection: close\r\n"))
    }

    func testRequestParsing() {
        XCTAssertTrue(HostGatewayServer.isWebSocketUpgrade(
            head: "GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: WebSocket\r\nConnection: Upgrade"))
        XCTAssertFalse(HostGatewayServer.isWebSocketUpgrade(
            head: "GET / HTTP/1.1\r\nHost: x\r\nUser-Agent: upgrade-websocket-lookalike"))

        let line = HostGatewayServer.requestLine(head: "get /a/b?c=1 HTTP/1.1\r\nHost: x")
        XCTAssertEqual(line.method, "GET")
        XCTAssertEqual(line.target, "/a/b?c=1")
        XCTAssertEqual(HostGatewayServer.requestPath("/ws?token=x"), "/ws")
    }
}
