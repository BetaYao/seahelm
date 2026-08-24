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

    private func connect(_ socketPath: String? = nil) -> Int32 {
        let target = socketPath ?? path!
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            target.withCString { strcpy(dst, $0) }
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

    /// Regression: when the path has been rebound by someone else, the first
    /// instance's stop() must not unlink it. It used to, which left the live
    /// server bound to an fd with no path on disk — `lsof` showed the socket,
    /// `ls` did not, and every hook silently no-op'd on its `[ -S ]` guard.
    ///
    /// The unlink here is deliberate and stands in for the real incident: a
    /// build without the standby guard (or any other process) clearing the path
    /// out from under a live listener. A current instance will not do this —
    /// see `testSecondInstanceStandsByRatherThanStealLiveSocket`.
    func testStopLeavesSocketRebornUnderNewerInstance() {
        let shared = "/tmp/sh-\(UUID().uuidString.prefix(8)).sock"
        let first = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()), path: shared)
        first.start()
        Thread.sleep(forTimeInterval: 0.1)

        // Strand `first`: with the path gone, `second` sees no live listener and
        // binds its own socket at the same name.
        unlink(shared)
        let second = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()), path: shared)
        second.start()
        Thread.sleep(forTimeInterval: 0.1)

        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared),
                      "stop() deleted the newer instance's socket file")

        // The survivor must still be reachable by a fresh client.
        let fd = connect(shared); defer { close(fd) }
        send(fd, #"{"id":"9","method":"ping"}"#)
        XCTAssertEqual((json(readLine(fd))?["result"] as? [String: Any])?["pong"] as? Bool, true)

        // And the owner still cleans up after itself.
        second.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared),
                       "stop() left a stale socket behind")
    }

    // MARK: - ownership + self-healing

    /// Layer 1. `start()` used to unlink the path unconditionally, so a second
    /// instance silently took the live app's socket and stranded it. Now it
    /// probes first: something is listening, so it stands down instead.
    func testSecondInstanceStandsByRatherThanStealLiveSocket() {
        let shared = "/tmp/sh-\(UUID().uuidString.prefix(8)).sock"
        let first = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()), path: shared)
        first.start()
        Thread.sleep(forTimeInterval: 0.1)
        var st = stat()
        XCTAssertEqual(stat(shared, &st), 0)
        let firstInode = st.st_ino

        let second = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()), path: shared)
        second.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { second.stop(); first.stop() }

        XCTAssertEqual(second.state, .standby, "second instance stole a live socket")
        XCTAssertEqual(first.state, .listening)

        // The file on disk must still be the first instance's socket...
        var after = stat()
        XCTAssertEqual(stat(shared, &after), 0)
        XCTAssertEqual(after.st_ino, firstInode, "the path was rebound under a live listener")

        // ...and the first instance must still answer on it.
        let fd = connect(shared); defer { close(fd) }
        send(fd, #"{"id":"10","method":"ping"}"#)
        XCTAssertEqual((json(readLine(fd))?["result"] as? [String: Any])?["pong"] as? Bool, true)
    }

    /// Layer 2. The exact production failure: the socket file vanishes while the
    /// listener is still bound to it. Nothing in-process notices on its own —
    /// accept() keeps waiting on an fd no client can name — so the health check
    /// has to spot it and rebind.
    func testHealthCheckRebindsAfterSocketFileVanishes() {
        let shared = "/tmp/sh-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()),
                                         path: shared, healthCheckInterval: 0.2)
        server.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { server.stop() }

        unlink(shared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared))

        XCTAssertTrue(waitUntil(2) { FileManager.default.fileExists(atPath: shared) },
                      "health check never rebound the vanished socket path")
        XCTAssertEqual(server.state, .listening)

        // Reachable again — a rebind that no client can use is not a recovery.
        let fd = connect(shared); defer { close(fd) }
        send(fd, #"{"id":"11","method":"ping"}"#)
        XCTAssertEqual((json(readLine(fd))?["result"] as? [String: Any])?["pong"] as? Bool, true)
    }

    /// Layer 2, the other direction: a stood-down instance is not dead. When the
    /// owner exits it takes the path with it, and the survivor claims it.
    func testStandbyInstanceTakesOverWhenOwnerStops() {
        let shared = "/tmp/sh-\(UUID().uuidString.prefix(8)).sock"
        let owner = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()), path: shared)
        owner.start()
        Thread.sleep(forTimeInterval: 0.1)

        let waiter = ControlSocketServer(router: ControlRouter(dataSource: FakeDS()),
                                         path: shared, healthCheckInterval: 0.2)
        waiter.start()
        Thread.sleep(forTimeInterval: 0.1)
        defer { waiter.stop() }
        XCTAssertEqual(waiter.state, .standby)

        owner.stop()
        XCTAssertTrue(waitUntil(2) { waiter.state == .listening },
                      "standby instance never claimed the freed socket path")

        let fd = connect(shared); defer { close(fd) }
        send(fd, #"{"id":"12","method":"ping"}"#)
        XCTAssertEqual((json(readLine(fd))?["result"] as? [String: Any])?["pong"] as? Bool, true)
    }

    /// Poll a condition rather than sleeping a fixed slice — the health check
    /// fires on its own timer and a fixed sleep is either flaky or slow.
    private func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return cond()
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
