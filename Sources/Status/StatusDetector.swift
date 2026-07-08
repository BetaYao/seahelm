import Foundation

enum ProcessStatus {
    case running    // Process is alive
    case exited     // Exited with code 0
    case error      // Exited with code != 0
    case unknown    // Not started or unavailable
}

/// Deterministic status detection: ProcessStatus > ShellPhase > TextPatterns > Unknown
class StatusDetector {

    // Compiled once — these run per-pane on every poll cycle.
    // ⏺ ToolName(args) or ✗ ToolName(args)
    private static let activityCirclePattern = try! NSRegularExpression(pattern: #"^[[:space:]]*([⏺✗])\s+(\w+)\((.+?)\)"#)
    // ▸ ToolName   detail or ✗ ToolName   detail
    private static let activityArrowPattern = try! NSRegularExpression(pattern: #"^[[:space:]]*([▸✗])\s+(\w+)\s{2,}(.+)$"#)

    /// Detect agent status from available signals (priority order).
    /// Accepts an optional pre-lowercased content string to avoid redundant lowercasing.
    func detect(
        processStatus: ProcessStatus,
        shellInfo: ShellPhaseInfo?,
        content: String,
        agentDef: SailorDef?,
        manifest: CompiledManifest? = nil,
        osc: (title: String, progress: String) = ("", ""),
        lowercasedContent: String? = nil
    ) -> SailorStatus {
        // Priority 1: Process lifecycle overrides everything
        switch processStatus {
        case .exited: return .exited
        case .error:  return .error
        case .unknown: break
        case .running: break
        }

        // Priority 2: OSC 133 shell phase (authoritative when available)
        if let info = shellInfo {
            switch info.phase {
            case .running:
                return .running
            case .input, .prompt:
                return .idle
            case .output:
                if let code = info.lastExitCode, code != 0 {
                    return .error
                }
                return .idle
            }
        }

        // Priority 3: Manifest rule engine (preferred), else legacy SailorDef rules.
        if !content.isEmpty {
            let lower = lowercasedContent ?? content.lowercased()
            if let manifest {
                let d = manifest.evaluate(DetectionInput(
                    screen: lower, oscTitle: osc.title, oscProgress: osc.progress))
                return d.state == .unknown ? manifest.defaultStatus : d.state
            }
            if let agent = agentDef {
                return agent.detectStatus(fromLowercased: lower)
            }
        }

        return .unknown
    }

    /// Like `detect`, but returns the rich Detection (state + visible_* flags +
    /// matched rule id). Process lifecycle and OSC133 layers synthesize their own
    /// visible flags so the debounce/authority layers can treat all sources
    /// uniformly.
    func detectDetailed(
        processStatus: ProcessStatus,
        shellInfo: ShellPhaseInfo?,
        content: String,
        manifest: CompiledManifest?,
        osc: (title: String, progress: String) = ("", ""),
        lowercasedContent: String? = nil
    ) -> Detection {
        switch processStatus {
        case .exited: return Detection(state: .exited, visibleIdle: true)
        case .error:  return Detection(state: .error, visibleBlocker: true)
        case .unknown, .running: break
        }

        if let info = shellInfo {
            switch info.phase {
            case .running: return Detection(state: .running, visibleWorking: true)
            case .input, .prompt: return Detection(state: .idle, visibleIdle: true)
            case .output:
                if let code = info.lastExitCode, code != 0 { return Detection(state: .error) }
                return Detection(state: .idle, visibleIdle: true)
            }
        }

        guard !content.isEmpty, let manifest else { return .unknown }
        let lower = lowercasedContent ?? content.lowercased()
        let d = manifest.evaluate(DetectionInput(screen: lower, oscTitle: osc.title, oscProgress: osc.progress))
        if d.state == .unknown {
            return Detection(state: manifest.defaultStatus, visibleIdle: manifest.defaultStatus == .idle)
        }
        return d
    }

    /// Extract activity events from terminal viewport text.
    /// Looks for tool-call-like patterns (⏺ Tool(detail), ▸ Tool detail, ✗ Tool detail).
    /// Returns newest-first (bottom of terminal = most recent).
    func extractActivityEvents(from text: String) -> [ActivityEvent] {
        guard !text.isEmpty else { return [] }

        var events: [ActivityEvent] = []
        let lines = text.components(separatedBy: .newlines)
        let circlePattern = Self.activityCirclePattern
        let arrowPattern = Self.activityArrowPattern

        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            var marker: String?
            var tool: String?
            var detail: String?

            if let match = circlePattern.firstMatch(in: line, range: range) {
                marker = nsLine.substring(with: match.range(at: 1))
                tool = nsLine.substring(with: match.range(at: 2))
                detail = nsLine.substring(with: match.range(at: 3))
            } else if let match = arrowPattern.firstMatch(in: line, range: range) {
                marker = nsLine.substring(with: match.range(at: 1))
                tool = nsLine.substring(with: match.range(at: 2))
                detail = nsLine.substring(with: match.range(at: 3))
            }

            if let marker, let tool, let detail {
                let isError = marker == "✗"
                events.append(ActivityEvent(
                    tool: tool,
                    detail: detail.trimmingCharacters(in: .whitespaces),
                    isError: isError,
                    timestamp: Date()
                ))
            }
        }

        // Reverse so newest (bottom of terminal) is first, cap at 20
        events.reverse()
        if events.count > 20 {
            events = Array(events.prefix(20))
        }
        return events
    }
}

// MARK: - SailorDef status detection


extension SailorDef {
    /// Get pre-lowercased rules (computed inline for efficiency)
    private var lowercasedRules: [(status: String, patterns: [String])] {
        rules.map { rule in
            (status: rule.status, patterns: rule.patterns.map { $0.lowercased() })
        }
    }

