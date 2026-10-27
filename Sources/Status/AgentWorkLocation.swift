import Foundation

/// Where an agent is working, which is not always its hook `cwd`. Claude Code
/// puts the shell back in the project directory after any command that leaves
/// it, so an agent working in a sibling worktree (`../repo-feature`) reports
/// the main checkout as its cwd on every event and spells the move out in each
/// tool call instead: `cd <worktree> && …`, or an absolute path to edit.
enum AgentWorkLocation {
    /// Tools whose input names a file the agent is changing. Reads are left
    /// out: looking at another worktree is a visit, not working there.
    private static let fileTools: [String: String] = [
        "Edit": "file_path", "MultiEdit": "file_path", "Write": "file_path",
        "NotebookEdit": "notebook_path",
    ]

    /// What a tool call says about where the agent is working.
    enum Signal: Equatable {
        /// The call works in this directory (a file tool's parent directory).
        case directory(String)
        /// A shell command with no leading `cd`: it runs in the hook cwd.
        case cwd
    }

    /// Nil when the event says nothing about place — not a tool start, or a
    /// tool (Read, Grep, …) whose input names no place it works in. `cwd`
    /// resolves a relative `cd`.
    static func signal(event: WebhookEventType, data: [String: Any]?, cwd: String) -> Signal? {
        guard event == .toolUseStart,
              let tool = data?["tool_name"] as? String,
              let input = data?["tool_input"] as? [String: Any] else { return nil }
        if tool == "Bash", let command = input["command"] as? String {
            return leadingCd(command, cwd: cwd).map(Signal.directory) ?? .cwd
        }
        if let key = fileTools[tool], let path = input[key] as? String, path.hasPrefix("/") {
            return .directory((path as NSString).deletingLastPathComponent)
        }
        return nil
    }

    /// The directory a command `cd`s into before doing anything else:
    /// `cd <dir> && …`, `cd <dir>; …`, or a bare `cd <dir>`. Quoted paths and
    /// `~` are understood; anything fancier (`cd $(…)`, `cd -`) is nil.
    static func leadingCd(_ command: String, cwd: String) -> String? {
        let pattern = #"^\s*cd\s+(?:"([^"$`]+)"|'([^']+)'|([^\s;&|"'$`()]+))\s*(?:&&|;|\n|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else {
            return nil
        }
        let raw = (1...3).lazy
            .compactMap { Range(match.range(at: $0), in: command).map { String(command[$0]) } }
            .first
        guard var dir = raw, dir != "-" else { return nil }
        if dir == "~" || dir.hasPrefix("~/") {
            dir = NSHomeDirectory() + dir.dropFirst()
        } else if !dir.hasPrefix("/") {
            dir = (cwd as NSString).appendingPathComponent(dir)
        }
        return (dir as NSString).standardizingPath
    }

    /// The worktree a tool call creates, when it is one: `git worktree add
    /// [options] <path> …` anywhere in a shell command (a `cd` or `git -C`
    /// before it resolves a relative path), or Claude's EnterWorktree with a
    /// name (`<cwd>/.claude/worktrees/<name>`). Not canonicalized: the
    /// directory does not exist yet when the tool starts.
    static func createdWorktree(event: WebhookEventType, data: [String: Any]?, cwd: String) -> String? {
        guard event == .toolUseStart,
              let tool = data?["tool_name"] as? String,
              let input = data?["tool_input"] as? [String: Any] else { return nil }
        if tool == "EnterWorktree", let name = input["name"] as? String, !name.isEmpty, !name.contains("/") {
            return (cwd as NSString).appendingPathComponent(".claude/worktrees/\(name)")
        }
        guard tool == "Bash", let command = input["command"] as? String else { return nil }
        var dir = cwd
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";&|\n")) {
            var words = shellWords(segment)
            if words.first == "cd", words.count == 2 {
                dir = resolve(words[1], against: dir)
                continue
            }
            guard words.first == "git" else { continue }
            words.removeFirst()
            var base = dir
            while words.first == "-C", words.count > 1 {
                base = resolve(words[1], against: base)
                words.removeFirst(2)
            }
            guard words.count > 2, words[0] == "worktree", words[1] == "add" else { continue }
            var args = words.dropFirst(2)[...]
            while let arg = args.first, arg.hasPrefix("-") {
                args.removeFirst()
                if ["-b", "-B", "--reason"].contains(arg) { args = args.dropFirst() }
            }
            if let path = args.first { return resolve(path, against: base) }
        }
        return nil
    }

    private static func resolve(_ path: String, against base: String) -> String {
        var dir = path
        if dir == "~" || dir.hasPrefix("~/") {
            dir = NSHomeDirectory() + dir.dropFirst()
        } else if !dir.hasPrefix("/") {
            dir = (base as NSString).appendingPathComponent(dir)
        }
        return (dir as NSString).standardizingPath
    }

    /// Whitespace-split words, with single- and double-quoted runs kept whole.
    private static func shellWords(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #""([^"]*)"|'([^']*)'|(\S+)"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1...3).lazy.compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }.first
        }
    }
}
