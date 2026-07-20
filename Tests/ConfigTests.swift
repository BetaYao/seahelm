import XCTest
@testable import seahelm

final class ConfigTests: XCTestCase {

    // MARK: - Default Config

    func testDefaultConfig() {
        let config = Config()
        XCTAssertTrue(config.workspacePaths.isEmpty)
        XCTAssertEqual(config.activeWorkspaceIndex, 0)
        XCTAssertEqual(config.terminalRowCacheSize, 200)
        XCTAssertFalse(config.agentDetect.agents.isEmpty)
        XCTAssertFalse(config.onboardingCompleted)
    }

    // MARK: - JSON Decode

    func testDecodeFullConfig() throws {
        let json = """
        {
            "workspace_paths": ["/path/a", "/path/b"],
            "active_workspace_index": 1,
            "terminal_row_cache_size": 500
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.workspacePaths, ["/path/a", "/path/b"])
        XCTAssertEqual(config.activeWorkspaceIndex, 1)
        XCTAssertEqual(config.terminalRowCacheSize, 500)
    }

    func testDecodePartialConfig_UsesDefaults() throws {
        let json = """
        {
            "workspace_paths": ["/path/a"]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.workspacePaths, ["/path/a"])
        XCTAssertEqual(config.terminalRowCacheSize, 200)  // default
    }

