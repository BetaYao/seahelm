import Foundation

/// Spellings of a terminal token worth testing as a path. Shared by the exact
/// resolver and the worktree-wide lookup so both accept the same decorations.
enum PathToken {
    /// Characters that wrap a path in prose but are not part of it. Agent output
    /// is full of `` `src/a.ts` ``, `(src/a.ts)`, `"src/a.ts",` and CJK commas.
    static let wrappers = CharacterSet(charactersIn: "`'\"“”‘’()[]{}<>,;:.，。、：；！？*")

    /// Punctuation that ends a path even with no space after it. CJK prose runs
    /// paths together — `a.swift、b.swift。` is three tokens to a reader and one
    /// to a whitespace split — and none of these ever appear in a filename.
    static let separators = CharacterSet(charactersIn: "、，。；：！？「」『』（）【】《》〈〉…\u{3000}")

    /// Most literal first: as typed, unwrapped from punctuation, with a
    /// `:line[:col]` suffix removed (the form every agent and compiler prints),
    /// and with prose CJK letters shaved off either end — `修改了src/a.ts文件`.
    ///
    /// Extra spellings are safe to add: every one is verified against the
    /// filesystem or the worktree index before it is offered, so a bad guess
    /// costs a `stat`, not a wrong file.
    static func forms(of token: String) -> [String] {
        var forms = [token]
        func add(_ candidate: String) {
            guard !candidate.isEmpty, !forms.contains(candidate) else { return }
            forms.append(candidate)
        }

        add(token.trimmingCharacters(in: wrappers))
        for base in forms where base.contains(":") {
            add(base.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression))
        }
        for base in forms where base.contains(where: isCJKLetter) {
            add(String(base.drop(while: isCJKLetter).reversed().drop(while: isCJKLetter).reversed()))
        }
        return forms
    }

    /// A CJK letter (not punctuation): prose that can butt up against a path.
    static func isCJKLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // Kana
             0x3400...0x4DBF,   // CJK ext A
             0x4E00...0x9FFF,   // CJK unified
             0xAC00...0xD7A3,   // Hangul syllables
             0xF900...0xFAFF:   // CJK compatibility ideographs
            return true
        default:
            return false
        }
    }
}

/// Immutable snapshot of a worktree's files, keyed by basename so a bare
/// filename in terminal output can be matched back to the paths that carry it.
struct WorktreeFileIndex: Equatable {
    /// Worktree-relative paths, no leading "./".
    let relativePaths: [String]
    /// Lowercased basename → indices into `relativePaths`.
    private let byBasename: [String: [Int]]

    init(relativePaths: [String]) {
        var paths: [String] = []
        paths.reserveCapacity(relativePaths.count)
        var buckets: [String: [Int]] = [:]
        for path in relativePaths {
            let cleaned = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            guard !cleaned.isEmpty, !cleaned.hasSuffix("/") else { continue }
            let basename = (cleaned as NSString).lastPathComponent.lowercased()
            guard !basename.isEmpty else { continue }
            buckets[basename, default: []].append(paths.count)
            paths.append(cleaned)
        }
        self.relativePaths = paths
        self.byBasename = buckets
    }

    var isEmpty: Bool { relativePaths.isEmpty }

    /// Paths whose trailing components match `token`, best first.
    ///
    /// `token` may be a bare basename (`UsageSummary.swift`) or a partial path
    /// (`Usage/UsageSummary.swift`); the latter must line up on a component
    /// boundary so `Usage/x.swift` never matches `MisUsage/x.swift`.
    ///
    /// Ranking puts files under `preferring` first (the pane's own directory is
    /// the likeliest referent), then the shallowest path, then alphabetical —
    /// so the order is stable rather than filesystem-dependent.
    func matches(token: String, preferring directory: String? = nil, limit: Int = 15) -> [String] {
        for form in PathToken.forms(of: token) {
            let hits = indices(matching: form)
            guard !hits.isEmpty else { continue }
            return Array(rank(hits, preferring: directory).prefix(limit))
        }
        return []
    }

    private func indices(matching form: String) -> [Int] {
        var needle = form.hasPrefix("./") ? String(form.dropFirst(2)) : form
        if needle.hasPrefix("/") { needle = String(needle.drop(while: { $0 == "/" })) }
        guard !needle.isEmpty, !needle.hasSuffix("/") else { return [] }

        let basename = (needle as NSString).lastPathComponent.lowercased()
        guard let bucket = byBasename[basename] else { return [] }
        guard needle.contains("/") else { return bucket }

        let lowered = needle.lowercased()
        let suffix = "/" + lowered
        return bucket.filter {
            let path = relativePaths[$0].lowercased()
            return path == lowered || path.hasSuffix(suffix)
        }
    }

    private func rank(_ indices: [Int], preferring directory: String?) -> [String] {
        let prefix = directory
            .map { $0.hasSuffix("/") || $0.isEmpty ? $0 : $0 + "/" }
            .flatMap { $0.isEmpty ? nil : $0 }
        return indices.map { relativePaths[$0] }.sorted { lhs, rhs in
            if let prefix {
                let lhsNear = lhs.hasPrefix(prefix), rhsNear = rhs.hasPrefix(prefix)
                if lhsNear != rhsNear { return lhsNear }
            }
            let lhsDepth = lhs.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
            let rhsDepth = rhs.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs < rhs
        }
    }
}

