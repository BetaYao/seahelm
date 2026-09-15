import Foundation

/// Tracks removable-volume roots that have gone unresponsive.
///
/// An abrupt disconnect often leaves the mount in place but wedged: every
/// `stat()` / `realpath()` against it blocks in the kernel forever. Callers that
/// would otherwise touch those paths on the main thread (path compares, card
/// sort keys) consult this fence first and fall back to string identity.
enum VolumeFence {
    private static let lock = NSLock()
    private static var fencedRoots = Set<String>()

    /// `/Volumes/Name` for a path under a mounted volume, else nil (boot volume
    /// and anything else we never fence through this helper).
    static func volumeRoot(for path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix("/Volumes/") else { return nil }
        let rest = standardized.dropFirst("/Volumes/".count)
        guard let slash = rest.firstIndex(of: "/") else {
            return rest.isEmpty ? nil : standardized
        }
        return "/Volumes/" + rest[..<slash]
    }

    static func fence(_ root: String) {
        lock.lock()
        fencedRoots.insert(root)
        lock.unlock()
    }

    static func unfence(_ root: String) {
        lock.lock()
        fencedRoots.remove(root)
        lock.unlock()
    }

    static func isFenced(_ path: String) -> Bool {
        guard let root = volumeRoot(for: path) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return fencedRoots.contains(root)
    }

    static var fencedVolumeRoots: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return fencedRoots
    }

    static func resetForTesting() {
        lock.lock()
        fencedRoots.removeAll()
        lock.unlock()
    }
}
