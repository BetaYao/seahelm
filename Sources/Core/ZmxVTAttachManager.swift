import Foundation

// MARK: - Timing constants (ported from zmx-vt.js)

enum ZmxVTTiming {
    static let snapshotIdleMs: Int = 160
    static let snapshotMaxMs: Int = 2500
    static let flushMs: Int = 16
    static let leaseTTLMs: Int = 60_000
    static let maxChunkBytes: Int = 48 * 1024
    static let defaultCols: Int = 120
    static let defaultRows: Int = 32
}

// MARK: - Process spawning seam (unit-test injectable)

protocol VTAttachedProcess: AnyObject {
    var stdin: FileHandle? { get }
    func terminate()
    func setStdoutHandler(_ handler: @escaping (Data) -> Void)
    func setTerminationHandler(_ handler: @escaping () -> Void)
}

protocol VTProcessSpawning {
    func spawn(
        python3: String,
        scriptPath: String,
        sessionKey: String,
        rows: Int,
        cols: Int,
        zmxPath: String
    ) throws -> VTAttachedProcess
}

struct VTProcessSpawnRequest: Equatable {
    let python3: String
    let scriptPath: String
    let sessionKey: String
    let rows: Int
    let cols: Int
    let zmxPath: String
}

final class LiveVTAttachedProcess: VTAttachedProcess {
    private let process: Process
    let stdin: FileHandle?
    private var stdoutHandler: ((Data) -> Void)?

    init(process: Process, stdout: Pipe, stdinPipe: Pipe) {
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        let readHandle = stdout.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stdoutHandler?(data)
        }
    }

    func setStdoutHandler(_ handler: @escaping (Data) -> Void) {
        stdoutHandler = handler
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        process.terminationHandler = { _ in handler() }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

final class DefaultVTProcessSpawner: VTProcessSpawning {
    func spawn(
        python3: String,
        scriptPath: String,
        sessionKey: String,
        rows: Int,
        cols: Int,
        zmxPath: String
    ) throws -> VTAttachedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3)
        process.arguments = [scriptPath, sessionKey, String(rows), String(cols)]

        var env = ProcessInfo.processInfo.environment
        env["ZMX"] = zmxPath
        env.removeValue(forKey: "ZMX_SESSION")
        process.environment = env

        let outPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = inPipe

        try process.run()
        return LiveVTAttachedProcess(process: process, stdout: outPipe, stdinPipe: inPipe)
    }
}

// MARK: - Manager

final class ZmxVTAttachManager: HostGatewayVTAttaching {
    var onNotify: ((String, [String: Any]) -> Void)?

    private enum Phase {
        case snapshot
        case live
    }

    private struct StreamState {
        let proc: VTAttachedProcess
        let cols: Int
        let rows: Int
        var phase: Phase
        var buffer: [Data] = []
        var bufferLen: Int = 0
        var flushWorkItem: DispatchWorkItem?
        var snapshotIdleWorkItem: DispatchWorkItem?
        var snapshotCapWorkItem: DispatchWorkItem?
        var lastSeen: Date
    }

    private let processSpawner: VTProcessSpawning
    private let zmxPath: () -> String
    private let attachScriptPath: () -> String?
    private let sessionSize: (String) -> (rows: Int, cols: Int)?
    private let now: () -> Date
    private let leaseTTL: TimeInterval
    private let snapshotIdle: TimeInterval
    private let snapshotMax: TimeInterval
    private let flushInterval: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var streams: [String: StreamState] = [:]
    private var leaseTimer: DispatchSourceTimer?

    init(
        processSpawner: VTProcessSpawning = DefaultVTProcessSpawner(),
        zmxPath: @escaping () -> String = { ZmxLocator.executable() },
        attachScriptPath: @escaping () -> String? = { ZmxVTAttachManager.bundledAttachScriptPath() },
        sessionSize: @escaping (String) -> (rows: Int, cols: Int)? = { ZmxVTAttachManager.defaultSessionSize(for: $0) },
        now: @escaping () -> Date = Date.init,
        leaseTTL: TimeInterval = TimeInterval(ZmxVTTiming.leaseTTLMs) / 1000,
        snapshotIdle: TimeInterval = TimeInterval(ZmxVTTiming.snapshotIdleMs) / 1000,
        snapshotMax: TimeInterval = TimeInterval(ZmxVTTiming.snapshotMaxMs) / 1000,
        flushInterval: TimeInterval = TimeInterval(ZmxVTTiming.flushMs) / 1000,
        queue: DispatchQueue = DispatchQueue(label: "com.seahelm.ZmxVTAttachManager")
    ) {
        self.processSpawner = processSpawner
        self.zmxPath = zmxPath
        self.attachScriptPath = attachScriptPath
        self.sessionSize = sessionSize
        self.now = now
        self.leaseTTL = leaseTTL
        self.snapshotIdle = snapshotIdle
        self.snapshotMax = snapshotMax
        self.flushInterval = flushInterval
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
        startLeaseTimer()
    }

