import Network
import XCTest
@testable import seahelm

/// `CurlClient` against a keep-alive HTTP/1.1 server on loopback.
final class CurlClientTests: XCTestCase {
    private var server: LoopbackHTTPServer!
    private var client: CurlClient!

    override func setUpWithError() throws {
        server = try LoopbackHTTPServer()
        client = CurlClient()
    }

    override func tearDown() {
        server.stop()
    }

    private func url(_ path: String) -> String { "http://127.0.0.1:\(server.port)\(path)" }

    func testPostSendsTheBodyAndReturnsTheAnswer() throws {
        let response = try client.perform(url: url("/echo"), body: Data(#"{"a":1}"#.utf8), timeout: 5)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"POST {"a":1}"#)
    }

    func testGetHasNoBody() throws {
        let response = try client.perform(url: url("/echo"), timeout: 5)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "GET ")
    }

    /// The whole point: the second request rides the first one's connection.
    func testSequentialRequestsReuseOneConnection() throws {
        let first = try client.perform(url: url("/echo"), body: Data("1".utf8), timeout: 5)
        let second = try client.perform(url: url("/echo"), body: Data("2".utf8), timeout: 5)
        let third = try client.perform(url: url("/echo"), timeout: 5)
        XCTAssertFalse(first.reused)
        XCTAssertTrue(second.reused)
        XCTAssertTrue(third.reused)
        XCTAssertEqual(server.connectionCount, 1)
    }

    /// A recycled handle must not carry the last request's POST into a GET.
    func testARecycledHandleForgetsThePreviousRequest() throws {
        _ = try client.perform(url: url("/echo"), body: Data("old".utf8), timeout: 5)
        let get = try client.perform(url: url("/echo"), timeout: 5)
        XCTAssertEqual(String(decoding: get.body, as: UTF8.self), "GET ")
    }

    func testErrorStatusStillReturnsItsBody() throws {
        let response = try client.perform(url: url("/missing"), timeout: 5)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"ok":false}"#)
    }

    func testCancelAbandonsAHangingRequest() {
        let start = Date()
        let cancelAt = start.addingTimeInterval(0.5)
        XCTAssertThrowsError(try client.perform(url: url("/hang"), timeout: 30,
                                                isCancelled: { Date() >= cancelAt })) {
            XCTAssertEqual($0 as? CurlClient.Failure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testTimeout() {
        XCTAssertThrowsError(try client.perform(url: url("/hang"), timeout: 1)) {
            XCTAssertEqual($0 as? CurlClient.Failure, .timedOut)
        }
    }

    func testBodyPastTheCapIsRefused() {
        XCTAssertThrowsError(try client.perform(url: url("/big"), timeout: 5, maxBytes: 1_000)) {
            XCTAssertEqual($0 as? CurlClient.Failure, .tooLarge)
        }
    }

    func testRefusedConnectionIsATransportFailure() {
        server.stop()
        XCTAssertThrowsError(try client.perform(url: url("/echo"), timeout: 5)) {
            guard case .transport = $0 as? CurlClient.Failure else {
                return XCTFail("expected a transport failure, got \($0)")
            }
        }
    }

    /// The bridge borrows handles from several threads at once.
    func testConcurrentRequestsEachGetTheirOwnAnswer() {
        let group = DispatchGroup()
        let lock = NSLock()
        var answers: [String] = []
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                guard let response = try? self.client.perform(url: self.url("/echo"),
                                                              body: Data("\(i)".utf8), timeout: 5) else { return }
                lock.lock()
                answers.append(String(decoding: response.body, as: UTF8.self))
                lock.unlock()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(Set(answers), Set((0..<8).map { "POST \($0)" }))
    }
}

/// Just enough HTTP/1.1 to exercise a client: keep-alive, Content-Length bodies.
///
///   /echo    → "<METHOD> <body>"
///   /hang    → never answers
///   /big     → 64 KB
///   anything else → 404 with a JSON body
private final class LoopbackHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-http")
    private let lock = NSLock()
    private var connections = 0
    private var live: [NWConnection] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "LoopbackHTTPServer", code: 1)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = live
        live = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections += 1
        live.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, error == nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            while let request = Self.takeRequest(&buffer) {
                self.respond(to: request, on: connection)
            }
            if !done { self.read(connection, buffer: buffer) }
        }
    }

    private static func takeRequest(_ buffer: inout Data) -> (method: String, path: String, body: Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let length = lines.dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = buffer[bodyStart..<(bodyStart + length)]
        let request = (String(parts.first ?? ""), String(parts.count > 1 ? parts[1] : ""), Data(body))
        buffer = Data(buffer[(bodyStart + length)...])
        return request
    }

    private func respond(to request: (method: String, path: String, body: Data), on connection: NWConnection) {
        let status: String
        let body: Data
        switch request.path {
        case "/echo":
            status = "200 OK"
            body = Data("\(request.method) ".utf8) + request.body
        case "/hang":
            return
        case "/big":
            status = "200 OK"
            body = Data(repeating: 0x61, count: 64 * 1024)
        default:
            status = "404 Not Found"
            body = Data(#"{"ok":false}"#.utf8)
        }
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .idempotent)
    }
}
