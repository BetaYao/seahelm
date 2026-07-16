import XCTest
@testable import seahelm

final class SeahelmHookInstallerTests: XCTestCase {
    func testScriptShape() {
        let s = SeahelmHookInstaller.scriptContents()
        XCTAssertTrue(s.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(s.contains("seahelm-hook v4"))
        XCTAssertTrue(s.contains("nc -U \"$sock\""))     // control socket (Apple-nc compatible)
        XCTAssertTrue(s.contains("block_b64"))           // block extraction
        XCTAssertTrue(s.contains("base64 -d"))
        XCTAssertFalse(s.contains("/webhook"))           // HTTP fallback removed
        XCTAssertFalse(s.contains("curl"))
        XCTAssertTrue(s.contains("\"method\":\"hook\""))
        XCTAssertTrue(s.contains("seahelm_pane_id"))     // pane id injected
        XCTAssertTrue(s.contains("SEAHELM_PANE_ID"))
    }

    func testScriptIsValidSh() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-hook-syn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try SeahelmHookInstaller.scriptContents().write(to: tmp, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", tmp.path]   // syntax check only
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0, "sh syntax error:\n\(msg)")
    }

    func testInstallWritesExecutable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-hook-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertTrue(SeahelmHookInstaller.ensureInstalled(binDirectory: tmp))
        let path = tmp.appendingPathComponent("seahelm-hook").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111, 0o111)
        XCTAssertFalse(SeahelmHookInstaller.ensureInstalled(binDirectory: tmp)) // idempotent
    }
}

final class ClaudeHooksMigrationTests: XCTestCase {
    func testIsSeahelmManaged() {
        let httpEntry: [[String: Any]] = [["hooks": [["type": "http", "url": "http://localhost:7070/webhook"]]]]
        let cmdEntry: [[String: Any]] = [["hooks": [["type": "command", "command": "/x/seahelm-hook"]]]]
        let userEntry: [[String: Any]] = [["hooks": [["type": "command", "command": "/usr/bin/my-linter"]]]]
        XCTAssertTrue(ClaudeHooksSetup.isSeahelmManaged(httpEntry))
        XCTAssertTrue(ClaudeHooksSetup.isSeahelmManaged(cmdEntry))
        XCTAssertFalse(ClaudeHooksSetup.isSeahelmManaged(userEntry))
        XCTAssertFalse(ClaudeHooksSetup.isSeahelmManaged(nil))
    }

    func testEntriesEqualCanonical() {
        let a: [String: Any] = ["type": "command", "command": "/x", "extra": 1]
        let b: [String: Any] = ["command": "/x", "extra": 1, "type": "command"]  // reordered
        XCTAssertTrue(ClaudeHooksSetup.entriesEqual(a, b))
        XCTAssertFalse(ClaudeHooksSetup.entriesEqual(a, ["type": "http"]))
    }
}