    deinit {
        leaseTimer?.cancel()
        // Last retain can be dropped by a work item already on `queue`
        // (nested async captures). `queue.sync` from that thread traps.
        syncOnQueue {
            for key in Array(streams.keys) {
                tearDown(key: key, reason: "shutdown")
            }
        }
    }

    private func syncOnQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    func open(paneSessionKey: String) -> [String: Any] {
        queue.sync {
            openLocked(paneSessionKey: paneSessionKey)
        }
    }

    func close(paneSessionKey: String) {
        queue.sync {
            tearDown(key: paneSessionKey, reason: "closed")
        }
    }

    func keepalive(paneSessionKey: String) {
        queue.sync {
            guard var st = streams[paneSessionKey] else { return }
            st.lastSeen = now()
            streams[paneSessionKey] = st
        }
    }

    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool {
        queue.sync {
            guard let st = streams[paneSessionKey], let stdin = st.proc.stdin, !utf8.isEmpty else {
                return false
            }
            do {
                try stdin.write(contentsOf: utf8)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: Test hooks

    func test_emitPendingSnapshot(paneSessionKey: String) {
        queue.sync {
            closeSnapshot(key: paneSessionKey)
        }
    }

    func test_flushLiveData(paneSessionKey: String) {
        queue.sync {
            flushLive(key: paneSessionKey)
        }
    }

    func test_reapLeases(now overrideNow: Date) {
        queue.sync {
            reapLeases(now: overrideNow)
        }
    }

    func test_drain() {
        queue.sync { }
    }

    // MARK: Geometry

    static func bundledAttachScriptPath() -> String? {
        Bundle.main.url(forResource: "zmx-attach", withExtension: "py")?.path
    }

    static func defaultSessionSize(for paneSessionKey: String) -> (rows: Int, cols: Int)? {
        guard let listOutput = ProcessRunner.output([ZmxLocator.executable(), "list"]) else { return nil }
        guard let pid = ProcessProbe.sessionPid(paneSessionKey: paneSessionKey, zmxListOutput: listOutput) else {
            return nil
        }
        guard let ttyOut = ProcessRunner.output(["ps", "-o", "tty=", "-p", String(pid)]) else { return nil }
        let tty = ttyOut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tty.isEmpty, tty != "??" else { return nil }
        guard let sizeOut = ProcessRunner.output(["stty", "-f", "/dev/\(tty)", "size"]) else { return nil }
        let parts = sizeOut.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              let rows = Int(parts[0]),
              let cols = Int(parts[1]) else { return nil }
        return (rows: rows, cols: cols)
    }

    static func resolvedGeometry(for paneSessionKey: String,
                                 lookup: (String) -> (rows: Int, cols: Int)?) -> (rows: Int, cols: Int) {
        lookup(paneSessionKey) ?? (rows: ZmxVTTiming.defaultRows, cols: ZmxVTTiming.defaultCols)
    }

    // MARK: Private

    private func openLocked(paneSessionKey: String) -> [String: Any] {
        guard !paneSessionKey.isEmpty else { return ["ok": false, "error": "missing pane_session_key"] }
        if streams[paneSessionKey] != nil {
            tearDown(key: paneSessionKey, reason: "reopened")
        }

        let geometry = Self.resolvedGeometry(for: paneSessionKey, lookup: sessionSize)
        guard let scriptPath = attachScriptPath() else {
            return ["ok": false, "error": "zmx-attach.py not bundled"]
        }

        let proc: VTAttachedProcess
        do {
            proc = try processSpawner.spawn(
                python3: "/usr/bin/python3",
                scriptPath: scriptPath,
                sessionKey: paneSessionKey,
                rows: geometry.rows,
                cols: geometry.cols,
                zmxPath: zmxPath())
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

        var st = StreamState(
            proc: proc,
            cols: geometry.cols,
            rows: geometry.rows,
            phase: .snapshot,
            lastSeen: now())
        streams[paneSessionKey] = st
        wireProcess(key: paneSessionKey, proc: proc)
        scheduleSnapshotClose(key: paneSessionKey)

        return [
            "ok": true,
            "cols": geometry.cols,
            "rows": geometry.rows,
        ]
    }

    private func wireProcess(key: String, proc: VTAttachedProcess) {
        proc.setStdoutHandler { [weak self] chunk in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.handleStdout(key: key, chunk: chunk)
            }
        }
        proc.setTerminationHandler { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.streams[key]?.proc === proc else { return }
                self.tearDown(key: key, reason: "attach exited")
            }
        }
    }

    private func handleStdout(key: String, chunk: Data) {
        guard var st = streams[key] else { return }
        st.buffer.append(chunk)
        st.bufferLen += chunk.count

        switch st.phase {
        case .snapshot:
            streams[key] = st
            scheduleSnapshotClose(key: key)
        case .live:
            streams[key] = st
            if st.bufferLen >= ZmxVTTiming.maxChunkBytes {
                flushLive(key: key)
            } else if st.flushWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.queue.async {
                        self?.flushLive(key: key)
                    }
                }
                st.flushWorkItem = work
                streams[key] = st
                queue.asyncAfter(deadline: .now() + flushInterval, execute: work)
            }
        }
    }

