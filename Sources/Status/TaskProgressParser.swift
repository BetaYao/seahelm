import Foundation

/// Parses task/todo progress from terminal viewport text.
/// Supports emoji-based (Claude Code) and bracket-based (Claude Code, Codex, OpenCode) formats.
struct TaskProgressParser {

    struct Result {
        let totalTasks: Int
        let completedTasks: Int
        let currentTask: String?
    }

    // MARK: - Compiled regex patterns (created once)

    /// Emoji-based: ✅ Task description / 🔧 Task description / ⬜ Task description
    private static let emojiPattern: NSRegularExpression = {
        // Match lines starting with task emoji followed by text
        try! NSRegularExpression(
            pattern: #"^\s*([✅☑🔧🔨⏳🔄⬜☐⏹❌])\s+(.+)$"#,
            options: .anchorsMatchLines
        )
    }()

    /// Bracket-based: [completed] Task / [in_progress] Task / [pending] Task
    /// Also handles: 1. [completed] Task, [x] Task, [ ] Task, [~] Task
    private static let bracketPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^\s*(?:\d+\.\s*)?\[(completed|done|x|in_progress|current|~|pending|todo| )\]\s+(.+)$"#,
            options: [.anchorsMatchLines, .caseInsensitive]
        )
    }()

    // MARK: - Emoji classification

    private static let completedEmoji: Set<Character> = ["✅", "☑"]
    private static let inProgressEmoji: Set<Character> = ["🔧", "🔨", "⏳", "🔄"]
    private static let pendingEmoji: Set<Character> = ["⬜", "☐", "⏹", "❌"]

    // MARK: - Bracket classification

    private static let completedBrackets: Set<String> = ["completed", "done", "x"]
    private static let inProgressBrackets: Set<String> = ["in_progress", "current", "~"]
    private static let pendingBrackets: Set<String> = ["pending", "todo", " "]

    // MARK: - Public API

    /// Parse task progress from viewport text. Returns nil if no task list found (< 2 task lines).
    static func parse(content: String, agentType: AgentType) -> Result? {
        guard !content.isEmpty else { return nil }

        var completed = 0
        var inProgress = 0
        var pending = 0
        var currentTask: String?

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        // Try emoji-based patterns
        let emojiMatches = emojiPattern.matches(in: content, range: fullRange)
        for match in emojiMatches {
            guard match.numberOfRanges >= 3 else { continue }
            let emojiRange = match.range(at: 1)
            let descRange = match.range(at: 2)
            let emoji = nsContent.substring(with: emojiRange)

            guard let firstChar = emoji.first else { continue }
            let description = nsContent.substring(with: descRange).trimmingCharacters(in: .whitespaces)

            if completedEmoji.contains(firstChar) {
                completed += 1
            } else if inProgressEmoji.contains(firstChar) {
                inProgress += 1
                if currentTask == nil { currentTask = description }
            } else if pendingEmoji.contains(firstChar) {
                pending += 1
            }
        }

        // Try bracket-based patterns
        let bracketMatches = bracketPattern.matches(in: content, range: fullRange)
        for match in bracketMatches {
            guard match.numberOfRanges >= 3 else { continue }
            let statusRange = match.range(at: 1)
            let descRange = match.range(at: 2)
            let status = nsContent.substring(with: statusRange).lowercased()
            let description = nsContent.substring(with: descRange).trimmingCharacters(in: .whitespaces)

            if completedBrackets.contains(status) {
                completed += 1
            } else if inProgressBrackets.contains(status) {
                inProgress += 1
                if currentTask == nil { currentTask = description }
            } else if pendingBrackets.contains(status) {
                pending += 1
            }
        }

        let total = completed + inProgress + pending
        guard total >= 2 else { return nil }

        return Result(
            totalTasks: total,
            completedTasks: completed,
            currentTask: currentTask
        )
    }
}
