import Foundation

struct PortPrecheck: Equatable {
    let hasUnmergedCommits: Bool
    let hasUnpushedCommits: Bool
    let hasUncommittedChanges: Bool
    var hasWarnings: Bool { hasUnmergedCommits || hasUnpushedCommits || hasUncommittedChanges }
}

enum ReturnToPort {
    static func warningSummary(_ p: PortPrecheck) -> String {
        guard p.hasWarnings else { return "No risk, safe to dock" }
        var parts: [String] = []
        if p.hasUnmergedCommits { parts.append("unmerged commits") }
        if p.hasUnpushedCommits { parts.append("unpushed commits") }
        if p.hasUncommittedChanges { parts.append("uncommitted changes") }
        return "⚠ " + parts.joined(separator: ";")
    }
}