    private func scheduleSnapshotClose(key: String) {
        guard var st = streams[key], st.phase == .snapshot else { return }
        st.snapshotIdleWorkItem?.cancel()
        let idleWork = DispatchWorkItem { [weak self] in
            self?.queue.async {
                self?.closeSnapshot(key: key)
            }
        }
        st.snapshotIdleWorkItem = idleWork
        if st.snapshotCapWorkItem == nil {
            let capWork = DispatchWorkItem { [weak self] in
                self?.queue.async {
                    self?.closeSnapshot(key: key)
                }
            }
            st.snapshotCapWorkItem = capWork
            queue.asyncAfter(deadline: .now() + snapshotMax, execute: capWork)
        }
        streams[key] = st
        queue.asyncAfter(deadline: .now() + snapshotIdle, execute: idleWork)
    }

    private func closeSnapshot(key: String) {
        guard var st = streams[key], st.phase == .snapshot else { return }
        st.snapshotIdleWorkItem?.cancel()
        st.snapshotIdleWorkItem = nil
        st.snapshotCapWorkItem?.cancel()
        st.snapshotCapWorkItem = nil
        st.phase = .live

        let chunk = st.bufferLen > 0 ? Data(st.buffer.reduce(into: Data()) { $0.append($1) }) : Data()
        st.buffer = []
        st.bufferLen = 0
        streams[key] = st

        emitNotify(method: "vt.snapshot", key: key, chunk: chunk, cols: st.cols, rows: st.rows)
    }

    private func flushLive(key: String) {
        guard var st = streams[key], st.phase == .live, st.bufferLen > 0 else { return }
        st.flushWorkItem?.cancel()
        st.flushWorkItem = nil
        let chunk = st.buffer.reduce(into: Data()) { $0.append($1) }
        st.buffer = []
        st.bufferLen = 0
        streams[key] = st
        emitNotify(method: "vt.data", key: key, chunk: chunk, cols: nil, rows: nil)
    }

    private func emitNotify(method: String, key: String, chunk: Data, cols: Int?, rows: Int?) {
        var params: [String: Any] = [
            "pane_session_key": key,
            "b64": chunk.base64EncodedString(),
        ]
        if let cols { params["cols"] = cols }
        if let rows { params["rows"] = rows }
        onNotify?(method, params)
    }

    private func tearDown(key: String, reason: String) {
        guard let st = streams.removeValue(forKey: key) else { return }
        st.flushWorkItem?.cancel()
        st.snapshotIdleWorkItem?.cancel()
        st.snapshotCapWorkItem?.cancel()
        st.proc.terminate()
        _ = reason
    }

    private func startLeaseTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + leaseTTL / 4, repeating: leaseTTL / 4)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reapLeases(now: self.now())
        }
        timer.resume()
        leaseTimer = timer
    }

    private func reapLeases(now: Date) {
        for (key, st) in streams where now.timeIntervalSince(st.lastSeen) > leaseTTL {
            tearDown(key: key, reason: "lease expired")
        }
    }
}
