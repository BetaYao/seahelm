import XCTest
@testable import seahelm

final class ClaudeStatuslineBridgeInstallerTests: XCTestCase {
    func testInstallsWrapperAndPreservesExistingCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = root.appendingPathComponent(".claude")
        let supportDir = root.appendingPathComponent("Application Support/seahelm")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = claudeDir.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"claude-hud","padding":2}}"#.write(to: settings, atomically: true, encoding: .utf8)

        let changed = ClaudeStatuslineBridgeInstaller.ensureInstalledForTests(
            settingsURL: settings,
            supportDirectory: supportDir,
            cacheDirectory: root.appendingPathComponent("Caches/seahelm")
        )

        XCTAssertTrue(changed)
        let preserved = try String(contentsOf: supportDir.appendingPathComponent("claude-statusline-original-command"), encoding: .utf8)
        XCTAssertEqual(preserved, "claude-hud")
        let data = try Data(contentsOf: settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try XCTUnwrap(json["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertTrue((statusLine["command"] as? String)?.contains("claude-statusline-bridge.sh") == true)
    }

    func testInstalledCommandWithSpacesPreservesExactInputBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = root.appendingPathComponent(".claude")
        let supportDir = root.appendingPathComponent("Application Support/seahelm")
        let cacheDir = root.appendingPathComponent("Caches/seahelm cache")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalOutput = root.appendingPathComponent("original output.json")
        let settings = claudeDir.appendingPathComponent("settings.json")
        try """
        {"statusLine":{"type":"command","command":"/bin/cat > \(Self.shellQuote(originalOutput.path))"}}
        """.write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertTrue(ClaudeStatuslineBridgeInstaller.ensureInstalledForTests(
            settingsURL: settings,
            supportDirectory: supportDir,
            cacheDirectory: cacheDir
        ))

        let data = try Data(contentsOf: settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let statusLine = try XCTUnwrap(json["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":19}}}"#.utf8) + Data([0x0A])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]
        let stdin = Pipe()
        process.standardInput = stdin

        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: cacheDir.appendingPathComponent("claude-statusline.json")), input)
        XCTAssertEqual(try Data(contentsOf: originalOutput), input)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
