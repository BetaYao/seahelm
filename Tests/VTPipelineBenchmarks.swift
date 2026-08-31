import XCTest
@testable import seahelm

/// Baseline measurements for the VT path, so a change to it can be shown to work
/// instead of argued about.
///
/// Two numbers, because the path has two separate problems:
///
///   * **Wire amplification** — what leaves the socket per byte the agent wrote.
///     Deterministic, so it runs with the normal suite and guards against the
///     framing quietly getting more expensive.
///   * **Keystroke echo RTT** — how long a typed byte takes to come back as
///     screen output, end to end through a real `HostGatewayServer` and a real
///     WebSocket. Timing-dependent, so it is opt-in:
///
///         TEST_RUNNER_SEAHELM_BENCH=1 xcodebuild -project seahelm.xcodeproj \
///           -scheme seahelmTests -configuration Debug \
///           -skipPackagePluginValidation -derivedDataPath .build test \
///           -only-testing:seahelmTests/VTPipelineBenchmarks
///
/// (`TEST_RUNNER_` is the prefix `xcodebuild` strips before handing a variable to
/// the test process; a bare `SEAHELM_BENCH=1` never reaches it and the benchmark
/// stays skipped.)
///
/// Both print an absolute report rather than only asserting, since the point is
/// to diff the numbers across a change. The harness deliberately keeps XCTest
/// expectations out of the timed path \u{2014} `wait(for:)` spins a runloop, and
/// measuring through it produced a phantom 200ms tail that was the harness, not
/// the pipeline.
final class VTPipelineBenchmarks: XCTestCase {

    // MARK: - Payload

