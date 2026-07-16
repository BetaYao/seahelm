import XCTest
@testable import seahelm

final class SeahelmSuggestInstallerTests: XCTestCase {
    func testScriptContainsPortMarkerAndEndpoint() {
        let script = SeahelmSuggestInstaller.scriptContents()
        XCTAssertTrue(script.contains("seahelm-suggest v4"))          // version marker
        XCTAssertTrue(script.contains("nc -U \"$sock\""))            // control socket (Apple-nc compatible)
        XCTAssertTrue(script.contains("SEAHELM_SOCKET_PATH"))
        XCTAssertTrue(script.contains("SEAHELM_PANE_ID"))            // pane targeting
        XCTAssertTrue(script.contains("\"method\":\"suggest\""))
        XCTAssertFalse(script.contains("/webhook"))                 // HTTP fallback removed
        XCTAssertFalse(script.contains("curl"))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
    }

    /// Panes created before SessionManager exported SEAHELM_PANE_ID still carry
    /// ZMX_SESSION (the same backend session name). Without this fallback such a
    /// pane reports no pane id, the turn correlation keys off the literal "cli"
    /// while the Stop hook keys off Claude's session UUID, and every Stop blocks
    /// for a suggestion that already arrived.
    func testScriptFallsBackToZmxSessionForPaneId() {
        let script = SeahelmSuggestInstaller.scriptContents()
        XCTAssertTrue(script.contains("pane=\"${SEAHELM_PANE_ID:-${ZMX_SESSION:-}}\""))
    }

    /// The suggest and Stop-hook sides must resolve the pane id the SAME way —
    /// if only one of them falls back, they key the turn differently and the
    /// correlation breaks exactly as it did before.
    func testPaneIdFallbackMatchesHookInstaller() {
        let suggest = SeahelmSuggestInstaller.scriptContents()
        let hook = SeahelmHookInstaller.scriptContents()
        let fallback = "${SEAHELM_PANE_ID:-${ZMX_SESSION:-}}"
        XCTAssertTrue(suggest.contains(fallback))
        XCTAssertTrue(hook.contains(fallback))
    }

    func testInstallWritesExecutableScript() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-suggest-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let wrote = SeahelmSuggestInstaller.ensureInstalled(binDirectory: tmp)
        XCTAssertTrue(wrote)

        let scriptPath = tmp.appendingPathComponent("seahelm-suggest").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath))
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o111, 0o111) // executable bits set

        // Idempotent: second run with same version does not rewrite.
        let wroteAgain = SeahelmSuggestInstaller.ensureInstalled(binDirectory: tmp)
        XCTAssertFalse(wroteAgain)
    }
}
