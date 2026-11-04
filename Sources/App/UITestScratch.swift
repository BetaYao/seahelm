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
/// `run_ui_tests.sh` ends what the run left there and removes it.
enum UITestScratch {
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
