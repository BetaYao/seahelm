import Foundation

/// A blocking JSON-RPC call to seahelm-core (`~/.config/seahelm/core.sock`,
/// or `$SEAHELM_CORE_SOCKET`): one request, one newline-terminated reply.
/// Used where the core owns something the app only shows — First Mate when
/// `autopilot_owner` is `core`. Never call on main.
enum CoreSocketClient {
    static var path: String {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SEAHELM_CORE_SOCKET"], !path.isEmpty { return path }
        // Unit tests never reach the user's live core: a test that wants a
        // core sets SEAHELM_CORE_SOCKET to one of its own.
        if env["XCTestConfigurationFilePath"] != nil { return "/nonexistent/seahelm-core.sock" }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/core.sock").path
    }

    enum Failure: Error, Equatable {
        case unreachable
        case rpc(code: Int, message: String)
        case malformed
    }

    static func call(_ method: String, _ params: [String: Any] = [:],
                     timeout: TimeInterval = 5, path: String = CoreSocketClient.path) -> Result<[String: Any], Failure> {
        guard let fd = open(path: path, timeout: timeout) else { return .failure(.unreachable) }
        defer { close(fd) }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return .failure(.malformed) }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { return .failure(.unreachable) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !reply.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            reply.append(contentsOf: buffer[0..<n])
        }
        return parse(reply)
    }

    /// A connected socket to the core, with read and write timeouts; the
    /// caller closes it. Nil when the core is not there.
    static func open(path: String = CoreSocketClient.path, timeout: TimeInterval) -> Int32? {
        guard path.utf8.count < 104 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in path.withCString { strcpy(dst, $0) } }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    /// One reply line → its `result`, or its `error`.
    static func parse(_ reply: Data) -> Result<[String: Any], Failure> {
        let line = reply.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first ?? Data()
        guard !line.isEmpty else { return .failure(.unreachable) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
            return .failure(.malformed)
        }
        if let error = obj["error"] as? [String: Any] {
            return .failure(.rpc(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? ""))
        }
        return .success(obj["result"] as? [String: Any] ?? [:])
    }
}
