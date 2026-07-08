import Foundation

/// Timeout-guarded filesystem existence checks.
///
/// `FileManager.fileExists(atPath:)` is a `stat()` under the hood, and a `stat()`
/// against a stale or unresponsive mount — e.g. a removable volume that was
/// ejected and remounted while the app was running — can block in the kernel
/// indefinitely. Running the probe off-thread and bounding the wait keeps callers
/// (especially the main thread during launch state-restore) responsive.
///
/// On timeout we treat the path as **present**, never absent. Callers that prune
/// config on absence must not destroy a user's saved workspaces just because the
/// drive they live on is temporarily unreachable.
enum PathProbe {
    /// Bounded `fileExists`. Returns the real result if the `stat()` completes
    /// within `timeout`, otherwise `true` ("assume present").
    static func exists(_ path: String, timeout: TimeInterval = 2) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        // Boxed so the (possibly abandoned) worker never races a stack slot the
        // caller has already returned from.
        final class Box { var value = true }
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            let exists = FileManager.default.fileExists(atPath: path)
            box.value = exists
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return true
        }
        return box.value
    }

    /// Probes many paths concurrently and returns the subset that **definitively
    /// does not exist**. Paths whose `stat()` did not return within `timeout`
    /// (stale mount) are treated as present and omitted. Total wall-clock is
    /// bounded by `timeout` regardless of how many paths are probed.
    static func missingPaths(from paths: [String], timeout: TimeInterval = 2) -> Set<String> {
        let unique = Set(paths)
        guard !unique.isEmpty else { return [] }
        var missing = Set<String>()
        let lock = NSLock()
        let group = DispatchGroup()
        for path in unique {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let exists = FileManager.default.fileExists(atPath: path)
                if !exists {
                    lock.lock()
                    missing.insert(path)
                    lock.unlock()
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return missing
    }
}
