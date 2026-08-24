import Foundation

/// Unix-domain-socket server for the control API. Newline-delimited JSON,
/// request/response per line (subscriptions come in a later phase). Each
/// connection is handled on its own thread with a blocking read loop; the
/// connection count is small (agents + tooling), so this stays simple.
///
/// The socket lives at ~/.config/seahelm/seahelm.sock with 0600 permissions —
/// filesystem-scoped to the user, unlike the TCP webhook which any local
/// process can reach.

/// What the control channel is doing right now.
///
/// `standby` is the one state the app cannot resolve on its own: another live
/// instance owns the socket path, and stealing it back would only strand that
/// instance in turn — two apps trading `unlink()` forever. Everything else is
/// either healthy or self-healing, so `standby` is what the island surfaces.
enum ControlSocketState: Equatable {
    case stopped
    case listening
    case standby
}

final class ControlSocketServer {
    private let router: ControlRouter
    private let path: String
    private var listenFD: Int32 = -1
    private var running = false
    /// (dev, ino) of the socket file we bound, so `stop()` can tell our own
    /// socket from one a newer instance rebound at the same path.
    private var boundIdentity: (dev: dev_t, ino: ino_t)?
    private let acceptQueue = DispatchQueue(label: "seahelm.control-socket.accept")

    /// Guards `_state` and `_generation`, both read from the accept loop and
    /// written from the health timer.
    private let stateLock = NSLock()
    private var _state: ControlSocketState = .stopped
    /// Bumped whenever we drop a listener. The accept loop owns its fd and
    /// closes it when its generation goes stale, so a rebind can never race a
    /// blocked `accept()` into the fd number its replacement just claimed.
    private var _generation = 0

    private let healthQueue = DispatchQueue(label: "seahelm.control-socket.health")
    private var healthTimer: DispatchSourceTimer?

    /// How often to confirm the socket path still names our listener. The
    /// whole hook surface dies with that path and every client fails silently
    /// (see `healthCheck()`), so an outage wants to be seconds long, not
    /// "until somebody notices the island went quiet".
    private let healthCheckInterval: TimeInterval
    static let defaultHealthCheckInterval: TimeInterval = 10
    /// Accept-loop poll slice — also the worst-case delay before a dropped
    /// listener's thread notices and exits.
    private static let acceptPollMs: Int32 = 500

    var state: ControlSocketState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private func setState(_ new: ControlSocketState) {
        stateLock.lock(); _state = new; stateLock.unlock()
    }

