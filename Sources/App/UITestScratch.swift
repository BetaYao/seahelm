import Foundation

/// The scratch world a UI test runs the app in, built by the app itself: the
/// test runner is sandboxed and cannot write outside its container, so it only
/// names the directory (`SEAHELM_UITEST_SCRATCH`) and points the app's home,
/// core socket and seahelmd dir into it (`UITests/Helpers/ScratchHome.swift`).
/// Here, before the config is first read, the app lays out what those paths
/// expect: a home whose config has one throwaway git repo as its only project
/// (panes run a plain shell), and the seahelmd socket dir.
///
/// Only under `-SeahelmUITesting`, and only when the home really is inside the
/// scratch directory, so this can never write into a real home.
///
/// Nothing at the end of a test ends the core and seahelmd daemons it started:
/// sessions are meant to outlive the app, and `XCUIApplication.terminate()`
/// kills it without its terminate handler. `run_ui_tests.sh` sweeps them after
/// the run, but a bare `xcodebuild test` or Xcode's ⌘U never runs that. So each
/// launch also sweeps the scratch directories earlier launches left
/// (`sweepStale`): whatever way the tests are run, leftovers last only until
/// the next test starts.
enum UITestScratch {
    /// Scratch directories younger than this may belong to a test still
    /// running (another suite at once); they are left alone.
    static let staleAfter: TimeInterval = 30 * 60

    static func prepareIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment,
                               arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("-SeahelmUITesting"),
              let root = environment["SEAHELM_UITEST_SCRATCH"], !root.isEmpty,
              let home = environment["CFFIXED_USER_HOME"], home.hasPrefix(root + "/") else { return }
        do {
            try prepare(root: URL(fileURLWithPath: root), home: URL(fileURLWithPath: home))
        } catch {
            NSLog("[UITestScratch] could not prepare \(root): \(error)")
        }
        // Off the launch path: lsof over a directory of sockets takes a moment.
        DispatchQueue.global(qos: .utility).async { sweepStale(keeping: root) }
    }

    /// End what earlier test launches left in their scratch directories, and
    /// remove them: every `/tmp/shui-*` but `keeping`, older than `staleAfter`.
    static func sweepStale(keeping own: String, in tmp: String = "/tmp", now: Date = Date()) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: tmp)) ?? []
        var dirs: [(path: String, created: Date, owner: UInt32)] = []
        for name in entries {
            let path = (tmp as NSString).appendingPathComponent(name)
            guard let a = try? fm.attributesOfItem(atPath: path),
                  a[.type] as? FileAttributeType == .typeDirectory,
                  let created = a[.creationDate] as? Date,
                  let owner = (a[.ownerAccountID] as? NSNumber)?.uint32Value else { continue }
            dirs.append((path, created, owner))
        }
        for dir in staleScratch(dirs, keeping: own, user: getuid(), now: now) {
            let pids = holders(of: dir).filter { $0 != getpid() }
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty { Thread.sleep(forTimeInterval: 0.5) }
            do { try fm.removeItem(atPath: dir) } catch { NSLog("[UITestScratch] could not remove \(dir): \(error)") }
            NSLog("[UITestScratch] swept \(dir) (\(pids.count) processes)")
        }
    }

    /// Which of `dirs` are another launch's leftovers: named `shui-…` (what
    /// `ScratchHome` makes, nothing else), real directories this user owns,
    /// not this launch's, and old enough not to be a test still running.
    static func staleScratch(_ dirs: [(path: String, created: Date, owner: UInt32)],
                             keeping own: String, user: uid_t, now: Date) -> [String] {
        let ownPath = (own as NSString).standardizingPath
        return dirs.filter { d in
            let name = (d.path as NSString).lastPathComponent
            return name.hasPrefix("shui-") && name.count > 5
                && name.dropFirst(5).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                && (d.path as NSString).standardizingPath != ownPath
                && d.owner == user
                && now.timeIntervalSince(d.created) >= staleAfter
        }.map(\.path)
    }

    /// The processes with a file open under `dir`: its core, its seahelmd
    /// daemons and the shells they hold.
    private static func holders(of dir: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-t", "+D", dir]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }).sorted()
    }

    static func prepare(root: URL, home: URL) throws {
        let fm = FileManager.default
        let configDir = home.appendingPathComponent(".config/seahelm")
        let config = configDir.appendingPathComponent("config.json")
        guard !fm.fileExists(atPath: config.path) else { return }
        let repo = root.appendingPathComponent("repo")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("# scratch\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        for args in [["init", "-q", "-b", "main"], ["add", "."],
                     ["-c", "user.name=ui", "-c", "user.email=ui@example.invalid", "commit", "-q", "-m", "init"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        let json: [String: Any] = [
            "workspace_paths": [repo.path],
            "onboarding_completed": true,
            "default_agent": "shellCommand",
            "autopilot_enabled": false,
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: config)
    }
}
