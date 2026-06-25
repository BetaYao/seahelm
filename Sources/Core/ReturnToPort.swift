import Foundation

struct PortPrecheck: Equatable {
    let hasUnmergedCommits: Bool
    let hasUnpushedCommits: Bool
    let hasUncommittedChanges: Bool
    var hasWarnings: Bool { hasUnmergedCommits || hasUnpushedCommits || hasUncommittedChanges }
}

enum ReturnToPort {
    static func warningSummary(_ p: PortPrecheck) -> String {
        guard p.hasWarnings else { return "无风险,可安全入坞" }
        var parts: [String] = []
        if p.hasUnmergedCommits { parts.append("有未 merge 的提交") }
        if p.hasUnpushedCommits { parts.append("有未 push 的提交") }
        if p.hasUncommittedChanges { parts.append("有未提交的改动") }
        return "⚠ " + parts.joined(separator: ";")
    }
}
