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
    /// Instruction injected into the agent's system prompt so it emits next-step
    /// suggestions itself as the last action of a turn — no blocking Stop hook /
    /// extra round-trip. The Stop-hook path stays as a fallback for turns where
    /// the agent doesn't comply or wasn't launched with this flag.
    static let suggestInstruction =
        "End every response with one final PLAIN-TEXT line formatted exactly as " +
        "`\(StopHookResponder.sentinel) first option | second option`, giving 2-5 short " +
        "imperative next-step options (a few words each) separated by ` | `. seahelm turns " +
        "that line into clickable buttons for the user. Make it the LAST line of your " +
        "message; do NOT run any tool or shell command to produce it."

    /// Agent-specific flag that appends to the system prompt at launch. nil =
    /// this agent gets suggestions only via the Stop-hook fallback.
    private var appendSystemPromptFlag: String? {
        switch self {
        case .claudeCode: return "--append-system-prompt"
        default:          return nil
        }
    }

    func launchCommand(withTask task: String) -> String? {
        launchCommand(withTask: task, agentYolo: Config.load().agentYolo)
    }

    /// Testable overload — avoids Config.load() in unit tests.
    func launchCommand(withTask task: String, agentYolo: Bool) -> String? {
        guard let base = launchCommand else { return nil }
        var cmd = base
        if agentYolo, let yolo = yoloFlag {
            cmd += " \(yolo)"
        }
        if let flag = appendSystemPromptFlag {
            cmd += " \(flag) \(ShellEscape.singleQuote(Self.suggestInstruction))"
        }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            cmd += " \(ShellEscape.singleQuote(trimmed))"
        }
        return cmd
    }

    /// Skip-permission / YOLO CLI flag for this agent, if known.
    var yoloFlag: String? {
        switch self {
        case .claudeCode:
            return "--dangerously-skip-permissions"
        case .codex:
            return "--dangerously-bypass-approvals-and-sandbox"
        case .cursor:
            return "--yolo"
        case .openCode:
            return "--yolo"
        default:
            return nil
        }
    }

    /// Short label for compact UI (the picker chip).
    var shortName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .openCode:   return "OpenCode"
        default:          return displayName
        }
    }

    /// Manifest id used to resolve this agent's detection rules from ManifestStore.
    /// Each known AI agent has its own manifest; anything else falls back to the
    /// generic "agent" manifest.
    var manifestId: String {
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
        default:          return "agent"
        }
    }

    /// Reverse of `manifestId` for agents identifiable by process probe (those
    /// whose manifest declares a `process` block). The generic "agent" manifest
    /// has no process block, so the probe never returns it.
    static func fromManifestId(_ id: String?) -> SailorType {
        switch id {
        case "claude":   return .claudeCode
        case "codex":    return .codex
        case "opencode": return .openCode
        case "gemini":   return .gemini
        case "cline":    return .cline
        case "goose":    return .goose
        case "amp":      return .amp
        case "aider":    return .aider
        case "cursor":   return .cursor
        case "kiro":     return .kiro
        default:         return .unknown
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

    /// Short glyph shown before a worktree tab title (cockpit redesign).
    /// AI agents get a sigil (Claude ✻ / Codex ⟡ / others ◆); shell tasks get
    /// a terminal mark; unknown gets none.
    var tabGlyph: String? {
        switch self {
        case .claudeCode: return "✻"
        case .codex:      return "⟡"
        case .openCode:   return "◇"
        case .gemini:     return "✦"
        case .unknown:    return nil
        default:          return isAIAgent ? "◆" : "❯"
        }
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
