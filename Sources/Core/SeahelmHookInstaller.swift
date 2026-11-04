import Foundation

/// Installs `~/.local/bin/seahelm-hook`, the command hook every agent runs on
/// every lifecycle event. It is a Rust program (`seahelm-core-hooks`'
/// `seahelm-hook` binary, the same bridge as `seahelm-core hook`) bundled as
/// Contents/Resources/bin/seahelm-hook and copied into place on launch
/// whenever the bundled one differs; it replaced a `/bin/sh` + `nc -U` script.
///
/// It sends the payload to seahelm-core, the only receiver of hooks
/// (docs/app-reads-core.md), and prints the core's answer, which is only
/// ever a SessionStart's added context: the suggestion guidance, for an agent
/// running in a seahelm pane. Stop is observation-only.
enum SeahelmHookInstaller {
    /// The bundled program, else `$SEAHELM_HOOK_BIN` (tests, dev builds).
    static var bundled: URL? {
        if let env = ProcessInfo.processInfo.environment["SEAHELM_HOOK_BIN"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        guard let url = Bundle.main.url(forResource: "seahelm-hook", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Absolute path to the installed hook (used by hook config).
    static func scriptPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/seahelm-hook").path
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin, from: bundled)
    }

    @discardableResult
    static func ensureInstalled(binDirectory: URL, from source: URL?) -> Bool {
        BundledBinary.install(source, as: "seahelm-hook", in: binDirectory)
    }
}

/// Copies a program bundled under Contents/Resources/bin to a stable place
/// (`~/.local/bin`), where agents' configs can name it whatever app build is
/// running.
enum BundledBinary {
    /// Copy `source` to `<directory>/<name>` unless the same bytes are already
    /// there. True when it wrote.
    @discardableResult
    static func install(_ source: URL?, as name: String, in directory: URL) -> Bool {
        guard let source, let desired = try? Data(contentsOf: source) else {
            NSLog("[BundledBinary] no bundled \(name)")
            return false
        }
        let target = directory.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: target), existing == desired { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Write beside it and rename: a copy mid-run keeps its inode.
            let staged = directory.appendingPathComponent(".\(name).new")
            try desired.write(to: staged, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
            }
            return true
        } catch {
            NSLog("[BundledBinary] Failed to install \(name): \(error)")
            return false
        }
    }
}
