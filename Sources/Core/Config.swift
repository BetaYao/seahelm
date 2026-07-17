import Foundation

struct Config: Codable {
    var workspacePaths: [String]
    var activeWorkspaceIndex: Int
    var terminalRowCacheSize: Int
    var agentDetect: SailorDetectConfig
    var webhook: WebhookConfig
    var autoUpdate: UpdateConfig
    var cardOrder: [String]
    var zoomIndex: Int
    var themeMode: String
    var worktreeStartedAt: [String: String]
    /// Per-worktree last real-activity timestamp (ISO8601). Persisted so the
    /// >8h idle-collapse survives app restarts instead of resetting to launch.
    var worktreeLastActivityAt: [String: String]
    var splitLayouts: [String: CodableSplitNode]
    var activeTabRepoPath: String?
    var selectedWorktreePath: String?
    var activeWorktreePaths: [String: String]
    var focusedPaneIds: [String: String]
    /// Per-session agent resume refs, keyed by backend session name. Populated
    /// from agent hook events; used to relaunch the agent (e.g. `claude
    /// --resume <id>`) when a backend session is recreated instead of falling
    /// back to a plain shell.
    var agentSessions: [String: AgentSessionRef]
    var wecomBot: WeComBotConfig?
    var wechat: WeChatConfig?
    var firstMate: FirstMateConfig
    var notifications: NotificationConfig
    /// Vibe-island style notch overlay showing notifications + suggestions.
    var islandEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case workspacePaths = "workspace_paths"
        case activeWorkspaceIndex = "active_workspace_index"
        case terminalRowCacheSize = "terminal_row_cache_size"
        case agentDetect = "agent_detect"
        case webhook
        case autoUpdate = "auto_update"
        case cardOrder = "card_order"
        case zoomIndex = "zoom_index"
        case themeMode = "theme_mode"
        case worktreeStartedAt = "worktree_started_at"
        case worktreeLastActivityAt = "worktree_last_activity_at"
        case splitLayouts = "split_layouts"
        case activeTabRepoPath = "active_tab_repo_path"
        case selectedWorktreePath = "selected_worktree_path"
        case activeWorktreePaths = "active_worktree_paths"
        case focusedPaneIds = "focused_pane_ids"
        case agentSessions = "agent_sessions"
        case wecomBot = "wecom_bot"
        case wechat
        case firstMate
        case notifications
        case islandEnabled = "island_enabled"
    }

    init() {
        workspacePaths = []
        activeWorkspaceIndex = 0
        terminalRowCacheSize = 200
        agentDetect = SailorDetectConfig.default
        webhook = WebhookConfig()
        autoUpdate = UpdateConfig()
        cardOrder = []
        zoomIndex = 3
        themeMode = "system"
        worktreeStartedAt = [:]
        worktreeLastActivityAt = [:]
        splitLayouts = [:]
        activeTabRepoPath = nil
        selectedWorktreePath = nil
        activeWorktreePaths = [:]
        focusedPaneIds = [:]
        agentSessions = [:]
        wecomBot = nil
        wechat = nil
        firstMate = .default
        notifications = NotificationConfig()
        islandEnabled = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspacePaths = try container.decodeIfPresent([String].self, forKey: .workspacePaths) ?? []
        activeWorkspaceIndex = try container.decodeIfPresent(Int.self, forKey: .activeWorkspaceIndex) ?? 0
        terminalRowCacheSize = try container.decodeIfPresent(Int.self, forKey: .terminalRowCacheSize) ?? 200
        agentDetect = (try container.decodeIfPresent(SailorDetectConfig.self, forKey: .agentDetect) ?? .default)
            .includingMissingDefaultSailors()
        webhook = try container.decodeIfPresent(WebhookConfig.self, forKey: .webhook) ?? WebhookConfig()
        autoUpdate = try container.decodeIfPresent(UpdateConfig.self, forKey: .autoUpdate) ?? UpdateConfig()
        cardOrder = try container.decodeIfPresent([String].self, forKey: .cardOrder) ?? []
        zoomIndex = try container.decodeIfPresent(Int.self, forKey: .zoomIndex) ?? 3
        themeMode = try container.decodeIfPresent(String.self, forKey: .themeMode) ?? "system"
        worktreeStartedAt = try container.decodeIfPresent([String: String].self, forKey: .worktreeStartedAt) ?? [:]
        worktreeLastActivityAt = try container.decodeIfPresent([String: String].self, forKey: .worktreeLastActivityAt) ?? [:]
        splitLayouts = try container.decodeIfPresent([String: CodableSplitNode].self, forKey: .splitLayouts) ?? [:]
        activeTabRepoPath = try container.decodeIfPresent(String.self, forKey: .activeTabRepoPath)
        selectedWorktreePath = try container.decodeIfPresent(String.self, forKey: .selectedWorktreePath)
        activeWorktreePaths = try container.decodeIfPresent([String: String].self, forKey: .activeWorktreePaths) ?? [:]
        focusedPaneIds = try container.decodeIfPresent([String: String].self, forKey: .focusedPaneIds) ?? [:]
        agentSessions = try container.decodeIfPresent([String: AgentSessionRef].self, forKey: .agentSessions) ?? [:]
        wecomBot = try container.decodeIfPresent(WeComBotConfig.self, forKey: .wecomBot)
        wechat = try container.decodeIfPresent(WeChatConfig.self, forKey: .wechat)
        firstMate = try container.decodeIfPresent(FirstMateConfig.self, forKey: .firstMate) ?? .default
        notifications = try container.decodeIfPresent(NotificationConfig.self, forKey: .notifications) ?? NotificationConfig()
        islandEnabled = try container.decodeIfPresent(Bool.self, forKey: .islandEnabled) ?? true
    }

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/seahelm")
    static let configPath = configDir.appendingPathComponent("config.json")

    /// Copies the newest pre-existing config dir (~/.config/seamux, else
    /// ~/.config/amux) into ~/.config/seahelm on first launch. Source dirs are
    /// kept for rollback. No-op once ~/.config/seahelm exists.
    static func migrateLegacyConfigDirIfNeeded(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager fm: FileManager = .default
    ) {
        let new = home.appendingPathComponent(".config/seahelm")
        guard !fm.fileExists(atPath: new.path) else { return }
        let candidates = [".config/seamux", ".config/amux"]
        for rel in candidates {
            let legacy = home.appendingPathComponent(rel)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.copyItem(at: legacy, to: new)
                return
            }
        }
    }

    static func load() -> Config {
        // Pretend a fresh install: no repos to restore means no stations, and so
        // no `zmx attach` into sessions the live app is already driving.
        if DebugFlags.forceEmptyState { return Config() }

        migrateLegacyConfigDirIfNeeded()
        // Support UI test config override via launch argument
        if let idx = CommandLine.arguments.firstIndex(of: "-UITestConfig"),
           idx + 1 < CommandLine.arguments.count {
            let testPath = CommandLine.arguments[idx + 1]
            if let data = FileManager.default.contents(atPath: testPath) {
                return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
            }
        }

        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return Config()
        }
        do {
            let data = try Data(contentsOf: configPath)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("Failed to load config: \(error)")
            return Config()
        }
    }

    private static let saveQueue = DispatchQueue(label: "com.seahelm.config-save", qos: .utility)
    private static var pendingSaveWorkItem: DispatchWorkItem?

    func save() {
        // A forced-empty-state instance shares the real config path with the
        // live app; saving would persist its pretend-empty view over the real one.
        guard !DebugFlags.forceEmptyState else { return }

        // Debounced async save: coalesces rapid saves into a single write
        Config.pendingSaveWorkItem?.cancel()
        let configCopy = self
        let workItem = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(configCopy)
                try data.write(to: Config.configPath, options: .atomic)
            } catch {
                NSLog("Failed to save config: \(error)")
            }
        }
        Config.pendingSaveWorkItem = workItem
        Config.saveQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
}

