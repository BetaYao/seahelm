import Foundation

/// Everything the app under test touches, kept out of the user's live setup.
///
/// A UI test used to launch the app on the real `~/.config/seahelm/config.json`,
/// the live seahelm-core and the real seahelmd sessions: ⌘D in a test split a
/// pane in the user's own layout and saved it. Now each launch gets a scratch
/// directory under /tmp (short: socket paths cap near 104 bytes) holding a home
/// (`CFFIXED_USER_HOME` moves Foundation's home, `HOME` the children's), the
/// core's socket, the seahelmd socket dir, and one throwaway git repo as the
/// only project, whose panes run a plain shell.
final class ScratchHome {
    let root: URL
    var home: URL { root.appendingPathComponent("h") }
    var repo: URL { root.appendingPathComponent("repo") }
    var coreSocket: URL { root.appendingPathComponent("c.sock") }
    var seahelmdDir: URL { root.appendingPathComponent("d") }

    init() throws {
        root = URL(fileURLWithPath: "/tmp/shui-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        let configDir = home.appendingPathComponent(".config/seahelm")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: seahelmdDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("# scratch\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try git(["init", "-q", "-b", "main"])
        try git(["add", "."])
        try git(["-c", "user.name=ui", "-c", "user.email=ui@example.invalid", "commit", "-q", "-m", "init"])
        let config: [String: Any] = [
            "workspace_paths": [repo.path],
            "onboarding_completed": true,
            "default_agent": "shellCommand",
            "autopilot_enabled": false,
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: configDir.appendingPathComponent("config.json"))
    }

    var environment: [String: String] {
        [
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "SEAHELM_CORE_SOCKET": coreSocket.path,
            "SEAHELMD_DIR": seahelmdDir.path,
        ]
    }

    /// End whatever the run left behind (the scratch core, seahelmd daemons:
    /// both detach from the app) and remove the directory.
    func tearDown() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", "+D", root.path]
        let out = Pipe()
        lsof.standardOutput = out
        lsof.standardError = FileHandle.nullDevice
        if (try? lsof.run()) != nil {
            lsof.waitUntilExit()
            let me = getpid()
            let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").compactMap { Int32($0) }.filter { $0 != me }
            for pid in Set(pids) { kill(pid, SIGTERM) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func git(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "ScratchHome", code: Int(p.terminationStatus)) }
    }
}