/// Per-worktree cache of `WorktreeFileIndex`, built off the main thread.
///
/// Lookups never touch the disk on the caller's thread: a right-click has to
/// build its menu synchronously, and enumerating a large tree takes ~1s (a
/// 176k-file repo measured here) — long enough to freeze the click.
final class WorktreeFileIndexStore {
    static let shared = WorktreeFileIndexStore()

    /// How long a snapshot is served before a refresh is kicked off. The stale
    /// copy is still returned meanwhile — a file that appeared seconds ago is a
    /// rarer case than a menu that has to wait.
    static let staleAfter: TimeInterval = 15
    /// Worktrees kept in memory, least-recently-used evicted.
    static let maxWorktrees = 8
    /// Ceiling for the non-git fallback, which has no ignore rules to lean on.
    static let fallbackEntryLimit = 60_000

    private let queue = DispatchQueue(label: "seahelm.worktree-file-index", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [String: (index: WorktreeFileIndex, builtAt: Date)] = [:]
    private var building: Set<String> = []
    private var recency: [String] = []

    /// Overrides the listing for tests. When set, it replaces both phases.
    var listPaths: ((String) -> [String])?

    /// The cached snapshot, or nil while the first build is in flight. Always
    /// schedules a refresh when the copy is missing or stale.
    func cachedIndex(for worktreePath: String, now: Date = Date()) -> WorktreeFileIndex? {
        guard !worktreePath.isEmpty else { return nil }
        lock.lock()
        let entry = cache[worktreePath]
        if entry != nil { touch(worktreePath) }
        lock.unlock()

        if entry == nil || now.timeIntervalSince(entry!.builtAt) > Self.staleAfter {
            build(worktreePath)
        }
        return entry?.index
    }

    /// Build the index ahead of the first right-click — called when a pane takes
    /// focus, so the menu finds a warm cache instead of an empty one.
    func warm(_ worktreePath: String) {
        guard !worktreePath.isEmpty else { return }
        lock.lock()
        let entry = cache[worktreePath]
        lock.unlock()
        guard entry == nil || Date().timeIntervalSince(entry!.builtAt) > Self.staleAfter else { return }
        build(worktreePath)
    }

    /// Two phases, because they cost wildly different amounts. Listing the git
    /// index is a constant ~16ms read of one file; adding untracked files walks
    /// the working tree, which on a cold cache over an external volume measured
    /// 11s here. Publishing the tracked snapshot first means the menu is useful
    /// almost immediately and gains the new files a moment later.
    private func build(_ worktreePath: String) {
        lock.lock()
        guard !building.contains(worktreePath) else { return lock.unlock() }
        building.insert(worktreePath)
        let override = listPaths
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.building.remove(worktreePath)
                self.lock.unlock()
            }
            if let override {
                self.publish(override(worktreePath), for: worktreePath)
                return
            }
            guard let tracked = Self.gitPaths(worktreePath: worktreePath, includingUntracked: false) else {
                self.publish(Self.enumeratedPaths(worktreePath: worktreePath), for: worktreePath)
                return
            }
            self.publish(tracked, for: worktreePath)
            if let complete = Self.gitPaths(worktreePath: worktreePath, includingUntracked: true),
               complete.count != tracked.count {
                self.publish(complete, for: worktreePath)
            }
        }
    }

    private func publish(_ paths: [String], for worktreePath: String) {
        let index = WorktreeFileIndex(relativePaths: paths)
        lock.lock()
        cache[worktreePath] = (index, Date())
        touch(worktreePath)
        evictIfNeeded()
        lock.unlock()
    }

    /// Caller holds `lock`.
    private func touch(_ worktreePath: String) {
        recency.removeAll { $0 == worktreePath }
        recency.append(worktreePath)
    }

    /// Caller holds `lock`.
    private func evictIfNeeded() {
        while recency.count > Self.maxWorktrees {
            let evicted = recency.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    // MARK: - Listing

    /// Files git knows about. Its index is both far smaller and far faster than
    /// walking the tree (3k entries in 17ms versus 176k in ~1s on the same
    /// repo), and it honours .gitignore for free. `includingUntracked` adds the
    /// working-tree walk that makes it slow.
    static func gitPaths(worktreePath: String, includingUntracked: Bool) -> [String]? {
        // `--others` walks the working tree, which is the slow mode this comment
        // warns about — hence the wider deadline than a plain index read needs.
        let arguments = ["ls-files", "-z", "--cached"]
            + (includingUntracked ? ["--others", "--exclude-standard"] : [])
        guard let output = GitProcess.run(arguments, in: worktreePath, timeout: listTimeout) else {
            return nil
        }
        return output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Deadline for one `ls-files`. Generous because the untracked walk on a big
    /// repo is legitimately slow, but bounded so a wedged volume can't park the
    /// caller forever.
    private static let listTimeout: TimeInterval = 30

    /// Fallback for a directory that is not a git repo. Capped, because without
    /// ignore rules the walk can otherwise pull in an entire dependency tree.
    static func enumeratedPaths(worktreePath: String) -> [String] {
        let root = URL(fileURLWithPath: worktreePath)
        return WorktreePathIndex.enumerate(root: root, showHidden: false)
            .lazy
            .filter { !$0.isDirectory }
            .prefix(fallbackEntryLimit)
            .map(\.relativePath)
    }
}
