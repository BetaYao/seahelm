import XCTest
@testable import seahelm

final class SeahelmCliInstallerTests: XCTestCase {

    func testScriptIsValidPython() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertTrue(SeahelmCliInstaller.ensureInstalled(binDirectory: tmp))
        let script = tmp.appendingPathComponent("seahelm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))

        // py_compile fails (nonzero) on a syntax error — catches raw-string /
        // interpolation mistakes in the generated CLI.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-m", "py_compile", script.path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0, "python syntax error:\n\(msg)")
    }

    func testIdempotentReinstall() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertTrue(SeahelmCliInstaller.ensureInstalled(binDirectory: tmp))
        XCTAssertFalse(SeahelmCliInstaller.ensureInstalled(binDirectory: tmp)) // no rewrite
    }

    func testScriptMentionsSocketEnvAndMethods() {
        let s = SeahelmCliInstaller.scriptContents()
        XCTAssertTrue(s.contains("SEAHELM_SOCKET_PATH"))
        for method in ["session.snapshot", "pane.read", "pane.run", "pane.send_text",
                       "pane.send_keys", "pane.split", "wait.output", "wait.agent_status"] {
            XCTAssertTrue(s.contains(method), "CLI missing method \(method)")
        }
    }
}
