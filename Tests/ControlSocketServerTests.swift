import XCTest
import Darwin
@testable import seahelm

/// End-to-end over a real Unix socket: exercises ControlSocketServer's framing,
/// per-connection threading, and the events.subscribe streaming path that the
/// pure-router unit tests can't reach.
final class ControlSocketServerTests: XCTestCase {

    private final class FakeDS: ControlDataSource {
        func snapshotPanes() -> [PaneSnapshot] {
            [PaneSnapshot(paneId: "t1", worktreePath: "/wt", branch: "main",
                          project: "proj", agentType: "Claude Code", status: "Running", lastMessage: "hi")]
        }
        func readPane(paneId: String, source: String, lines: Int) -> String? { "line" }
        func ingestHook(json: [String: Any]) -> String? { nil }
    }

    private var server: ControlSocketServer!
    private var path: String!

    override func setUp() {
        super.setUp()
        EventHub.shared.resetForTesting()
        path = "/tmp/sh-\(UUID().uuidString.prefix(8)).sock"
        server = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()), path: path)
        server.start()
        // Give the accept loop a beat to bind.
        Thread.sleep(forTimeInterval: 0.1)
    }

    override func tearDown() {
        server.stop()
        EventHub.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - socket client helper

    private func connect() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            path.withCString { strcpy(dst, $0) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        XCTAssertEqual(ok, 0, "connect failed: \(errno)")
        return fd
    }

    private func send(_ fd: Int32, _ s: String) {
        let line = s + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    /// Read one newline-terminated line (with a wall-clock guard).
    private func readLine(_ fd: Int32, timeout: TimeInterval = 2) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, 1)
            if n <= 0 { break }
            if chunk[0] == 0x0A { return String(decoding: buf, as: UTF8.self) }
            buf.append(chunk[0])
        }
        return buf.isEmpty ? nil : String(decoding: buf, as: UTF8.self)
    }

    private func json(_ line: String?) -> [String: Any]? {
        guard let line, let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    // MARK: - tests

    func testPingRoundTrip() {
        let fd = connect(); defer { close(fd) }
        send(fd, #"{"id":"1","method":"ping"}"#)
        let obj = json(readLine(fd))
        XCTAssertEqual(obj?["id"] as? String, "1")
        XCTAssertEqual((obj?["result"] as? [String: Any])?["pong"] as? Bool, true)
    }

    func testSnapshotOverSocket() {
        let fd = connect(); defer { close(fd) }
        send(fd, #"{"id":"2","method":"session.snapshot"}"#)
        let panes = (json(readLine(fd))?["result"] as? [String: Any])?["panes"] as? [[String: Any]]
        XCTAssertEqual(panes?.first?["pane_id"] as? String, "t1")
    }

    func testEventsSubscribeStreamsLiveEvent() {
        let fd = connect(); defer { close(fd) }
        send(fd, #"{"id":"3","method":"events.subscribe","params":{}}"#)
        // First line is the ack.
        let ack = json(readLine(fd))
        XCTAssertEqual((ack?["result"] as? [String: Any])?["subscribed"] as? Bool, true)
        // Publish an event; it should stream to the subscriber.
        EventHub.shared.publish(seq: 42, event: ["type": "pane.status_changed", "pane_id": "t1", "seq": 42])
        let ev = (json(readLine(fd))?["event"] as? [String: Any])
        XCTAssertEqual(ev?["type"] as? String, "pane.status_changed")
        XCTAssertEqual(ev?["seq"] as? Int, 42)
    }

    func testEventsSubscribeReplaysAfterSeq() {
        // Buffer some events first.
        for i in 1...3 { EventHub.shared.publish(seq: UInt64(i), event: ["type": "x", "pane_id": "t1", "seq": i]) }
        let fd = connect(); defer { close(fd) }
        send(fd, #"{"id":"4","method":"events.subscribe","params":{"events_after":1}}"#)
        _ = readLine(fd) // ack
        let e1 = (json(readLine(fd))?["event"] as? [String: Any])
        let e2 = (json(readLine(fd))?["event"] as? [String: Any])
        XCTAssertEqual([e1?["seq"] as? Int, e2?["seq"] as? Int], [2, 3])
    }
}
