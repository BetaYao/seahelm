import Foundation

struct Config: Codable {
    var workspacePaths: [String]
    var activeWorkspaceIndex: Int
    var backend: String
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

    enum CodingKeys: String, CodingKey {
        case workspacePaths = "workspace_paths"
        case activeWorkspaceIndex = "active_workspace_index"
        case backend
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
    }

    init() {
        workspacePaths = []
        activeWorkspaceIndex = 0
        backend = "zmx"
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspacePaths = try container.decodeIfPresent([String].self, forKey: .workspacePaths) ?? []
        activeWorkspaceIndex = try container.decodeIfPresent(Int.self, forKey: .activeWorkspaceIndex) ?? 0
        var rawBackend = try container.decodeIfPresent(String.self, forKey: .backend) ?? "zmx"
        if rawBackend == "tmux" {
            rawBackend = "zmx"
        }
        backend = rawBackend
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

struct SailorRule: Codable {
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

struct WebhookConfig: Codable {
    var enabled: Bool = true
    var port: UInt16 = 7070
    var suggestOnStop: Bool = true

    enum CodingKeys: String, CodingKey {
        case enabled, port
        case suggestOnStop = "suggest_on_stop"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 7070
        suggestOnStop = try c.decodeIfPresent(Bool.self, forKey: .suggestOnStop) ?? true
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