    /// Get pre-lowercased messageSkipPatterns (computed inline for efficiency)
    private var lowercasedSkipPatterns: [String] {
        messageSkipPatterns.map { $0.lowercased() }
    }

    /// Apply rules in order; first match wins
    func detectStatus(from content: String) -> SailorStatus {
        return detectStatus(fromLowercased: content.lowercased())
    }

    /// Apply rules using pre-lowercased content to avoid redundant lowercasing.
    /// Only scans the last ~10 lines to avoid false positives from old command output
    /// (e.g. "0 errors" from a successful cargo build triggering Error status).
    func detectStatus(fromLowercased lower: String) -> SailorStatus {
        let tail = Self.lastLines(of: lower, count: 10)
        for (status, patterns) in lowercasedRules {
            for pattern in patterns {
                if tail.contains(pattern) {
                    return SailorStatus(rawValue: status) ?? .unknown
                }
            }
        }
        return SailorStatus(rawValue: defaultStatus) ?? .idle
    }

    /// Extract the last N lines from a string efficiently (no array allocation).
    private static func lastLines(of text: String, count: Int) -> Substring {
        var newlinesSeen = 0
        var idx = text.endIndex
        while idx > text.startIndex {
            idx = text.index(before: idx)
            if text[idx] == "\n" {
                newlinesSeen += 1
                if newlinesSeen == count {
                    return text[text.index(after: idx)...]
                }
            }
        }
        return text[...]
    }

    func extractLastMessage(from content: String, maxLen: Int) -> String {
        // Scan from the end of the string without splitting into an array
        var endIndex = content.endIndex
        while endIndex > content.startIndex {
            // Find start of current line
            var lineStart = content.index(before: endIndex)
            while lineStart > content.startIndex && content[content.index(before: lineStart)] != "\n" {
                lineStart = content.index(before: lineStart)
            }

            let line = content[lineStart..<endIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !trimmed.isEmpty && !isChromeLine(trimmed) {
                let trimmedLower = trimmed.lowercased()
                if !lowercasedSkipPatterns.contains(where: { trimmedLower.contains($0) }) {
                    if trimmed.count > maxLen {
                        return String(trimmed.prefix(maxLen - 3)) + "..."
                    }
                    return trimmed
                }
            }

            // Move to previous line
            endIndex = lineStart > content.startIndex ? lineStart : content.startIndex
            if endIndex > content.startIndex && content[content.index(before: endIndex)] == "\n" {
                endIndex = content.index(before: endIndex)
            }
        }
        return ""
    }

    private func isChromeLine(_ line: String) -> Bool {
        // Box-drawing characters and decorative lines
        let chromeChars: Set<Character> = ["─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼",
                                           "═", "║", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬",
                                           "━", "┃", "┏", "┓", "┗", "┛", "┣", "┫", "┳", "┻", "╋"]
        if line.count <= 2 { return true }
        return line.allSatisfy { chromeChars.contains($0) || $0 == " " }
    }
}

// MARK: - DebouncedStatusTracker

/// Tracks status changes; Unknown preserves current state.
///
/// A bare `running → idle` transition is *held* for `pendingIdleConfirmations`
/// consecutive observations before it commits, to kill flicker when an agent
/// momentarily looks idle mid-turn (our poll is coarse, so one extra confirmation
/// ~= one poll cycle). A `visibleIdle` signal (process exit, OSC133 prompt, an
/// explicit visible_idle rule) bypasses the hold and commits immediately.
class DebouncedStatusTracker {
    private(set) var currentStatus: SailorStatus = .unknown

    /// Consecutive plain-idle observations required to leave `running`.
    var pendingIdleConfirmations = 2
    private var pendingIdleCount = 0

    /// Update with detected status. Returns true if status changed.
    @discardableResult
    func update(status: SailorStatus, visibleIdle: Bool = true) -> Bool {
        // Unknown means "no data" — don't change.
        guard status != .unknown else { return false }

        // Hold a bare running→idle flip until it is confirmed (unless a visible
        // idle signal proves the agent really finished).
        if currentStatus == .running, status == .idle, !visibleIdle {
            pendingIdleCount += 1
            if pendingIdleCount < pendingIdleConfirmations { return false }
        }
        pendingIdleCount = 0

        guard status != currentStatus else { return false }
        currentStatus = status
        return true
    }

    func forceStatus(_ status: SailorStatus) {
        currentStatus = status
        pendingIdleCount = 0
    }

    func reset() {
        currentStatus = .unknown
        pendingIdleCount = 0
    }
}

// MARK: - SailorStatus extensions

extension SailorStatus {
    /// Rollup priority. `waiting` (agent blocked on the user) ranks highest so it
    /// bubbles to the worktree badge — it is the state most in need of attention.
    var priority: UInt8 {
        switch self {
        case .waiting: return 6
        case .error:   return 5
        case .exited:  return 4
        case .running: return 3
        case .idle:    return 2
        case .unknown: return 1
        }
    }

    var isUrgent: Bool {
        self == .error || self == .waiting
    }

    var isActive: Bool {
        self == .running || self == .waiting
    }

    static func highestPriority(_ statuses: [SailorStatus]) -> SailorStatus {
        statuses.max(by: { $0.priority < $1.priority }) ?? .unknown
    }
}
