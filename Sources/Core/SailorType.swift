import Foundation

enum SailorType: String, Codable, CaseIterable {
    // AI Agents
    case claudeCode
    case codex
    case openCode
    case gemini
    case cline
    case goose
    case amp
    case aider
    case cursor
    case kiro
    // Shell tasks
    case brew
    case btop
    case top
    case htop
    case docker
    case npm
    case yarn
    case make
    case cargo
    case go
    case python
    case pip
    case shellCommand   // generic fallback for any non-AI command
    case unknown

    var displayName: String {
        switch self {
        case .claudeCode:   return "Claude Code"
        case .codex:        return "Codex"
        case .openCode:     return "OpenCode"
        case .gemini:       return "Gemini"
        case .cline:        return "Cline"
        case .goose:        return "Goose"
        case .amp:          return "Amp"
        case .aider:        return "Aider"
        case .cursor:       return "Cursor"
        case .kiro:         return "Kiro"
        case .brew:         return "Homebrew"
        case .btop:         return "btop"
        case .top:          return "top"
        case .htop:         return "htop"
        case .docker:       return "Docker"
        case .npm:          return "npm"
        case .yarn:         return "Yarn"
        case .make:         return "Make"
        case .cargo:        return "Cargo"
        case .go:           return "Go"
        case .python:       return "Python"
        case .pip:          return "pip"
        case .shellCommand: return "Shell"
        case .unknown:      return "Unknown"
        }
    }

    /// CLI command that launches this agent, for auto-starting it in a new
    /// worktree terminal. Nil for non-AI / shell types.
    var launchCommand: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex:      return "codex"
        case .openCode:   return "opencode"
        case .gemini:     return "gemini"
        case .cline:      return "cline"
        case .goose:      return "goose"
        case .amp:        return "amp"
        case .aider:      return "aider"
        case .cursor:     return "cursor"
        case .kiro:       return "kiro"
        default:          return nil
        }
    }

    /// Full agent invocation including the task as the agent's initial prompt
    /// (a positional argument, e.g. `claude 'fix the bug'`). Returns nil for
    /// non-AI / shell types (those are not auto-launched). The task is
    /// shell-escaped because the result is interpreted by a POSIX shell.
    func launchCommand(withTask task: String) -> String? {
        guard let base = launchCommand else { return nil }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return "\(base) \(ShellEscape.singleQuote(trimmed))"
    }

    /// Short label for compact UI (the picker chip).
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .openCode:   return "OpenCode"
        default:          return displayName
        }
    }

    var isAIAgent: Bool {
        switch self {
        case .claudeCode, .codex, .openCode, .gemini, .cline,
             .goose, .amp, .aider, .cursor, .kiro:
            return true
        default:
            return false
        }
    }

    var isShellTask: Bool {
        !isAIAgent && self != .unknown
    }

    // MARK: - AI Agent detection from terminal content

    // Ordered by specificity to avoid false matches (e.g., "opencode" before "code")
    private static let detectionPatterns: [(pattern: String, type: SailorType)] = [
        ("opencode", .openCode),
        ("claude", .claudeCode),
        ("codex", .codex),
        ("gemini", .gemini),
        ("cline", .cline),
        ("goose", .goose),
        ("aider", .aider),
        ("cursor", .cursor),
        ("kiro", .kiro),
        ("amp ", .amp),
    ]

    /// Detect agent type from lowercased terminal content (for AI agents)
    static func detect(fromLowercased content: String) -> SailorType {
        for (pattern, type) in detectionPatterns {
            if content.contains(pattern) {
                return type
            }
        }
        return .unknown
    }

    // MARK: - Shell command detection from command line

    private static let commandMap: [String: SailorType] = [
        "brew": .brew, "btop": .btop, "top": .top, "htop": .htop,
        "docker": .docker, "npm": .npm, "npx": .npm,
        "yarn": .yarn, "make": .make, "cargo": .cargo, "go": .go,
        "python": .python, "python3": .python,
        "pip": .pip, "pip3": .pip,
    ]

    /// Detect shell task type from a command line string.
    /// Handles full paths (/usr/local/bin/brew) and env prefixes (ENV=val make).
    static func detect(fromCommand command: String) -> SailorType {
        let tokens = command.split(separator: " ", maxSplits: 10)
        guard !tokens.isEmpty else { return .unknown }

        // Skip leading KEY=VALUE environment variable assignments
        for token in tokens {
            let str = String(token)
            if str.contains("=") && !str.hasPrefix("=") {
                continue
            }
            // Extract basename if it's a full path
            let name = (str as NSString).lastPathComponent.lowercased()
            if let type = commandMap[name] {
                return type
            }
            // First non-env token that doesn't match → generic shell
            return .shellCommand
        }
        return .unknown
    }
}
