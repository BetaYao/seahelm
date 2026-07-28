import Foundation

/// One path under a worktree root, relative to that root (no leading slash).
struct WorktreePathEntry: Equatable {
    let relativePath: String
    /// Pre-lowercased basename for fast substring matching while typing.
    let basenameLowercased: String
    let isDirectory: Bool

    init(relativePath: String, isDirectory: Bool) {
        self.relativePath = relativePath
        self.basenameLowercased = (relativePath as NSString).lastPathComponent.lowercased()
        self.isDirectory = isDirectory
    }

    init(relativePath: String, basenameLowercased: String, isDirectory: Bool) {
        self.relativePath = relativePath
        self.basenameLowercased = basenameLowercased
        self.isDirectory = isDirectory
    }
}

/// Flat path table for Files-tab search. Enumerate once (with prune), filter in
/// memory, then rebuild a slim ancestor tree for the outline.
enum WorktreePathIndex {
    /// Soft cap on match count so short needles (e.g. "a") cannot rebuild a
    /// multi-thousand-node outline on every keystroke.
    static let defaultMatchLimit = 250

    /// Directory basenames skipped during enumeration (and always, even when
    /// showing hidden files).
    static let prunedDirectoryNames: Set<String> = [
        ".git", ".build", ".next", ".venv", ".turbo", ".cache",
        "node_modules", "Pods", "DerivedData", "build", "dist", "target",
        "__pycache__", "Carthage",
    ]

    static func shouldPruneDirectory(named name: String) -> Bool {
        prunedDirectoryNames.contains(name)
    }

    /// Walk `root` and return every file and directory entry (relative paths),
    /// honouring `showHidden` and `prunedDirectoryNames`.
    static func enumerate(root: URL, showHidden: Bool) -> [WorktreePathEntry] {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var entries: [WorktreePathEntry] = []
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDir = values?.isDirectory ?? false
            let isSymlink = values?.isSymbolicLink ?? false

            if isDir, shouldPruneDirectory(named: name) {
                enumerator.skipDescendants()
                continue
            }
            if !showHidden, name.hasPrefix(".") {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            // Don't follow symlinked directories into arbitrary trees.
            if isDir, isSymlink {
                enumerator.skipDescendants()
                continue
            }

            let full = item.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let relative = String(full.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            entries.append(WorktreePathEntry(
                relativePath: relative,
                basenameLowercased: name.lowercased(),
                isDirectory: isDir
            ))
        }
        return entries
    }

    /// Basename substring match (case-insensitive). Empty / whitespace needle → no hits
    /// (caller treats that as "not filtering"). Stops after `limit` hits.
    static func matching(
        entries: [WorktreePathEntry],
        needle: String,
        limit: Int = defaultMatchLimit
    ) -> [WorktreePathEntry] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        var hits: [WorktreePathEntry] = []
        hits.reserveCapacity(min(limit, entries.count))
        for entry in entries {
            if entry.basenameLowercased.contains(trimmed) {
                hits.append(entry)
                if hits.count >= limit { break }
            }
        }
        return hits
    }

    /// Build root-level `FileTreeNode`s whose subtrees contain only `matched` paths
    /// and the ancestor directories needed to reach them.
    static func buildFilteredTree(root: URL, matched: [WorktreePathEntry]) -> [FileTreeNode] {
        guard !matched.isEmpty else { return [] }

        var allPaths = Set<String>()
        var directoryPaths = Set<String>()

        for entry in matched {
            allPaths.insert(entry.relativePath)
            if entry.isDirectory {
                directoryPaths.insert(entry.relativePath)
            }
            // Every proper ancestor is a directory that must appear.
            var parts = entry.relativePath.split(separator: "/").map(String.init)
            while parts.count > 1 {
                parts.removeLast()
                let parent = parts.joined(separator: "/")
                allPaths.insert(parent)
                directoryPaths.insert(parent)
            }
        }

        var nodes: [String: FileTreeNode] = [:]
        nodes.reserveCapacity(allPaths.count)
        for relative in allPaths {
            let isDir = directoryPaths.contains(relative)
            let node = FileTreeNode(
                url: root.appendingPathComponent(relative),
                isDirectory: isDir
            )
            node.children = isDir ? [] : nil
            nodes[relative] = node
        }

        var roots: [FileTreeNode] = []
        for relative in allPaths {
            guard let node = nodes[relative] else { continue }
            if let slash = relative.lastIndex(of: "/") {
                let parentPath = String(relative[..<slash])
                guard let parent = nodes[parentPath] else { continue }
                parent.children?.append(node)
            } else {
                roots.append(node)
            }
        }

        func sortLevel(_ list: inout [FileTreeNode]?) {
            guard var kids = list else { return }
            kids.sort(by: Self.outlineOrder)
            for kid in kids where kid.isDirectory {
                sortLevel(&kid.children)
            }
            list = kids
        }
        for rootNode in roots where rootNode.isDirectory {
            sortLevel(&rootNode.children)
        }
        roots.sort(by: Self.outlineOrder)
        return roots
    }

    private static func outlineOrder(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
    }
}
