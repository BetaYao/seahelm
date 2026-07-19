import XCTest
@testable import seahelm

final class CursorHooksSetupTests: XCTestCase {

    func testEnsureHooksJSONAddsRequiredEventsAndVersion() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")

        XCTAssertTrue(CursorHooksSetup.ensureHooksJSONForTests(at: url))

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        for event in ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "stop"] {
            let list = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing \(event)")
            let command = try XCTUnwrap(list.first?["command"] as? String)
            XCTAssertEqual(command, SeahelmHookInstaller.scriptPath())
        }
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["loop_limit"] as? Int, 5)
    }

    func testPreservesUserOwnedHooksAndAppendsSeahelm() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "hooks": [
                "stop": [["command": "./hooks/my-audit.sh"]],
            ],
        ]).write(to: url)

        XCTAssertTrue(CursorHooksSetup.ensureHooksJSONForTests(at: url))

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(stop[0]["command"] as? String, "./hooks/my-audit.sh")
        XCTAssertTrue((stop[1]["command"] as? String)?.contains("seahelm-hook") == true)
    }

    func testUpgradesStaleSeahelmOwnedCommand() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "hooks": [
                "stop": [["command": "/old/path/seahelm-hook"]],
            ],
        ]).write(to: url)

        XCTAssertTrue(CursorHooksSetup.ensureHooksJSONForTests(at: url))

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop.first?["command"] as? String, SeahelmHookInstaller.scriptPath())
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
