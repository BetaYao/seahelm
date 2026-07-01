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

    /// Path to the embedded binary if it exists and is executable.
    private static func bundledResourcePath() -> String? {
        guard let url = Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "bin"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }
}
