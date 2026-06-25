import Foundation

struct WorkspaceTab {
    let repoPath: String
    var displayName: String
    var worktrees: [WorktreeInfo]

    init(repoPath: String, worktrees: [WorktreeInfo]) {
        self.repoPath = repoPath
        self.displayName = URL(fileURLWithPath: repoPath).lastPathComponent
        self.worktrees = worktrees
    }
}

class WorkspaceManager {
    private(set) var tabs: [WorkspaceTab] = []

    func addTab(repoPath: String, worktrees: [WorktreeInfo]) -> Int {
        // Don't add duplicates
        if let existing = tabs.firstIndex(where: { $0.repoPath == repoPath }) {
            return existing
        }
        let tab = WorkspaceTab(repoPath: repoPath, worktrees: worktrees)
        tabs.append(tab)
        disambiguateNames()
        return tabs.count - 1
    }

    func removeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs.remove(at: index)
        disambiguateNames()
    }

    func tab(at index: Int) -> WorkspaceTab? {
        guard index >= 0, index < tabs.count else { return nil }
        return tabs[index]
    }

    func updateWorktrees(at index: Int, worktrees: [WorktreeInfo]) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].worktrees = worktrees
    }

    /// Add parent dir to display name when multiple tabs have the same name
    private func disambiguateNames() {
        var nameCounts: [String: Int] = [:]
        for tab in tabs {
            let name = URL(fileURLWithPath: tab.repoPath).lastPathComponent
            nameCounts[name, default: 0] += 1
        }
        for i in tabs.indices {
            let name = URL(fileURLWithPath: tabs[i].repoPath).lastPathComponent
            if nameCounts[name, default: 0] > 1 {
                let parent = URL(fileURLWithPath: tabs[i].repoPath).deletingLastPathComponent().lastPathComponent
                tabs[i].displayName = "\(parent)/\(name)"
            } else {
                tabs[i].displayName = name
            }
        }
    }
}
