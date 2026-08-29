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
        XCTAssertEqual(response.cacheControl, "public, max-age=86400")
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
