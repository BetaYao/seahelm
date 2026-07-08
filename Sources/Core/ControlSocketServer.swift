import Foundation

/// Unix-domain-socket server for the control API. Newline-delimited JSON,
/// request/response per line (subscriptions come in a later phase). Each
/// connection is handled on its own thread with a blocking read loop; the
/// connection count is small (agents + tooling), so this stays simple.
///
/// The socket lives at ~/.config/seahelm/seahelm.sock with 0600 permissions —
/// filesystem-scoped to the user, unlike the TCP webhook which any local
/// process can reach.
final class ControlSocketServer {
    private let router: ControlRouter
    private let path: String
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "seahelm.control-socket.accept")

    static func defaultSocketPath() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("seahelm.sock").path
    }

    init(router: ControlRouter, path: String = ControlSocketServer.defaultSocketPath()) {
        self.router = router
        self.path = path
    }

    var socketPath: String { path }

    func start() {
        guard listenFD < 0 else { return }
        // sun_path is bounded (~104 bytes); refuse rather than truncate.
        guard path.utf8.count < 104 else {
            NSLog("[ControlSocket] path too long: \(path)"); return
        }
        unlink(path)  // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("[ControlSocket] socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            path.withCString { src in strcpy(dst, src) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else {
            NSLog("[ControlSocket] bind() failed: \(errno)"); close(fd); return
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            NSLog("[ControlSocket] listen() failed: \(errno)"); close(fd); return
        }

        listenFD = fd
        running = true
        NSLog("[ControlSocket] listening at \(path)")
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if running { usleep(10_000) }
                continue
            }
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