struct SailorDetectConfig: Codable {
    var agents: [SailorDef]

    static let `default` = SailorDetectConfig(agents: [
        SailorDef(name: "claude", rules: [
            SailorRule(status: "Running", patterns: ["to interrupt", "(thinking)", "moving to task"]),
            SailorRule(status: "Error", patterns: ["ERROR", "error:"]),
            SailorRule(status: "Waiting", patterns: ["?", "(y/n)", "(yes/no)"]),
        ], defaultStatus: "Idle", messageSkipPatterns: ["shift+tab", "accept edits", "to interrupt"]),
        SailorDef(name: "codex", rules: [
            SailorRule(status: "Waiting", patterns: [
                "would you like to run the following command?",
                "would you like to proceed?",
                "yes, proceed",
                "don't ask again",
                "tell codex what to do differently",
            ]),
            SailorRule(status: "Running", patterns: ["to interrupt", "(thinking)", "moving to task"]),
            SailorRule(status: "Error", patterns: ["error:"]),
        ], defaultStatus: "Idle", messageSkipPatterns: ["tip", "shortcuts", "switch layout"]),
        SailorDef(name: "agent", rules: [
            SailorRule(status: "Running", patterns: ["to interrupt"]),
            SailorRule(status: "Error", patterns: ["error"]),
            SailorRule(status: "Waiting", patterns: ["?", "> "]),
        ], defaultStatus: "Idle", messageSkipPatterns: ["shift+tab", "accept edits", "to interrupt"]),
    ])

