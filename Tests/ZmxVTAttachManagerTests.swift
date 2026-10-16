import XCTest
@testable import seahelm

// MARK: - Fake attach process

final class FakeVTAttachedProcess: VTAttachedProcess {
    let stdin: FileHandle?
    private(set) var terminated = false
    private var stdoutHandler: ((Data) -> Void)?
    private var terminationHandler: (() -> Void)?

    init() {
        stdin = FileHandle(forWritingAtPath: "/dev/null")
    }

    func setStdoutHandler(_ handler: @escaping (Data) -> Void) {
        stdoutHandler = handler
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        terminationHandler = handler
    }

    func terminate() {
        terminated = true
        // Match Process.terminate(): the handler is not invoked synchronously
        // on the caller. Firing it here while ZmxVTAttachManager holds queue.sync
        // re-enters the serial queue and can deinit on that thread.
        terminationHandler = nil
    }

    /// Fires the attach-exit callback the same way `Process.terminationHandler` does.
    func fireTermination() {
        let handler = terminationHandler
        terminationHandler = nil
        handler?()
    }

    func emit(_ bytes: Data) {
        stdoutHandler?(bytes)
    }
}

final class RecordingVTProcessSpawner: VTProcessSpawning {
    private(set) var requests: [VTProcessSpawnRequest] = []
    var nextProcess: FakeVTAttachedProcess?

    func spawn(
        python3: String,
        scriptPath: String,
        sessionKey: String,
        rows: Int,
        cols: Int,
        zmxPath: String
    ) throws -> VTAttachedProcess {
        requests.append(VTProcessSpawnRequest(
            python3: python3,
            scriptPath: scriptPath,
            sessionKey: sessionKey,
            rows: rows,
            cols: cols,
            zmxPath: zmxPath))
        guard let proc = nextProcess else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no fake process"])
        }
        return proc
    }
}

// MARK: - Tests

final class ZmxVTAttachManagerTests: XCTestCase {
    private var fakeClock = Date(timeIntervalSince1970: 1_000_000)
    private var notifications: [(method: String, params: [String: Any])] = []

    private func makeManager(
        spawner: RecordingVTProcessSpawner,
        sessionSize: @escaping (String) -> (rows: Int, cols: Int)? = { _ in (rows: 40, cols: 100) },
        leaseTTL: TimeInterval = 5,
        snapshotIdle: TimeInterval = TimeInterval(ZmxVTTiming.snapshotIdleMs) / 1000,
        snapshotMax: TimeInterval = TimeInterval(ZmxVTTiming.snapshotMaxMs) / 1000,
        snapshotSettleMax: TimeInterval = TimeInterval(ZmxVTTiming.snapshotSettleMaxMs) / 1000,
        queue: DispatchQueue = DispatchQueue(label: "com.seahelm.ZmxVTAttachManager.test")
    ) -> ZmxVTAttachManager {
        let mgr = ZmxVTAttachManager(
            processSpawner: spawner,
            zmxPath: { "/fake/zmx" },
            attachScriptPath: { "/fake/zmx-attach.py" },
            sessionSize: sessionSize,
            now: { [unowned self] in self.fakeClock },
            leaseTTL: leaseTTL,
            snapshotIdle: snapshotIdle,
            snapshotMax: snapshotMax,
            snapshotSettleMax: snapshotSettleMax,
            queue: queue)
        mgr.addObserver { [unowned self] event in
            self.notifications.append((event.kind.legacyMethod, event.legacyNotifyParams))
        }
        return mgr
    }

