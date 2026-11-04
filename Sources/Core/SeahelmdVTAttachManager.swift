import Foundation

// MARK: - Timing constants

enum SeahelmdVTTiming {
    static let snapshotIdleMs: Int = 160
    /// Measured from the open: the attach may take this long to say anything.
    static let snapshotMaxMs: Int = 2500
    /// Measured from the first byte. The opening redraw lands as one burst, but
    /// a pane that is busy — an agent's spinner repainting every 100ms — never
    /// goes quiet for `snapshotIdleMs`, so without this every such pane waited
    /// out the full `snapshotMaxMs` before its screen appeared. Whatever the
    /// snapshot does not catch follows as ordinary data, in order.
    static let snapshotSettleMaxMs: Int = 300
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
        sessionKey: String,
        rows: Int,
        cols: Int,
        seahelmdPath: String
    ) throws -> VTAttachedProcess
}

struct VTProcessSpawnRequest: Equatable {
    let sessionKey: String
    let rows: Int
    let cols: Int
    let seahelmdPath: String
}

final class LiveVTAttachedProcess: VTAttachedProcess {
    private let process: Process
    let stdin: FileHandle?
    /// Held so `terminate` can clear the handler — leaving it set keeps the
    /// FileHandle registered with the run loop after the process is gone.
    private let stdoutRead: FileHandle
    private var stdoutHandler: ((Data) -> Void)?

    init(process: Process, stdout: Pipe, stdinPipe: Pipe) {
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutRead = stdout.fileHandleForReading
        stdoutRead.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stdoutHandler?(data)
        }
    }

    func setStdoutHandler(_ handler: @escaping (Data) -> Void) {
        stdoutHandler = handler
    }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        process.terminationHandler = { [weak self] _ in
            self?.teardownPipes()
            handler()
        }
    }

    func terminate() {
        teardownPipes()
        if process.isRunning {
            process.terminate()
        }
    }

    private func teardownPipes() {
        stdoutRead.readabilityHandler = nil
        try? stdoutRead.close()
        try? stdin?.close()
    }
}

final class DefaultVTProcessSpawner: VTProcessSpawning {
    /// `seahelmd pipe <session> <rows> <cols>`: the session's raw VT stream
    /// on stdout and stdin to its input, at the session's own size (attaching
    /// at another could resize it under the Mac).
    func spawn(
        sessionKey: String,
        rows: Int,
        cols: Int,
        seahelmdPath: String
    ) throws -> VTAttachedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: seahelmdPath)
        process.arguments = ["pipe", sessionKey, String(rows), String(cols)]

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

final class SeahelmdVTAttachManager: HostGatewayVTAttaching {
    /// Observers, not one closure. A single slot meant every new browser session
    /// overwrote the previous one's callback on this shared manager, so opening a
    /// second tab silently killed the first tab's terminal.
    private var observers: [Int: (VTEvent) -> Void] = [:]
    private var nextObserverToken = 1

    private enum Phase {
        case snapshot
        case live
    }

    private struct StreamState {
        let proc: VTAttachedProcess
        let cols: Int
        let rows: Int
        var phase: Phase
        /// One growing `Data`, not an array of chunks. The array had to be
        /// concatenated on every flush, allocating and copying the whole buffer
        /// again each time; appending in place reuses the capacity.
        var buffer = Data()
        var flushWorkItem: DispatchWorkItem?
        var snapshotIdleWorkItem: DispatchWorkItem?
        var snapshotCapWorkItem: DispatchWorkItem?
        var snapshotSettleWorkItem: DispatchWorkItem?
        var lastSeen: Date
        /// When this stream last emitted, so an idle pane can answer immediately
        /// instead of serving out a coalescing window nothing is filling.
        var lastFlush: Date
    }

    private let processSpawner: VTProcessSpawning
    private let seahelmdPath: (String) -> String
    private let sessionSize: (String) -> (rows: Int, cols: Int)?
    private let now: () -> Date
    private let leaseTTL: TimeInterval
    private let snapshotIdle: TimeInterval
    private let snapshotMax: TimeInterval
    private let snapshotSettleMax: TimeInterval
    private let flushInterval: TimeInterval
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var streams: [String: StreamState] = [:]
    private var leaseTimer: DispatchSourceTimer?