    private func bumpGeneration() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        _generation += 1
        return _generation
    }

    private func currentGeneration() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _generation
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _generation == generation
    }

    static func defaultSocketPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("seahelm.sock").path
    }

    init(router: ControlRouter,
         path: String = ControlSocketServer.defaultSocketPath(),
         healthCheckInterval: TimeInterval = ControlSocketServer.defaultHealthCheckInterval) {
        self.router = router
        self.path = path
        self.healthCheckInterval = healthCheckInterval
    }

    var socketPath: String { path }

    func start() {
        // sun_path is bounded (~104 bytes); refuse rather than truncate. This
        // is the one failure with no retry — a too-long path never gets shorter.
        guard path.utf8.count < 104 else {
            NSLog("[ControlSocket] path too long: \(path)"); return
        }
        // Every mutation of the listener runs on healthQueue so the periodic
        // check can never interleave with start()/stop().
        healthQueue.sync { attemptBind() }
        startHealthChecks()
    }

    func stop() {
        healthTimer?.cancel()
        healthTimer = nil
        healthQueue.sync {
            dropListener()
            // Only remove the socket file if it is still the one we bound. A
            // newer instance's bind unlinks this path and rebinds its own
            // socket; a blind unlink here would delete *its* live socket,
            // leaving it bound to an fd that no client can reach (hooks then
            // fail their `[ -S ]` guard and silently drop every event).
            if let mine = boundIdentity {
                var st = stat()
                if stat(path, &st) == 0, st.st_dev == mine.dev, st.st_ino == mine.ino {
                    unlink(path)
                }
            }
            boundIdentity = nil
            setState(.stopped)
        }
    }

    // MARK: - Binding

    /// One bind attempt. Ends at `.listening` on success, `.standby` when a
    /// live instance already owns the path, `.stopped` when the OS refused us.
    /// Must run on `healthQueue`.
    private func attemptBind() {
        guard listenFD < 0 else { return }

        // Never unlink a socket someone is still listening on. This used to
        // clear the path unconditionally, which let a second instance take the
        // live app's socket without a word: the first stayed bound to an
        // unlinked inode no client could reach, and every hook fell through its
        // `[ -S ]` guard in silence. Standing down is the honest outcome —
        // stealing it back would only strand the other instance in turn.
        if Self.hasLiveListener(at: path) {
            if state != .standby {
                NSLog("[ControlSocket] \(path) belongs to another live instance — standing by")
            }
            setState(.standby)
            return
        }
        unlink(path)  // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[ControlSocket] socket() failed"); setState(.stopped); return
        }

        var addr = Self.address(for: path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else {
            NSLog("[ControlSocket] bind() failed: \(errno)"); close(fd); setState(.stopped); return
        }
        chmod(path, 0o600)
        var st = stat()
        boundIdentity = (stat(path, &st) == 0) ? (st.st_dev, st.st_ino) : nil
        guard listen(fd, 8) == 0 else {
            NSLog("[ControlSocket] listen() failed: \(errno)"); close(fd); setState(.stopped); return
        }

        listenFD = fd
        running = true
        setState(.listening)
        NSLog("[ControlSocket] listening at \(path)")
        let generation = currentGeneration()
        acceptQueue.async { [weak self] in self?.acceptLoop(fd: fd, generation: generation) }
    }

    /// Let go of the current listener without touching the filesystem: bump the
    /// generation so its thread closes the fd and exits on its own. Deliberately
    /// does not `close()` here — the fd number must stay claimed until its owner
    /// is gone, or a rebind could hand the same number to a thread still parked
    /// in `accept()`. Must run on `healthQueue`.
    private func dropListener() {
        running = false
        _ = bumpGeneration()
        listenFD = -1
    }

    /// True when something is accepting connections on `path` right now. A
    /// leftover file from a crashed instance refuses the connect, which is
    /// exactly what makes it safe to unlink.
    private static func hasLiveListener(at path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(for: path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }

    private static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            path.withCString { src in strcpy(dst, src) }
        }
        return addr
    }

    // MARK: - Health

    private func startHealthChecks() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + healthCheckInterval,
                       repeating: healthCheckInterval)
        timer.setEventHandler { [weak self] in self?.healthCheck() }
        healthTimer = timer
        timer.resume()
    }

    /// The socket file can vanish out from under a live listener: another
    /// instance's bind unlinks the path, and when *that* instance exits it takes
    /// the path with it. Our fd stays valid and the accept loop keeps spinning,
    /// but there is no longer a name for anyone to connect to — every hook fails
    /// its `[ -S ]` guard and drops the event in silence, so nothing in this
    /// process ever learns the channel died. Hence the poll.
    private func healthCheck() {
        switch state {
        case .listening:
            guard let mine = boundIdentity else { return }
            var st = stat()
            if stat(path, &st) != 0 {
                // Nobody owns the path now, so it is ours to take back.
                NSLog("[ControlSocket] socket path vanished — rebinding")
            } else if st.st_dev != mine.dev || st.st_ino != mine.ino {
                // Somebody rebound it. attemptBind() decides whether that
                // somebody is alive (stand by) or a leftover file (reclaim).
                NSLog("[ControlSocket] socket path was replaced — re-checking ownership")
            } else {
                return  // healthy: the path still names our listener
            }
            dropListener()
            boundIdentity = nil
            attemptBind()
        case .standby, .stopped:
            // The owner may have exited, or whatever refused the bind last time
            // may have cleared.
            attemptBind()
        }
    }

    private func acceptLoop(fd: Int32, generation: Int) {
        // This loop owns the fd for its whole life, including the close.
        defer { close(fd) }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while running, isCurrent(generation) {
            pfd.revents = 0
            // Poll rather than block in accept(): a dropped listener has to be
            // able to notice its generation went stale and let go of the fd.
            let ready = poll(&pfd, 1, Self.acceptPollMs)
            if ready < 0 {
                if errno != EINTR { usleep(10_000) }
                continue
            }
            guard ready > 0 else { continue }  // timeout — re-check the guards
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if running { usleep(10_000) }
                continue
            }
            guard running, isCurrent(generation) else { close(clientFD); return }
            Thread.detachNewThread { [weak self] in self?.handleConnection(clientFD) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        // Writing to a client that vanished mid-stream must not raise SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // A subscribed connection is written from two threads (this read loop's
        // responses + EventHub push callbacks), so serialize all writes.
        let writeLock = NSLock()
        func writeLine(_ s: String) {
            guard !s.isEmpty else { return }
            writeLock.lock(); defer { writeLock.unlock() }
            _ = s.withCString { write(fd, $0, strlen($0)) }
        }
        var subToken: Int?
        defer { if let t = subToken { EventHub.shared.unsubscribe(t) } }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !lineData.isEmpty else { continue }
                if handleSubscribe(lineData, writeLine: writeLine, subToken: &subToken) { continue }
                writeLine(respond(to: lineData))
            }
        }
    }

    /// If the line is an `events.subscribe`, ack it, replay any missed events,
    /// register a live subscriber, and return true. Otherwise return false so the
    /// caller handles it as a normal request/response.
    private func handleSubscribe(_ lineData: Data,
                                 writeLine: @escaping (String) -> Void,
                                 subToken: inout Int?) -> Bool {
        guard let line = String(data: lineData, encoding: .utf8),
              let req = ControlRouter.parseRequest(line),
              req.method == "events.subscribe" else { return false }

        let params = req.params
        let types = (params["types"] as? [String]).map(Set.init)
        let paneId = params["pane_id"] as? String

        writeLine(ControlRouter.encodeResponse(id: req.id,
            result: .ok(["subscribed": true, "seq": Int(EventHub.shared.currentSeq)])))

        if let after = params["events_after"] as? Int {
            for (_, event) in EventHub.shared.eventsAfter(UInt64(max(0, after)))
                where ControlRouter.eventPasses(event, types: types, paneId: paneId) {
                writeLine(ControlRouter.encodeEvent(event))
            }
        }

        if subToken == nil {
            subToken = EventHub.shared.subscribe { _, event in
                guard ControlRouter.eventPasses(event, types: types, paneId: paneId) else { return }
                writeLine(ControlRouter.encodeEvent(event))
            }
        }
        return true
    }

    private func respond(to lineData: Data) -> String {
        guard let line = String(data: lineData, encoding: .utf8) else {
            return ControlRouter.encodeParseError()
        }
        guard let req = ControlRouter.parseRequest(line) else {
            return ControlRouter.encodeParseError()
        }
        let result = router.handle(method: req.method, params: req.params)
        return ControlRouter.encodeResponse(id: req.id, result: result)
    }
}