    func testDecodeEmptyJSON_UsesDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertTrue(config.workspacePaths.isEmpty)
        // Missing onboarding_completed → legacy skip (completed).
        XCTAssertTrue(config.onboardingCompleted)
    }

    // MARK: - Quit Confirmation

    func testConfirmBeforeQuit_DefaultsOn() throws {
        XCTAssertTrue(Config().confirmBeforeQuit)
        // Existing configs predate the key, so they must opt in, not out.
        let legacy = try JSONDecoder().decode(Config.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(legacy.confirmBeforeQuit)
    }

    func testConfirmBeforeQuit_SuppressionSurvivesRoundtrip() throws {
        // What the "Don't ask again" checkbox writes must still be off after a reload.
        var config = Config()
        config.confirmBeforeQuit = false

        let data = try JSONEncoder().encode(config)
        let reloaded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertFalse(reloaded.confirmBeforeQuit)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("confirm_before_quit"), "must persist under its snake_case key")
    }

    // MARK: - JSON Roundtrip

    func testEncodeDecodeRoundtrip() throws {
        var original = Config()
        original.workspacePaths = ["/a", "/b"]

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(decoded.workspacePaths, original.workspacePaths)
        XCTAssertEqual(decoded.terminalRowCacheSize, original.terminalRowCacheSize)
    }

    // MARK: - Agent Detect Config

    func testDefaultAgentDetect_HasClaude() {
        let agents = SailorDetectConfig.default.agents
        XCTAssertTrue(agents.contains(where: { $0.name == "claude" }))
    }

    func testClaudeAgent_HasRules() {
        let claude = SailorDetectConfig.default.agents.first(where: { $0.name == "claude" })!
        XCTAssertFalse(claude.rules.isEmpty)
        XCTAssertEqual(claude.defaultStatus, "Idle")
        XCTAssertFalse(claude.messageSkipPatterns.isEmpty)
    }

    func testDecodeExistingSailorDetectAddsMissingDefaultSailors() throws {
        let json = """
        {
            "agent_detect": {
                "agents": [
                    {
                        "name": "claude",
                        "rules": [{"status": "Running", "patterns": ["to interrupt"]}],
                        "default_status": "Idle",
                        "message_skip_patterns": []
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)

        XCTAssertTrue(config.agentDetect.agents.contains(where: { $0.name == "claude" }))
        XCTAssertTrue(config.agentDetect.agents.contains(where: { $0.name == "codex" }))
    }

    func testDecodeExistingSailorDetectMergesMissingDefaultRulePatterns() throws {
        let json = """
        {
            "agent_detect": {
                "agents": [
                    {
                        "name": "codex",
                        "rules": [
                            {"status": "Running", "patterns": ["to interrupt", "custom running"]},
                            {"status": "Waiting", "patterns": ["custom waiting"]}
                        ],
                        "default_status": "Idle",
                        "message_skip_patterns": ["custom skip"]
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)
        let codex = try XCTUnwrap(config.agentDetect.agents.first { $0.name == "codex" })
        let running = try XCTUnwrap(codex.rules.first { $0.status == "Running" })
        let waiting = try XCTUnwrap(codex.rules.first { $0.status == "Waiting" })
        let error = try XCTUnwrap(codex.rules.first { $0.status == "Error" })

        XCTAssertTrue(running.patterns.contains("custom running"))
        XCTAssertTrue(running.patterns.contains("to interrupt"))
        XCTAssertTrue(running.patterns.contains("(thinking)"))
        XCTAssertTrue(running.patterns.contains("moving to task"))
        XCTAssertTrue(waiting.patterns.contains("custom waiting"))
        XCTAssertTrue(waiting.patterns.contains("would you like to run the following command?"))
        XCTAssertTrue(error.patterns.contains("error:"))
        XCTAssertTrue(codex.messageSkipPatterns.contains("custom skip"))
        XCTAssertTrue(codex.messageSkipPatterns.contains("tip"))
    }

    func testDecodeExistingClaudeSailorDetectMergesTaskProgressRunningPatterns() throws {
        let json = """
        {
            "agent_detect": {
                "agents": [
                    {
                        "name": "claude",
                        "rules": [{"status": "Running", "patterns": ["to interrupt"]}],
                        "default_status": "Idle",
                        "message_skip_patterns": []
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)
        let claude = try XCTUnwrap(config.agentDetect.agents.first { $0.name == "claude" })
        let running = try XCTUnwrap(claude.rules.first { $0.status == "Running" })

        XCTAssertTrue(running.patterns.contains("(thinking)"))
        XCTAssertTrue(running.patterns.contains("moving to task"))
    }

    // MARK: - Save/Load to File

    func testSaveAndLoadFromFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("config.json")

        // Create and save config
        var config = Config()
        config.workspacePaths = ["/Users/dev/project-a", "/Users/dev/project-b"]
        config.terminalRowCacheSize = 500

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: filePath)

        // Load it back
        let loadedData = try Data(contentsOf: filePath)
        let loaded = try JSONDecoder().decode(Config.self, from: loadedData)

        XCTAssertEqual(loaded.workspacePaths, ["/Users/dev/project-a", "/Users/dev/project-b"])
        XCTAssertEqual(loaded.terminalRowCacheSize, 500)
    }

    func testConfigModification_WorkspacePaths() {
        var config = Config()
        XCTAssertTrue(config.workspacePaths.isEmpty)

        config.workspacePaths.append("/new/path")
        XCTAssertEqual(config.workspacePaths.count, 1)

        config.workspacePaths.append("/another/path")
        XCTAssertEqual(config.workspacePaths.count, 2)

        config.workspacePaths.remove(at: 0)
        XCTAssertEqual(config.workspacePaths, ["/another/path"])
    }

    func testAgentDetectConfig_EncodeDecodeRoundtrip() throws {
        let original = SailorDetectConfig.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SailorDetectConfig.self, from: data)

        XCTAssertEqual(decoded.agents.count, original.agents.count)
        for (orig, dec) in zip(original.agents, decoded.agents) {
            XCTAssertEqual(orig.name, dec.name)
            XCTAssertEqual(orig.defaultStatus, dec.defaultStatus)
            XCTAssertEqual(orig.rules.count, dec.rules.count)
        }
    }

    func testCardOrder_DefaultEmpty() {
        let config = Config()
        XCTAssertTrue(config.cardOrder.isEmpty)
    }

    func testCardOrder_RoundTrip() throws {
        var config = Config()
        config.cardOrder = ["/path/a", "/path/b", "/path/c"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.cardOrder, ["/path/a", "/path/b", "/path/c"])
    }

    func testCardOrder_SortsWorktrees() {
        let order = ["/c", "/a", "/b"]
        var items = [
            (path: "/a", index: 0),
            (path: "/b", index: 1),
            (path: "/c", index: 2),
        ]
        items.sort { a, b in
            let ai = order.firstIndex(of: a.path) ?? Int.max
            let bi = order.firstIndex(of: b.path) ?? Int.max
            return ai < bi
        }
        XCTAssertEqual(items.map { $0.path }, ["/c", "/a", "/b"])
    }

    func testCardOrder_UnknownPathsGoToEnd() {
        let order = ["/b", "/a"]
        var items = [
            (path: "/a", index: 0),
            (path: "/b", index: 1),
            (path: "/unknown", index: 2),
        ]
        items.sort { a, b in
            let ai = order.firstIndex(of: a.path) ?? Int.max
            let bi = order.firstIndex(of: b.path) ?? Int.max
            return ai < bi
        }
        XCTAssertEqual(items.map { $0.path }, ["/b", "/a", "/unknown"])
    }

    func testDefaultThemeMode() {
        let config = Config()
        XCTAssertEqual(config.themeMode, "system")
    }

    func testSidebarWidthDefault() {
        let config = Config()
        XCTAssertEqual(config.sidebarWidth, 300)
    }

    func testDecodeSidebarWidth() throws {
        let json = #"{"sidebar_width": 280}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.sidebarWidth, 280)
    }

    func testDecodeMissingSidebarWidth_UsesDefault() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(config.sidebarWidth, 300)
    }

    func testEncodeDecodeSidebarWidthRoundtrip() throws {
        var original = Config()
        original.sidebarWidth = 264
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.sidebarWidth, 264)
    }

    func testDecodeMissingNewFields() throws {
        let json = """
        {
            "workspace_paths": ["/path/a"]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.themeMode, "system")
    }

    // MARK: - Config Dir Migration

    func testMigratesLegacyConfigDirWhenNewMissing() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("seahelm-migrate-\(UUID().uuidString)")
        let legacy = tmp.appendingPathComponent(".config/amux")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "{\"foo\":1}".write(to: legacy.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

        let migrated = tmp.appendingPathComponent(".config/seahelm/config.json")
        XCTAssertTrue(fm.fileExists(atPath: migrated.path), "new config.json should exist after migration")
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("config.json").path), "legacy must be kept for rollback")
    }

    func testMigrationNoopWhenNewExists() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("seahelm-migrate-\(UUID().uuidString)")
        let legacy = tmp.appendingPathComponent(".config/amux")
        let new = tmp.appendingPathComponent(".config/seahelm")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try "OLD".write(to: legacy.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "NEW".write(to: new.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

        let content = try String(contentsOf: new.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertEqual(content, "NEW", "existing new config must not be overwritten")
    }

    // MARK: - Seahelm Migration

    func testMigratesSeamuxIntoSeahelm() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let seamux = tmp.appendingPathComponent(".config/seamux")
        try fm.createDirectory(at: seamux, withIntermediateDirectories: true)
        try "{}".write(to: seamux.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

        let seahelm = tmp.appendingPathComponent(".config/seahelm/config.json")
        XCTAssertTrue(fm.fileExists(atPath: seahelm.path))
        // Source dir preserved for rollback
        XCTAssertTrue(fm.fileExists(atPath: seamux.appendingPathComponent("config.json").path))
    }

    func testMigratesAmuxWhenNoSeamux() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let amux = tmp.appendingPathComponent(".config/amux")
        try fm.createDirectory(at: amux, withIntermediateDirectories: true)
        try "{}".write(to: amux.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

        let seahelm = tmp.appendingPathComponent(".config/seahelm/config.json")
        XCTAssertTrue(fm.fileExists(atPath: seahelm.path))
    }

    func testNoMigrationWhenSeahelmExists() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let seahelm = tmp.appendingPathComponent(".config/seahelm")
        let seamux = tmp.appendingPathComponent(".config/seamux")
        try fm.createDirectory(at: seahelm, withIntermediateDirectories: true)
        try fm.createDirectory(at: seamux, withIntermediateDirectories: true)
        try "new".write(to: seahelm.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "old".write(to: seamux.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        Config.migrateLegacyConfigDirIfNeeded(home: tmp, fileManager: fm)

        let contents = try String(contentsOf: seahelm.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertEqual(contents, "new")  // not overwritten
    }

    func testAgentDetectConfig_Decode() throws {
        let json = """
        {
            "agents": [
                {
                    "name": "myagent",
                    "rules": [{"status": "Running", "patterns": ["working"]}],
                    "default_status": "Idle",
                    "message_skip_patterns": []
                }
            ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(SailorDetectConfig.self, from: json)
        XCTAssertEqual(config.agents.count, 1)
        XCTAssertEqual(config.agents[0].name, "myagent")
        XCTAssertEqual(config.agents[0].rules[0].status, "Running")
        XCTAssertEqual(config.agents[0].rules[0].patterns, ["working"])
    }
}