    func includingMissingDefaultSailors() -> SailorDetectConfig {
        var merged = self
        for defaultSailor in Self.default.agents {
            if let index = merged.agents.firstIndex(where: { $0.name == defaultSailor.name }) {
                merged.agents[index].mergeMissingDefaults(from: defaultSailor)
            } else {
                merged.agents.append(defaultSailor)
            }
        }
        return merged
    }
}

struct SailorDef: Codable {
    var name: String
    var rules: [SailorRule]
    var defaultStatus: String
    var messageSkipPatterns: [String]

    enum CodingKeys: String, CodingKey {
        case name, rules
        case defaultStatus = "default_status"
        case messageSkipPatterns = "message_skip_patterns"
    }
}

struct SailorRule: Codable, Equatable {
    var status: String
    var patterns: [String]
}

private extension SailorDef {
    mutating func mergeMissingDefaults(from defaultSailor: SailorDef) {
        for defaultRule in defaultSailor.rules {
            if let index = rules.firstIndex(where: { $0.status.lowercased() == defaultRule.status.lowercased() }) {
                rules[index].appendMissingPatterns(defaultRule.patterns)
            } else {
                rules.append(defaultRule)
            }
        }
        messageSkipPatterns.appendMissingCaseInsensitive(defaultSailor.messageSkipPatterns)
    }
}

private extension SailorRule {
    mutating func appendMissingPatterns(_ defaults: [String]) {
        patterns.appendMissingCaseInsensitive(defaults)
    }
}

private extension Array where Element == String {
    mutating func appendMissingCaseInsensitive(_ defaults: [String]) {
        var existing = Set(map { $0.lowercased() })
        for value in defaults where !existing.contains(value.lowercased()) {
            append(value)
            existing.insert(value.lowercased())
        }
    }
}

/// Hook/event integration settings. (Formerly carried an HTTP `port`; the HTTP
/// webhook was retired for the fs-scoped control socket, so only the behavioral
/// flags remain. A legacy `port` key in old configs is ignored.)
struct WebhookConfig: Codable {
    var enabled: Bool = true
    var suggestOnStop: Bool = true

    enum CodingKeys: String, CodingKey {
        case enabled
        case suggestOnStop = "suggest_on_stop"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        suggestOnStop = try c.decodeIfPresent(Bool.self, forKey: .suggestOnStop) ?? true
    }
}

struct NotificationConfig: Codable {
    /// Stability gate: after an agent settles into a terminal state (idle /
    /// waiting / error), wait this many seconds before actually delivering the
    /// notification. If the status changes again within the window the pending
    /// notification is dropped — this kills the "flash done" false alarms that
    /// slip through when waiting/error/visible-idle commit immediately. This is
    /// a state-stability gate, not a rate limit. 0 disables it (fire on edge).
    var stabilityDelay: TimeInterval = 1.0
    /// Minimum seconds between delivered notifications for the same pane/worktree.
    var cooldown: TimeInterval = 30

    enum CodingKeys: String, CodingKey {
        case stabilityDelay = "stability_delay"
        case cooldown
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stabilityDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .stabilityDelay) ?? 1.0
        cooldown = try c.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? 30
    }
}

struct UpdateConfig: Codable {
    var enabled: Bool = true
    var checkIntervalHours: Int = 6
    var skippedVersion: String? = nil

    enum CodingKeys: String, CodingKey {
        case enabled
        case checkIntervalHours = "check_interval_hours"
        case skippedVersion = "skipped_version"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        checkIntervalHours = try container.decodeIfPresent(Int.self, forKey: .checkIntervalHours) ?? 6
        skippedVersion = try container.decodeIfPresent(String.self, forKey: .skippedVersion)
    }
}
