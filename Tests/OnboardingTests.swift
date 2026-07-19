import XCTest
@testable import seahelm

final class OnboardingConfigTests: XCTestCase {
    func testFreshConfigStartsOnboardingIncomplete() {
        let config = Config()
        XCTAssertFalse(config.onboardingCompleted)
        XCTAssertEqual(config.defaultAgent, SailorType.claudeCode.rawValue)
        XCTAssertFalse(config.agentYolo)
        XCTAssertTrue(config.enabledHookAgents.isEmpty)
        XCTAssertEqual(config.notificationSound, "default")
    }

    func testLegacyConfigMissingOnboardingKeyIsCompleted() throws {
        let json = """
        {
            "workspace_paths": ["/repo"]
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertTrue(config.onboardingCompleted,
                      "Existing installs without the key must skip the wizard")
        XCTAssertEqual(config.workspacePaths, ["/repo"])
    }

    func testExplicitOnboardingFalseIsPreserved() throws {
        let json = """
        {
            "onboarding_completed": false,
            "default_agent": "codex",
            "agent_yolo": true,
            "enabled_hook_agents": ["claude", "codex"],
            "notification_sound": "none"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertFalse(config.onboardingCompleted)
        XCTAssertEqual(config.defaultAgent, "codex")
        XCTAssertTrue(config.agentYolo)
        XCTAssertEqual(config.enabledHookAgents, ["claude", "codex"])
        XCTAssertEqual(config.notificationSound, "none")
    }

    func testOnboardingFieldsRoundTrip() throws {
        var original = Config()
        original.onboardingCompleted = true
        original.defaultAgent = SailorType.openCode.rawValue
        original.agentYolo = true
        original.enabledHookAgents = ["opencode"]
        original.notificationSound = "defaultCritical"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.onboardingCompleted, true)
        XCTAssertEqual(decoded.defaultAgent, SailorType.openCode.rawValue)
        XCTAssertTrue(decoded.agentYolo)
        XCTAssertEqual(decoded.enabledHookAgents, ["opencode"])
        XCTAssertEqual(decoded.notificationSound, "defaultCritical")
    }
}

final class OnboardingAgentDetectorTests: XCTestCase {
    func testScanMarksDetectedFromCommandExists() {
        let agents = OnboardingAgentDetector.scan { cmd in
            cmd == "claude" || cmd == "codex"
        }
        let claude = agents.first { $0.type == .claudeCode }
        let gemini = agents.first { $0.type == .gemini }
        XCTAssertEqual(claude?.detected, true)
        XCTAssertEqual(gemini?.detected, false)
    }

    func testPreferredDefaultPrefersClaudeWhenDetected() {
        let agents = OnboardingAgentDetector.scan { $0 == "claude" || $0 == "codex" }
        XCTAssertEqual(OnboardingAgentDetector.preferredDefault(from: agents), .claudeCode)
    }

    func testPreferredDefaultFallsBackToFirstDetected() {
        let agents = OnboardingAgentDetector.scan { $0 == "codex" }
        XCTAssertEqual(OnboardingAgentDetector.preferredDefault(from: agents), .codex)
    }
}

final class GhosttyConfigImporterTests: XCTestCase {
    func testParseFontSettings() {
        let conf = """
        # comment
        font-family = "JetBrains Mono"
        font-size = 14
        theme = dark
        """
        let settings = GhosttyConfigImporter.parseFontSettings(from: conf)
        XCTAssertEqual(settings.family, "JetBrains Mono")
        XCTAssertEqual(settings.size, "14")
    }

    func testMergePreservesOtherLines() {
        let existing = """
        cursor-style = block
        font-family = Menlo
        """
        let merged = GhosttyConfigImporter.mergeFontSettings(
            into: existing,
            settings: .init(family: "SF Mono", size: "13")
        )
        XCTAssertTrue(merged.contains("cursor-style = block"))
        XCTAssertTrue(merged.contains("font-family = SF Mono"))
        XCTAssertTrue(merged.contains("font-size = 13"))
        XCTAssertFalse(merged.contains("Menlo"))
    }

    func testImportFontsWritesDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-ghostty-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = tmp.appendingPathComponent("ghostty-config")
        try """
        font-family = Iosevka
        font-size = 15
        """.write(to: source, atomically: true, encoding: .utf8)

        let dest = tmp.appendingPathComponent("seahelm-ghostty.conf")
        try "window-padding-x = 4\n".write(to: dest, atomically: true, encoding: .utf8)

        XCTAssertTrue(GhosttyConfigImporter.importFonts(from: source, destination: dest))
        let result = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(result.contains("window-padding-x = 4"))
        XCTAssertTrue(result.contains("font-family = Iosevka"))
        XCTAssertTrue(result.contains("font-size = 15"))
    }
}

final class AgentYoloLaunchTests: XCTestCase {
    func testClaudeYoloFlagAppended() {
        let cmd = SailorType.claudeCode.launchCommand(withTask: "hi", agentYolo: true)!
        XCTAssertTrue(cmd.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(cmd.contains("'hi'") || cmd.contains("hi"))
    }

    func testYoloOffOmitsFlag() {
        let cmd = SailorType.claudeCode.launchCommand(withTask: "", agentYolo: false)!
        XCTAssertFalse(cmd.contains("--dangerously-skip-permissions"))
    }

    func testCodexYoloFlag() {
        let cmd = SailorType.codex.launchCommand(withTask: "", agentYolo: true)!
        XCTAssertTrue(cmd.contains("--dangerously-bypass-approvals-and-sandbox"))
    }
}
