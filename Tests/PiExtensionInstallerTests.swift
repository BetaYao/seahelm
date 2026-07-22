import XCTest
@testable import seahelm

final class PiExtensionInstallerTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-pi-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return tmp
    }

    private func settings(_ agentDir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: PiExtensionInstaller.settingsURL(agentDir: agentDir))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallsExtensionAndRegistersInSettings() throws {
        let dir = try makeTempDir()
        XCTAssertTrue(PiExtensionInstaller.ensureInstalled(agentDir: dir))

        let ext = PiExtensionInstaller.extensionFileURL(agentDir: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ext.path))
        let js = try String(contentsOf: ext, encoding: .utf8)
        XCTAssertTrue(js.contains("agent_settled"))         // idle signal wired
        XCTAssertTrue(js.contains("export default function seahelm"))

        let exts = try XCTUnwrap(settings(dir)["extensions"] as? [String])
        XCTAssertEqual(exts, [ext.path])

        // Idempotent: a second run changes nothing.
        XCTAssertFalse(PiExtensionInstaller.ensureInstalled(agentDir: dir))
    }

    func testPreservesExistingSettingsKeysAndExtensions() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = ["model": "gpt-5", "extensions": ["/home/me/.pi/agent/extensions/mine.js"]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: existing)
        try data.write(to: PiExtensionInstaller.settingsURL(agentDir: dir))

        XCTAssertTrue(PiExtensionInstaller.ensureInstalled(agentDir: dir))

        let s = try settings(dir)
        XCTAssertEqual(s["model"] as? String, "gpt-5")       // untouched
        let exts = try XCTUnwrap(s["extensions"] as? [String])
        XCTAssertTrue(exts.contains("/home/me/.pi/agent/extensions/mine.js"))  // user entry kept
        XCTAssertEqual(exts.count, 2)                         // ours appended, once
    }

    func testDoesNotClobberUnparseableSettings() throws {
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = "{ this is not valid json, // with a comment\n}"
        try raw.write(to: PiExtensionInstaller.settingsURL(agentDir: dir), atomically: true, encoding: .utf8)

        // The extension file still installs, but the malformed settings are left as-is.
        _ = PiExtensionInstaller.ensureInstalled(agentDir: dir)
        XCTAssertEqual(try String(contentsOf: PiExtensionInstaller.settingsURL(agentDir: dir), encoding: .utf8), raw)
    }

    func testLeavesForeignExtensionFileAlone() throws {
        let dir = try makeTempDir()
        let ext = PiExtensionInstaller.extensionFileURL(agentDir: dir)
        try FileManager.default.createDirectory(at: ext.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = "export default function notOurs() {}\n"
        try foreign.write(to: ext, atomically: true, encoding: .utf8)

        _ = PiExtensionInstaller.ensureInstalled(agentDir: dir)
        XCTAssertEqual(try String(contentsOf: ext, encoding: .utf8), foreign)
    }
}