    /// Real captured PTY output — `top` repainting in place, which is the shape
    /// an agent's status line has.
    ///
    /// This is the corpus the wire numbers are quoted against, and it exists
    /// because the synthetic generator below is a **liar about compression**: its
    /// hand-written repetition deflates to 0.020x, where real terminal output
    /// manages 0.21x. Anyone measuring a compression change against the synthetic
    /// stream would report a 50x win that does not exist.
    ///
    /// Stored raw-deflated (256KB → 53KB) so the repo carries a fixture rather
    /// than a quarter-megabyte blob, and inflated through the shipping code path.
    static func realRepaintCapture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/vt-top-repaint.deflate")
        let deflated = try Data(contentsOf: url)
        guard let raw = HostGatewayVTFrame.inflate(deflated), !raw.isEmpty else {
            throw XCTSkip("fixture failed to inflate")
        }
        return raw
    }

    static func chunked(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { start in
            data[start..<min(start + size, data.count)]
        }
    }

    /// A stand-in for what an agent puts on the wire: SGR colour, cursor motion,
    /// in-place spinner repaints, long runs of spaces.
    ///
    /// Kept for the encode-throughput loop, which only needs volume. Do **not**
    /// quote compression ratios off it — see `realRepaintCapture()`.
    static func agentRepaintStream(targetBytes: Int, chunkSize: Int = 512) -> [Data] {
        let spinner = ["\u{28CB}", "\u{28D9}", "\u{28F9}", "\u{28F8}",
                       "\u{28FC}", "\u{28F4}", "\u{28E6}", "\u{28E7}",
                       "\u{28C7}", "\u{28CF}"]
        var text = ""
        text.reserveCapacity(targetBytes + 4096)
        var i = 0
        while text.utf8.count < targetBytes {
            // The spinner line, repainted in place — the shape that made `zmx
            // attach` necessary in the first place.
            text += "\u{1B}[2K\r\u{1B}[38;5;244m\(spinner[i % spinner.count]) Thinking\u{2026}\u{1B}[0m"
            if i % 7 == 0 {
                text += "\r\n\u{1B}[32m+\u{1B}[0m\(String(repeating: " ", count: 10))"
                text += "let value = compute(\(i), scale: 1.0)\r\n"
            }
            if i % 23 == 0 {
                text += "\u{1B}[1A\u{1B}[2K\r"
            }
            i += 1
        }
        let data = Data(text.utf8)
        return stride(from: 0, to: data.count, by: chunkSize).map { start in
            data[start..<min(start + chunkSize, data.count)]
        }
    }

    /// Frames land on the manager's serial queue and are read from the test
    /// thread; the lock is what makes that legal rather than merely lucky.
    private final class FrameSink {
        private let lock = NSLock()
        private var frames: [String] = []

        func append(_ frame: String) {
            lock.lock(); defer { lock.unlock() }
            frames.append(frame)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }
    }

    // MARK: - Wire amplification

    /// How many bytes leave the socket per byte the agent wrote.
    ///
    /// Today the answer is ~1.35x: base64 costs exactly 4/3, and the JSON
    /// envelope adds a fixed ~70 bytes per frame on top. Moving VT to binary
    /// frames should take this to ~1.0x; compressing should take it below 1.
    func testVTFramingWireAmplification() {
        let chunks = Self.agentRepaintStream(targetBytes: 1 << 20)   // 1 MiB
        let payloadBytes = chunks.reduce(0) { $0 + $1.count }

        let spawner = RecordingVTProcessSpawner()
        let proc = FakeVTAttachedProcess()
        spawner.nextProcess = proc
        let sink = FrameSink()

        // A flush interval long enough that the timer never wins mid-loop: the
        // 48KB threshold and the final explicit flush decide the frame count, so
        // the measurement does not move with how fast the machine runs the loop.
        let manager = ZmxVTAttachManager(
            processSpawner: spawner,
            zmxPath: { "/usr/bin/true" },
            attachScriptPath: { "/dev/null" },
            sessionSize: { _ in (rows: 40, cols: 120) },
            flushInterval: 3600,
            queue: DispatchQueue(label: "bench.vt.amplification"))
        manager.addObserver { event in
            sink.append(HostGatewayFrame.encode(
                .notify(method: event.kind.legacyMethod, params: event.legacyNotifyParams)))
        }

        let key = "bench-amplification"
        _ = manager.open(paneSessionKey: key)
        manager.test_emitPendingSnapshot(paneSessionKey: key)   // leave snapshot phase

        let started = Date()
        for chunk in chunks {
            proc.emit(chunk)
        }
        manager.test_drain()
        manager.test_flushLiveData(paneSessionKey: key)
        manager.test_drain()
        let encodeSeconds = Date().timeIntervalSince(started)

        let frames = sink.all
        let vtDataFrames = frames.filter { $0.contains("\"vt.data\"") }
        let wireBytes = frames.reduce(0) { $0 + Data($1.utf8).count }

        // A benchmark that measured an empty pipeline would be worse than none:
        // prove every byte actually round-tripped before believing the ratio.
        let decoded = vtDataFrames.reduce(0) { total, frame in
            total + Self.decodedPayloadBytes(inNotifyFrame: frame)
        }
        XCTAssertEqual(decoded, payloadBytes, "frames did not carry the whole payload")

        let ratio = Double(wireBytes) / Double(payloadBytes)
        print("""

        [VT wire] payload      \(Self.kb(payloadBytes)) in \(chunks.count) chunks
        [VT wire] on the wire  \(Self.kb(wireBytes))  (\(String(format: "%.3f", ratio))x)
        [VT wire] frames       \(vtDataFrames.count) vt.data, avg \(Self.kb(wireBytes / max(vtDataFrames.count, 1)))/frame
        [VT wire] encode       \(String(format: "%.1f", encodeSeconds * 1000)) ms \
        (\(String(format: "%.1f", Double(payloadBytes) / encodeSeconds / 1_048_576)) MB/s)

        """)

        // Loose enough to be a regression guard, not a straitjacket: base64 alone
        // is 1.333x, so anything approaching 1.6 means a second layer crept in.
        XCTAssertLessThan(ratio, 1.6, "VT framing overhead grew")
    }

    /// The three wire formats side by side on real captured output, which is the
    /// number any framing change has to move.
    func testWireFormatsOnRealCapture() throws {
        let corpus = try Self.realRepaintCapture()
        let key = "seahelm-workspace-seahelm-2"

        // Frame at the same 48KB the manager flushes at under load, since that is
        // where the bandwidth actually goes.
        let frames = Self.chunked(corpus, size: ZmxVTTiming.maxChunkBytes)

        var legacy = 0, binary = 0, deflated = 0
        for chunk in frames {
            let event = VTEvent(kind: .data, paneSessionKey: key, payload: chunk)
            legacy += Data(HostGatewayFrame.encode(
                .notify(method: event.kind.legacyMethod, params: event.legacyNotifyParams)).utf8).count
            binary += HostGatewayVTFrame.encode(event, allowDeflate: false)?.count ?? 0
            deflated += HostGatewayVTFrame.encode(event, allowDeflate: true)?.count ?? 0
        }

        let n = corpus.count
        func line(_ label: String, _ bytes: Int) -> String {
            let ratio = Double(bytes) / Double(n)
            let saved = (1 - Double(bytes) / Double(legacy)) * 100
            return "[VT format] \(label.padding(toLength: 22, withPad: " ", startingAt: 0))"
                + "\(Self.kb(bytes))  \(String(format: "%.3f", ratio))x"
                + "  \(String(format: "%+.1f", -saved))% vs today"
        }
        print("\n[VT format] corpus \(Self.kb(n)) real `top` repaint, \(frames.count) frames\n"
              + line("today (JSON+base64)", legacy) + "\n"
              + line("binary", binary) + "\n"
              + line("binary + deflate", deflated) + "\n")

        // Round-trip fidelity matters more than the ratio: a smaller frame that
        // decodes to the wrong bytes is a corrupted terminal.
        for chunk in frames {
            let event = VTEvent(kind: .data, paneSessionKey: key, payload: chunk)
            let encoded = try XCTUnwrap(HostGatewayVTFrame.encode(event, allowDeflate: true))
            let decoded = try XCTUnwrap(HostGatewayVTFrame.decode(encoded))
            XCTAssertEqual(decoded.payload, Data(chunk))
            XCTAssertEqual(decoded.paneSessionKey, key)
        }

        XCTAssertLessThan(Double(binary) / Double(legacy), 0.80, "binary should drop ~25%")
        XCTAssertLessThan(Double(deflated) / Double(legacy), 0.30, "deflate should drop ~80%")
    }

    /// Snapshots carry geometry in the header; a lost resize misrenders the pane.
    func testBinaryFrameCarriesSnapshotGeometry() throws {
        let event = VTEvent(kind: .snapshot, paneSessionKey: "k",
                            payload: Data("hello".utf8), cols: 203, rows: 61)
        let encoded = try XCTUnwrap(HostGatewayVTFrame.encode(event, allowDeflate: true))
        let decoded = try XCTUnwrap(HostGatewayVTFrame.decode(encoded))
        XCTAssertEqual(decoded.kind, .snapshot)
        XCTAssertEqual(decoded.cols, 203)
        XCTAssertEqual(decoded.rows, 61)
        XCTAssertEqual(decoded.payload, Data("hello".utf8))
        XCTAssertFalse(decoded.wasCompressed, "a 5-byte payload must not pay for deflate")
    }

    // MARK: - Keystroke echo RTT

    /// A pipe that loops stdin straight back to stdout, standing in for
    /// `zmx-attach.py` + the session. Same kernel round trip, without needing a
    /// live zmx session — so what is left in the number is the manager's flush
    /// coalescing plus the gateway's socket path, which is the part we change.
    private final class EchoVTAttachedProcess: VTAttachedProcess {
        private let pipe = Pipe()
        let stdin: FileHandle?
        private var stdoutHandler: ((Data) -> Void)?

        init() {
            stdin = pipe.fileHandleForWriting
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.stdoutHandler?(data)
            }
        }

        func setStdoutHandler(_ handler: @escaping (Data) -> Void) { stdoutHandler = handler }
        func setTerminationHandler(_ handler: @escaping () -> Void) {}

        func terminate() {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private final class EchoVTProcessSpawner: VTProcessSpawning {
        let proc = EchoVTAttachedProcess()

        func spawn(python3: String, scriptPath: String, sessionKey: String,
                   rows: Int, cols: Int, zmxPath: String) throws -> VTAttachedProcess {
            proc
        }
    }

    /// Frames arrive from a background receive loop and are consumed by the
    /// measuring thread. XCTest expectations would work, but `wait(for:)` spins a
    /// runloop — putting XCTest's own scheduling inside the number we are trying
    /// to measure. A semaphore keeps the harness out of the hot path.
    private final class FrameInbox {
        private let lock = NSLock()
        private var frames: [String] = []
        private let arrived = DispatchSemaphore(value: 0)

        func deliver(_ frame: String) {
            lock.lock(); frames.append(frame); lock.unlock()
            arrived.signal()
        }

        /// Consume up to and including the first match, so a reply that preceded
        /// the push it provoked cannot satisfy the next call.
        @discardableResult
        func take(matching predicate: (String) -> Bool, timeout: TimeInterval) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                lock.lock()
                if let index = frames.firstIndex(where: predicate) {
                    let frame = frames[index]
                    frames.removeSubrange(0...index)
                    lock.unlock()
                    return frame
                }
                lock.unlock()
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return nil }
                _ = arrived.wait(timeout: .now() + remaining)
            }
        }
    }

    private func pump(_ task: URLSessionWebSocketTask, into inbox: FrameInbox) {
        task.receive { [weak self, weak task] result in
            switch result {
            case .success(.string(let text)): inbox.deliver(text)
            case .success(.data(let data)): inbox.deliver(String(decoding: data, as: UTF8.self))
            case .failure: return
            @unknown default: break
            }
            guard let self, let task, task.state == .running else { return }
            self.pump(task, into: inbox)
        }
    }

    /// Time from "browser sends a keystroke" to "the byte comes back as screen
    /// output", through the real server and a real WebSocket.
    ///
    /// The floor here is the manager's 16ms flush timer, which is applied
    /// unconditionally — a one-byte echo waits it out exactly like a build log
    /// does. This is the number that moves if that coalescing turns adaptive.
    func testKeystrokeEchoRoundTripLatency() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SEAHELM_BENCH"] == "1",
                          "timing benchmark \u{2014} re-run with TEST_RUNNER_SEAHELM_BENCH=1")

        let port: UInt16 = 27998
        let root = Data((0..<32).map { UInt8($0 &+ 7) })
        let macId = "bench"
        let key = "bench-echo"

        let spawner = EchoVTProcessSpawner()
        let manager = ZmxVTAttachManager(
            processSpawner: spawner,
            zmxPath: { "/usr/bin/true" },
            attachScriptPath: { "/dev/null" },
            sessionSize: { _ in (rows: 40, cols: 120) },
            // Real flush interval: it is the thing under measurement. Snapshot
            // idle is shortened only to get the benchmark to its live phase.
            snapshotIdle: 0.05,
            flushInterval: TimeInterval(ZmxVTTiming.flushMs) / 1000,
            queue: DispatchQueue(label: "bench.vt.echo"))

        let server = HostGatewayServer(
            config: HostGatewayConfig(enabled: true, port: port),
            router: ControlRouter(dataSource: BenchDataSource()),
            expectedMacId: macId,
            rootSecretBase64url: PairingCrypto.base64url(root),
            vt: manager)
        defer { server.stop() }

        let ready = expectation(description: "listening")
        server.start(onReady: { ready.fulfill() })
        wait(for: [ready], timeout: 5)

        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        let inbox = FrameInbox()
        task.resume()
        pump(task, into: inbox)
        defer { task.cancel(with: .goingAway, reason: nil) }

        let token = PairingCrypto(rootSecret: root).authPassword
        task.send(.string(#"{"id":"a","method":"auth","params":{"mac_id":"\#(macId)","token":"\#(token)"}}"#)) { _ in }
        XCTAssertNotNil(inbox.take(matching: { $0.contains("\"ok\"") }, timeout: 5), "auth failed")

        task.send(.string(#"{"id":"o","method":"pane.vt_open","params":{"pane_session_key":"\#(key)"}}"#)) { _ in }
        XCTAssertNotNil(inbox.take(matching: { $0.contains("vt.snapshot") }, timeout: 5),
                        "never reached the live phase")

        // Warm up: the first writes pay for pipe setup and socket ramp.
        for _ in 0..<5 { _ = roundTrip(on: task, key: key, inbox: inbox) }

        // Two regimes, because the flush policy deliberately treats them
        // differently and one number would hide that.
        //
        //   typing    \u{2014} a gap between keystrokes, which is what a person
        //               actually does. The stream is idle when the byte lands, so
        //               adaptive flush should answer immediately.
        //   sustained \u{2014} the next keystroke the instant the last echo lands.
        //               The stream is never idle, so coalescing is correct here:
        //               batching is the whole point once data is really flowing.
        let typing = (0..<30).map { _ -> TimeInterval in
            Thread.sleep(forTimeInterval: 0.12)   // ~8 chars/sec
            return roundTrip(on: task, key: key, inbox: inbox)
        }.sorted()
        let sustained = (0..<40).map { _ in roundTrip(on: task, key: key, inbox: inbox) }.sorted()

        func pct(_ xs: [TimeInterval], _ q: Double) -> TimeInterval {
            xs[min(Int(Double(xs.count) * q), xs.count - 1)]
        }

        func row(_ label: String, _ xs: [TimeInterval]) -> String {
            let name = label.padding(toLength: 10, withPad: " ", startingAt: 0)
            return "[VT echo] \(name)n=\(xs.count)  p50 \(Self.ms(pct(xs, 0.50)))"
                + "  p90 \(Self.ms(pct(xs, 0.90)))  min \(Self.ms(xs[0]))"
        }
        print("\n" + row("typing", typing) + "\n" + row("sustained", sustained)
              + "\n[VT echo] coalescing window \(ZmxVTTiming.flushMs) ms"
              + " \u{2014} bounds `sustained`; `typing` should sit well under it\n")

        // Only catches total breakage \u{2014} the printed numbers are the product.
        XCTAssertLessThan(pct(typing, 0.50), 1.0, "echo round trip collapsed")
        XCTAssertLessThan(pct(typing, 0.50), pct(sustained, 0.50) + 0.001,
                          "an idle stream should not be slower than a saturated one")
    }

    /// One keystroke in, one `vt.data` out.
    private func roundTrip(on task: URLSessionWebSocketTask, key: String, inbox: FrameInbox) -> TimeInterval {
        let started = Date()
        task.send(.string(
            #"{"id":"k","method":"pane.send_keys","params":{"pane_session_key":"\#(key)","b64":"eA=="}}"#
        )) { _ in }
        inbox.take(matching: { $0.contains("vt.data") }, timeout: 5)
        return Date().timeIntervalSince(started)
    }

    // MARK: - Reporting helpers

    private static func decodedPayloadBytes(inNotifyFrame frame: String) -> Int {
        guard let data = frame.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = obj["params"] as? [String: Any],
              let b64 = params["b64"] as? String,
              let decoded = Data(base64Encoded: b64) else { return 0 }
        return decoded.count
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }

    private static func kb(_ bytes: Int) -> String {
        bytes >= 1_048_576
            ? String(format: "%.2f MB", Double(bytes) / 1_048_576)
            : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}

private final class BenchDataSource: ControlDataSource {
    func snapshotPanes() -> [PaneSnapshot] { [] }
    func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
    func ingestHook(json: [String: Any]) -> String? { nil }
    func sendKeys(paneId: String, keys: [String]) -> Bool { false }
}
