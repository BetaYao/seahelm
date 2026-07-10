import Foundation

/// Single source of truth for the zmx executable location. The bundled copy
/// (shipped in Contents/Resources/bin/zmx) always wins; $PATH is consulted only
/// in dev builds that never fetched/embedded the binary.
///
/// This is also the seam a future in-house persistence daemon would replace:
/// it is the one place that knows *which* executable provides session persistence.
enum ZmxLocator {
    /// Pure resolution: bundled path if present, else whatever the PATH lookup finds.
    static func resolve(bundledPath: String?, pathLookup: () -> String?) -> String? {
        bundledPath ?? pathLookup()
    }

    /// Absolute path to the zmx binary, or nil if genuinely absent.
    static func path() -> String? {
        resolve(bundledPath: bundledResourcePath(),
                pathLookup: { ProcessRunner.commandPath("zmx") })
    }

    /// A token safe to hand to `/usr/bin/env` or a shell: the absolute bundled
    /// path when available, otherwise the literal "zmx" (PATH-resolved downstream).
    static func executable() -> String { path() ?? "zmx" }

    static var isAvailable: Bool { path() != nil }
    static var isBundled: Bool { bundledResourcePath() != nil }

    /// Runtime backend resolution. zmx is the only persistent backend; fall back
    /// to a plain local shell when zmx is absent or reports an unexpectedly
    /// unsupported version. `warning` is non-nil only in that last (rare) case,
    /// so the UI can surface why persistence was disabled.
    static func resolveBackend() -> (backend: String, warning: String?) {
        guard isAvailable else { return ("local", nil) }
        let version = ProcessRunner.output([executable(), "version"]) ?? ""
        if isSupportedVersion(version) { return ("zmx", nil) }
        return ("local", "Bundled zmx version is unexpectedly unsupported (\(version)).")
    }

    /// zmx must be at least 0.4.2 for the `zmx run` session semantics seahelm
    /// relies on. Accepts a raw `zmx version` line and extracts the first semver.
    static func isSupportedVersion(_ rawVersion: String) -> Bool {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let semver = trimmed
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first { token in
                token.contains(".") && token.range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) != nil
            }
            ?? trimmed

        let normalized = semver.hasPrefix("v") ? String(semver.dropFirst()) : semver
        let parts = normalized
            .split(separator: ".")
            .prefix(3)
            .compactMap { Int($0.filter(\.isNumber)) }

        guard parts.count == 3 else { return false }
        let major = parts[0]
        let minor = parts[1]
        let patch = parts[2]

        if major > 0 { return true }
        if minor > 4 { return true }
        if minor < 4 { return false }
        return patch >= 2
    }

    /// Path to the embedded binary if it exists and is executable.
    private static func bundledResourcePath() -> String? {
        guard let url = Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }
}
