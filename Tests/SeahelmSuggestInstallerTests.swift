import XCTest
@testable import seahelm

final class SeahelmSuggestInstallerTests: XCTestCase {
    func testScriptContainsPortMarkerAndEndpoint() {
        let script = SeahelmSuggestInstaller.scriptContents(port: 7070)
        XCTAssertTrue(script.contains("seahelm-suggest v2"))          // version marker
        XCTAssertTrue(script.contains("SEAHELM_WEBHOOK_PORT:-7070"))   // default port w/ override
        XCTAssertTrue(script.contains("/webhook"))                     // HTTP fallback retained
        XCTAssertTrue(script.contains("nc -U \"$sock\""))              // prefers the control socket (Apple-nc compatible)
        XCTAssertTrue(script.contains("SEAHELM_SOCKET_PATH"))
        XCTAssertTrue(script.contains("SEAHELM_PANE_ID"))              // pane targeting
        XCTAssertTrue(script.contains("\"method\":\"suggest\""))
        XCTAssertTrue(script.contains("\"event\":\"suggest\""))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
    }

    func testInstallWritesExecutableScript() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-suggest-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wrote = SeahelmSuggestInstaller.ensureInstalled(binDirectory: tmp, port: 7070)
        XCTAssertTrue(wrote)

        let scriptPath = tmp.appendingPathComponent("seahelm-suggest").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o111, 0o111) // executable bits set

        // Idempotent: second run with same version does not rewrite.
        let wroteAgain = SeahelmSuggestInstaller.ensureInstalled(binDirectory: tmp, port: 7070)
        XCTAssertFalse(wroteAgain)
    }
}
