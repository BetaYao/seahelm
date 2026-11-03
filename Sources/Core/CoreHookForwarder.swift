import Foundation

/// Hands every hook payload the app receives to seahelm-core as well, while the
/// core runs beside the app in shadow mode (docs/status-core-port.md). The
/// agents' hook config keeps pointing at the app's socket; the core sees the
/// same events without anything installed for it.
///
/// Fire-and-forget on a queue of its own: no core (no socket file) is the
/// normal case and costs a `stat`; a core that does not take the line within
/// half a second loses it rather than slowing the app's hook path.
enum CoreHookForwarder {
    private static let queue = DispatchQueue(label: "seahelm.core-hook-forward", qos: .utility)

    /// `$SEAHELM_CORE_SOCKET`, else `~/.config/seahelm/core.sock`.
    static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["SEAHELM_CORE_SOCKET"], !path.isEmpty {
            return path
        }
        return NSHomeDirectory() + "/.config/seahelm/core.sock"
    }

    static func forward(_ params: [String: Any]) {
        let path = socketPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": "h", "method": "hook", "params": params]
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return }
        line.append(0x0A)
        queue.async { send(line, to: path) }
    }

    private static func send(_ data: Data, to path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { _ = strlcpy($0, path, capacity) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
