import Foundation

/// Installs `~/.local/bin/seahelm`, the command line agents (and people) use
/// from inside a pane: `seahelm pane run <id> npm test`, `seahelm pane split`,
/// `seahelm wait agent-status …`. It is a Rust program (`seahelmd/crates/cli`)
/// bundled beside seahelmd as Contents/Resources/bin/seahelm, copied into
/// place on launch whenever the bundled one differs; it replaced a Python
/// script that used to be written there.
enum SeahelmCliInstaller {
    /// The bundled program, else `$SEAHELM_CLI_BIN` (tests, dev builds).
    static var bundled: URL? {
        if let env = ProcessInfo.processInfo.environment["SEAHELM_CLI_BIN"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        guard let url = Bundle.main.url(forResource: "seahelm", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    @discardableResult
    static func ensureInstalled() -> Bool {
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        return ensureInstalled(binDirectory: bin, from: bundled)
    }

    /// Copy `source` to `<binDirectory>/seahelm` unless the same bytes are
    /// already there. True when it wrote.
    @discardableResult
    static func ensureInstalled(binDirectory: URL, from source: URL?) -> Bool {
        guard let source, let desired = try? Data(contentsOf: source) else {
            NSLog("[SeahelmCliInstaller] no bundled seahelm CLI")
            return false
        }
        let target = binDirectory.appendingPathComponent("seahelm")
        if let existing = try? Data(contentsOf: target), existing == desired { return false }
        do {
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            // Write beside it and rename: a CLI mid-run keeps its inode.
            let staged = binDirectory.appendingPathComponent(".seahelm.new")
            try desired.write(to: staged, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: target)
            }
            return true
        } catch {
            NSLog("[SeahelmCliInstaller] Failed to install: \(error)")
            return false
        }
    }
}
