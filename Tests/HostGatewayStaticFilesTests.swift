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
        let response = files.response(method: "GET", target: "/")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "<html>index</html>")
        XCTAssertEqual(response.contentType, "text/html; charset=utf-8")
    }

    func testAssetContentType() {
        let response = files.response(method: "GET", target: "/e2ee.js")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.contentType, "text/javascript; charset=utf-8")
    }

    func testQueryStringIsStripped() {
        let response = files.response(method: "GET", target: "/e2ee.js?v=20260724")
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
        let response = files.response(method: "HEAD", target: "/")
        let wire = String(decoding: HostGatewayStaticFiles.serialize(response, includeBody: false), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: 18\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(wire.contains("<html>"))
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