    init(
        processSpawner: VTProcessSpawning = DefaultVTProcessSpawner(),
        seahelmdPath: @escaping (String) -> String = { _ in SeahelmdLocator.executable() },
        sessionSize: @escaping (String) -> (rows: Int, cols: Int)? = { SeahelmdVTAttachManager.defaultSessionSize(for: $0) },
        now: @escaping () -> Date = Date.init,
        leaseTTL: TimeInterval = TimeInterval(SeahelmdVTTiming.leaseTTLMs) / 1000,
        snapshotIdle: TimeInterval = TimeInterval(SeahelmdVTTiming.snapshotIdleMs) / 1000,
        snapshotMax: TimeInterval = TimeInterval(SeahelmdVTTiming.snapshotMaxMs) / 1000,
        snapshotSettleMax: TimeInterval = TimeInterval(SeahelmdVTTiming.snapshotSettleMaxMs) / 1000,
        flushInterval: TimeInterval = TimeInterval(SeahelmdVTTiming.flushMs) / 1000,
        queue: DispatchQueue = DispatchQueue(label: "com.seahelm.SeahelmdVTAttachManager")
    ) {
        self.processSpawner = processSpawner
        self.seahelmdPath = seahelmdPath
        self.sessionSize = sessionSize
        self.now = now
        self.leaseTTL = leaseTTL
        self.snapshotIdle = snapshotIdle
        self.snapshotMax = snapshotMax
        self.snapshotSettleMax = snapshotSettleMax
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

    @discardableResult
    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    @discardableResult
    func addObserver(_ observer: @escaping (VTEvent) -> Void) -> Int {
        syncOnQueue {
            let token = nextObserverToken
            nextObserverToken += 1
            observers[token] = observer
            return token
        }
    }

    func removeObserver(_ token: Int) {
        syncOnQueue { _ = observers.removeValue(forKey: token) }
    }

    func open(paneSessionKey: String) -> [String: Any] {
        syncOnQueue {
            openLocked(paneSessionKey: paneSessionKey)
        }
    }

    func close(paneSessionKey: String) {
        syncOnQueue {
            tearDown(key: paneSessionKey, reason: "closed")
        }
    }

    func keepalive(paneSessionKey: String) {
        syncOnQueue {
            guard var st = streams[paneSessionKey] else { return }
            st.lastSeen = now()
            streams[paneSessionKey] = st
        }
    }

    func sendKeys(paneSessionKey: String, utf8: Data) -> Bool {
        syncOnQueue {
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
        syncOnQueue {
            closeSnapshot(key: paneSessionKey)
        }
    }

    func test_flushLiveData(paneSessionKey: String) {
        syncOnQueue {
            flushLive(key: paneSessionKey)
        }
    }

    func test_reapLeases(now overrideNow: Date) {
        syncOnQueue {
            reapLeases(now: overrideNow)
        }
    }

    func test_drain() {
        syncOnQueue { }
    }

    // MARK: Geometry

    static func defaultSessionSize(for paneSessionKey: String) -> (rows: Int, cols: Int)? {
        guard let listOutput = SeahelmdLocator.listOutput() else { return nil }
        guard let pid = ProcessProbe.sessionPid(paneSessionKey: paneSessionKey, seahelmdListOutput: listOutput) else {
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
        lookup(paneSessionKey) ?? (rows: SeahelmdVTTiming.defaultRows, cols: SeahelmdVTTiming.defaultCols)
    }

    // MARK: Private

    private func openLocked(paneSessionKey: String) -> [String: Any] {
        guard !paneSessionKey.isEmpty else { return ["ok": false, "error": "missing pane_session_key"] }
        if streams[paneSessionKey] != nil {
            tearDown(key: paneSessionKey, reason: "reopened")
        }

        let geometry = Self.resolvedGeometry(for: paneSessionKey, lookup: sessionSize)

        let proc: VTAttachedProcess
        do {
            proc = try processSpawner.spawn(
                sessionKey: paneSessionKey,
                rows: geometry.rows,
                cols: geometry.cols,
                seahelmdPath: seahelmdPath(paneSessionKey))
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }

        var st = StreamState(
            proc: proc,
            cols: geometry.cols,
            rows: geometry.rows,
            phase: .snapshot,
            lastSeen: now(),
            lastFlush: now())
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

        switch st.phase {
        case .snapshot:
            streams[key] = st
            scheduleSnapshotClose(key: key)
        case .live:
            streams[key] = st
            // Coalescing used to be unconditional, so a one-byte keystroke echo
            // sat out the full window exactly like a build log did — measured as
            // ~16ms of the 17.9ms round trip on loopback, where there is no
            // network to blame. Send immediately when the stream has been quiet,
            // and only batch once it is actually streaming: bursts still cost at
            // most one frame per window.
            // Clamped, because `now` is a wall clock — the same source the lease
            // reaper uses, and injectable for tests. A backward step (sleep/wake
            // correction, `settimeofday`, a VM host resync) made this negative,
            // which put the coalescing deadline `flushInterval - sinceLastFlush`
            // an hour out; every later chunk then found `flushWorkItem` already
            // set and did nothing, so the pane emitted nothing at all until it
            // hit the 48KB cap. An interactive shell just froze.
            let sinceLastFlush = max(0, now().timeIntervalSince(st.lastFlush))
            if st.buffer.count >= SeahelmdVTTiming.maxChunkBytes || sinceLastFlush >= flushInterval {
                flushLive(key: key)
            } else if st.flushWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.flushLive(key: key)
                }
                st.flushWorkItem = work
                streams[key] = st
                queue.asyncAfter(deadline: .now() + (flushInterval - sinceLastFlush), execute: work)
            }
        }
    }

    private func scheduleSnapshotClose(key: String) {
        guard var st = streams[key], st.phase == .snapshot else { return }
        st.snapshotIdleWorkItem?.cancel()
        let idleWork = DispatchWorkItem { [weak self] in
            self?.closeSnapshot(key: key)
        }
        st.snapshotIdleWorkItem = idleWork
        if st.snapshotCapWorkItem == nil {
            let capWork = DispatchWorkItem { [weak self] in
                self?.closeSnapshot(key: key)
            }
            st.snapshotCapWorkItem = capWork
            queue.asyncAfter(deadline: .now() + snapshotMax, execute: capWork)
        }
        if !st.buffer.isEmpty, st.snapshotSettleWorkItem == nil {
            let settleWork = DispatchWorkItem { [weak self] in
                self?.closeSnapshot(key: key)
            }
            st.snapshotSettleWorkItem = settleWork
            queue.asyncAfter(deadline: .now() + snapshotSettleMax, execute: settleWork)
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
        st.snapshotSettleWorkItem?.cancel()
        st.snapshotSettleWorkItem = nil
        st.phase = .live

        let chunk = st.buffer
        st.buffer = Data()
        st.lastFlush = now()
        streams[key] = st

        emit(VTEvent(kind: .snapshot, paneSessionKey: key, payload: chunk,
                     cols: st.cols, rows: st.rows))
    }

    private func flushLive(key: String) {
        guard var st = streams[key], st.phase == .live, !st.buffer.isEmpty else { return }
        st.flushWorkItem?.cancel()
        st.flushWorkItem = nil
        let chunk = st.buffer
        st.buffer = Data()
        st.lastFlush = now()
        streams[key] = st
        emit(VTEvent(kind: .data, paneSessionKey: key, payload: chunk))
    }

    /// Raw bytes to every watcher. Encoding belongs to the gateway, which is the
    /// only layer that knows what a given client negotiated.
    private func emit(_ event: VTEvent) {
        for observer in observers.values {
            observer(event)
        }
    }

    private func tearDown(key: String, reason: String) {
        guard let st = streams.removeValue(forKey: key) else { return }
        st.flushWorkItem?.cancel()
        st.snapshotIdleWorkItem?.cancel()
        st.snapshotCapWorkItem?.cancel()
        st.snapshotSettleWorkItem?.cancel()
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