    func testOpenSpawnsAttachHelperWithGeometry() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner)

        let result = mgr.open(paneSessionKey: "seahelm-repo-feat")

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["cols"] as? Int, 100)
        XCTAssertEqual(result["rows"] as? Int, 40)
        XCTAssertEqual(spawner.requests.count, 1)
        XCTAssertEqual(spawner.requests[0].sessionKey, "seahelm-repo-feat")
        XCTAssertEqual(spawner.requests[0].rows, 40)
        XCTAssertEqual(spawner.requests[0].cols, 100)
        XCTAssertEqual(spawner.requests[0].zmxPath, "/fake/zmx")
        XCTAssertEqual(spawner.requests[0].python3, "/usr/bin/python3")
    }

    func testDefaultGeometryWhenSessionSizeUnavailable() {
        let spawner = RecordingVTProcessSpawner()
        spawner.nextProcess = FakeVTAttachedProcess()
        let mgr = makeManager(spawner: spawner, sessionSize: { _ in nil })

        let result = mgr.open(paneSessionKey: "missing")

        XCTAssertEqual(result["cols"] as? Int, ZmxVTTiming.defaultCols)
        XCTAssertEqual(result["rows"] as? Int, ZmxVTTiming.defaultRows)
        XCTAssertEqual(spawner.requests[0].cols, ZmxVTTiming.defaultCols)
        XCTAssertEqual(spawner.requests[0].rows, ZmxVTTiming.defaultRows)
    }

    func testSnapshotThenLiveDataNotifications() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner)

        _ = mgr.open(paneSessionKey: "p1")
        fake.emit(Data("hello".utf8))
        mgr.test_drain()
        mgr.test_emitPendingSnapshot(paneSessionKey: "p1")

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications[0].method, "vt.snapshot")
        XCTAssertEqual(notifications[0].params["pane_session_key"] as? String, "p1")
        XCTAssertEqual(notifications[0].params["cols"] as? Int, 100)
        XCTAssertEqual(notifications[0].params["rows"] as? Int, 40)
        let snapB64 = notifications[0].params["b64"] as? String
        XCTAssertEqual(String(data: Data(base64Encoded: snapB64!)!, encoding: .utf8), "hello")

        fake.emit(Data("world".utf8))
        mgr.test_drain()
        mgr.test_flushLiveData(paneSessionKey: "p1")

        XCTAssertEqual(notifications.count, 2)
        XCTAssertEqual(notifications[1].method, "vt.data")
        let liveB64 = notifications[1].params["b64"] as? String
        XCTAssertEqual(String(data: Data(base64Encoded: liveB64!)!, encoding: .utf8), "world")
    }

    /// A busy pane never goes quiet for the idle window. Its snapshot must still
    /// arrive shortly after the first byte — not at the open's cap — and what
    /// the snapshot did not take must follow as data, in order.
    func testBusyPaneSnapshotsSoonAfterFirstByte() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let queue = DispatchQueue(label: "busy.test")
        let mgr = makeManager(spawner: spawner, snapshotIdle: 0.2, snapshotMax: 5, snapshotSettleMax: 0.1, queue: queue)
        var got: [(String, Date, String)] = []
        let lock = NSLock()
        mgr.addObserver { e in
            lock.lock(); got.append((e.kind.legacyMethod, Date(), String(decoding: e.payload, as: UTF8.self))); lock.unlock()
        }
        _ = mgr.open(paneSessionKey: "busy")
        let start = Date()
        // A frame every 30ms for ~0.6s: never 0.2s of quiet.
        for i in 0..<20 {
            fake.emit(Data("f\(i);".utf8))
            Thread.sleep(forTimeInterval: 0.03)
        }
        Thread.sleep(forTimeInterval: 0.1)
        mgr.test_flushLiveData(paneSessionKey: "busy")
        lock.lock(); let events = got; lock.unlock()

        let snap = events.first { $0.0 == "vt.snapshot" }
        XCTAssertNotNil(snap, "a busy pane still gets its snapshot")
        if let snap {
            XCTAssertLessThan(snap.1.timeIntervalSince(start), 0.5, "well before the 5s open cap")
            XCTAssertTrue(snap.2.hasPrefix("f0;"), "the snapshot starts with the first output")
        }
        XCTAssertEqual(events.first?.0, "vt.snapshot", "nothing is sent before the snapshot")
        let all = events.map { $0.2 }.joined()
        XCTAssertEqual(all, (0..<20).map { "f\($0);" }.joined(), "every byte arrives once, in order")
    }

    /// A pane that goes quiet still closes on the idle window, settle cap or not.
    func testQuietPaneSnapshotsOnIdle() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner, snapshotIdle: 0.05, snapshotMax: 5, snapshotSettleMax: 2)
        let done = expectation(description: "snapshot")
        var payload = ""
        mgr.addObserver { e in
            if e.kind.legacyMethod == "vt.snapshot" { payload = String(decoding: e.payload, as: UTF8.self); done.fulfill() }
        }
        _ = mgr.open(paneSessionKey: "quiet")
        fake.emit(Data("prompt$ ".utf8))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(payload, "prompt$ ")
    }

    func testCloseTerminatesAttachChildOnly() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner)

        _ = mgr.open(paneSessionKey: "p1")
        mgr.close(paneSessionKey: "p1")

        XCTAssertTrue(fake.terminated)
    }

    func testSendKeysReturnsTrueForOpenStream() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner)

        _ = mgr.open(paneSessionKey: "p1")
        XCTAssertTrue(mgr.sendKeys(paneSessionKey: "p1", utf8: Data("hi".utf8)))
        XCTAssertFalse(mgr.sendKeys(paneSessionKey: "p1", utf8: Data()))
    }

    func testKeepaliveExtendsLease() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner, leaseTTL: 10)

        _ = mgr.open(paneSessionKey: "p1")
        fakeClock = fakeClock.addingTimeInterval(8)
        mgr.keepalive(paneSessionKey: "p1")
        fakeClock = fakeClock.addingTimeInterval(8)
        mgr.test_reapLeases(now: fakeClock)

        XCTAssertFalse(fake.terminated)
    }

    func testReapExpiredLeaseClosesStream() {
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        let mgr = makeManager(spawner: spawner, leaseTTL: 10)

        _ = mgr.open(paneSessionKey: "p1")
        fakeClock = fakeClock.addingTimeInterval(11)
        mgr.test_reapLeases(now: fakeClock)

        XCTAssertTrue(fake.terminated)
    }

    func testReopenReplacesPreviousStream() {
        let spawner = RecordingVTProcessSpawner()
        let first = FakeVTAttachedProcess()
        let second = FakeVTAttachedProcess()
        spawner.nextProcess = first
        let mgr = makeManager(spawner: spawner)

        _ = mgr.open(paneSessionKey: "p1")
        spawner.nextProcess = second
        _ = mgr.open(paneSessionKey: "p1")

        XCTAssertTrue(first.terminated)
        XCTAssertFalse(second.terminated)
        XCTAssertEqual(spawner.requests.count, 2)
    }

    func testDeinitFromManagerQueueDoesNotTrap() {
        let queue = DispatchQueue(label: "com.seahelm.ZmxVTAttachManager.deinit-test")
        let spawner = RecordingVTProcessSpawner()
        spawner.nextProcess = FakeVTAttachedProcess()
        var mgr: ZmxVTAttachManager? = makeManager(spawner: spawner, queue: queue)
        weak var weakMgr = mgr
        _ = mgr!.open(paneSessionKey: "p1")

        let deallocated = expectation(description: "manager released on its own queue")
        queue.async {
            mgr = nil
            XCTAssertNil(weakMgr)
            deallocated.fulfill()
        }
        wait(for: [deallocated], timeout: 2)
        XCTAssertNil(mgr)
        XCTAssertNil(weakMgr)
    }

    func testDeinitAfterAttachExitOnQueueDoesNotTrap() {
        let queue = DispatchQueue(label: "com.seahelm.ZmxVTAttachManager.exit-deinit-test")
        let spawner = RecordingVTProcessSpawner()
        let fake = FakeVTAttachedProcess()
        spawner.nextProcess = fake
        var mgr: ZmxVTAttachManager? = makeManager(spawner: spawner, queue: queue)
        weak var weakMgr = mgr
        _ = mgr!.open(paneSessionKey: "p1")
        fake.fireTermination()
        mgr = nil

        let drained = expectation(description: "queue drained after attach exit")
        queue.async {
            XCTAssertNil(weakMgr)
            drained.fulfill()
        }
        wait(for: [drained], timeout: 2)
    }

    func testSessionPidParsing() {
        let output = """
        name=seahelm-a-feat\tpid=4242\tclients=1
        """
        XCTAssertEqual(ProcessProbe.sessionPid(paneSessionKey: "seahelm-a-feat", zmxListOutput: output), 4242)
    }
}
