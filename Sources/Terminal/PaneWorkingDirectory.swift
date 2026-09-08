import Darwin
import Foundation

/// Where a new pane opens.
///
/// A split inherits the directory the pane it came from is *in*. The worktree
/// root — the old answer — is only that directory until someone cds, and then
/// every split lands somewhere the user has to leave again (issue #27). This is
/// also what every other terminal does, so it is the behaviour people arrive
/// with.
///
/// The pane's own worktree is unchanged by any of this: a pane is filed under
/// the worktree it was split from, wherever its shell happens to be standing.
enum PaneWorkingDirectory {
    /// The ladder, most authoritative first. Pure — `exists` is injected so the
    /// order can be tested without a filesystem.
    ///
    /// The kernel outranks OSC 7 because it cannot be stale: `pwd` is whatever
    /// the shell last chose to report, and a shell that never reports (bash with
    /// no hook, anything inside a multiplexer that swallows the sequence)
    /// reports nothing at all. Both outrank the directory the pane was *created*
    /// in, which is the thing being fixed.
    static func choose(probed: String?, oscPwd: String?, initial: String?, worktreePath: String,
                       exists: (String) -> Bool = Self.directoryExists) -> String {
        for candidate in [probed, oscPwd, initial] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, exists(trimmed) { return trimmed }
        }
        return worktreePath
    }

    /// Everything the ladder needs about a live pane.
    static func resolve(station: Station?, worktreePath: String) -> String {
        choose(probed: station?.paneSessionKey.flatMap(probeSessionCwd),
               oscPwd: station?.pwd,
               initial: station?.initialWorkingDirectory,
               worktreePath: worktreePath)
    }

    /// The working directory of a zmx session's shell — the one `pwd` would
    /// print in that pane.
    ///
    /// Costs one `zmx list` (a few milliseconds) and one syscall, paid once per
    /// split rather than on the status poll: it is the only moment anyone needs
    /// the answer, and reading it per pane per cycle would be work nothing looks
    /// at.
    static func probeSessionCwd(paneSessionKey: String) -> String? {
        guard !paneSessionKey.isEmpty,
              let listing = ProcessRunner.output([ZmxLocator.executable(), "list"]),
              let pid = ProcessProbe.sessionPid(paneSessionKey: paneSessionKey,
                                                zmxListOutput: listing) else { return nil }
        return cwd(ofPid: pid)
    }

    /// A process's current directory, straight from the kernel. Nil when the
    /// process is gone or refuses to say — a hardened binary, another user's.
    static func cwd(ofPid pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard read == Int32(size) else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
