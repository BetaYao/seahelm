import Foundation

/// Single source of truth for the session daemon: seahelmd, built from
/// `seahelmd/` and shipped in Contents/Resources/bin/seahelmd. $PATH is
/// consulted only in dev builds that never embedded it.
///
/// One daemon per pane session owns the PTY and keeps its screen in
/// libghostty-vt, so the app can quit and come back without taking the agents
/// with it. Its verbs are `attach`, `new`, `run`, `send`, `history`, `kill`
/// and `list`. See seahelmd/README.md.
enum SeahelmdLocator {
    /// Pure resolution: bundled path if present, else whatever the PATH lookup finds.
    static func resolve(bundledPath: String?, pathLookup: () -> String?) -> String? {
        bundledPath ?? pathLookup()
    }

    /// Absolute path to seahelmd, or nil if genuinely absent.
    static func path() -> String? {
        resolve(bundledPath: bundledResourcePath(),
                pathLookup: { ProcessRunner.commandPath("seahelmd") })
    }

    /// A token safe to hand to `/usr/bin/env` or a shell: the absolute bundled
    /// path when available, otherwise the literal "seahelmd" (PATH-resolved downstream).
    static func executable() -> String { path() ?? "seahelmd" }

    static var isAvailable: Bool { path() != nil }

    /// Runtime backend resolution. The daemon is the only persistent backend;
    /// fall back to a plain local shell when it is absent or answers `version`
    /// with something else. `warning` is non-nil only in that last (rare) case,
    /// so the UI can surface why persistence was disabled.
    static func resolveBackend() -> (backend: String, warning: String?) {
        guard isAvailable else { return ("local", nil) }
        let version = ProcessRunner.output([executable(), "version"]) ?? ""
        if isSupportedVersion(version) { return ("seahelmd", nil) }
        return ("local", "Bundled seahelmd answered an unexpected version (\(version)).")
    }

    /// `seahelmd version` prints `seahelmd <semver>`. Every release so far
    /// speaks the verbs the app uses.
    static func isSupportedVersion(_ rawVersion: String) -> Bool {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("seahelmd ")
            && trimmed.range(of: #"^seahelmd v?\d+\.\d+\.\d+"#, options: .regularExpression) != nil
    }

    /// Where seahelmd keeps one socket per session. Short on purpose: a unix
    /// socket path holds ~104 bytes and session names run long.
    static func socketDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["SEAHELMD_DIR"] ?? "/tmp/seahelmd-\(getuid())"
    }

    /// Every session's `list` row, or nil when the daemon could not be asked.
    static func listOutput() -> String? {
        ProcessRunner.output([executable(), "list"])
    }

    /// Environment a session is started with: the palette this run latched,
    /// which the daemon answers OSC 10/11/12 with while no pane is attached —
    /// so an agent started before its pane still reads the real colours.
    static func sessionEnvironment() -> [String] {
        ["SEAHELMD_FACTS=\(facts(dark: GhosttyBridge.terminalIsDark))"]
    }

    /// The bundled Catppuccin Mocha / Latte the surfaces are themed with.
    static func facts(dark: Bool) -> String {
        dark ? "fg=cdd6f4 bg=1e1e2e cursor=f5e0dc dark=1" : "fg=4c4f69 bg=eff1f5 cursor=dc8a78 dark=0"
    }

    /// Path to the embedded binary if it exists and is executable.
    private static func bundledResourcePath() -> String? {
        guard let url = Bundle.main.url(forResource: "seahelmd", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }
}
