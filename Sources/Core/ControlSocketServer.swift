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
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            // Process complete lines.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !lineData.isEmpty else { continue }
                let response = respond(to: lineData)
                _ = response.withCString { cstr in
                    write(fd, cstr, strlen(cstr))
                }
            }
        }
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
