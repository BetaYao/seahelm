import XCTest
@testable import seahelm

final class SeahelmHookInstallerTests: XCTestCase {
    func testScriptShape() {
        let s = SeahelmHookInstaller.scriptContents()
        XCTAssertTrue(s.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(s.contains("seahelm-hook v5"))
        XCTAssertTrue(s.contains("nc -U \"$sock\""))     // control socket (Apple-nc compatible)
        XCTAssertTrue(s.contains("block_b64"))           // block extraction
        XCTAssertTrue(s.contains("base64 -d"))
        XCTAssertFalse(s.contains("/webhook"))           // HTTP fallback removed
        XCTAssertFalse(s.contains("curl"))
        XCTAssertTrue(s.contains("\"method\":\"hook\""))
        XCTAssertTrue(s.contains("seahelm_pane_id"))     // pane id injected
        XCTAssertTrue(s.contains("SEAHELM_PANE_ID"))
        XCTAssertTrue(s.contains("seahelm_source"))      // caller identity injected
        XCTAssertTrue(s.contains("src=\"${1:-}\""))
    }

    /// End-to-end over a real control socket: the shipped script must stamp the
    /// source it was invoked with, and omit the tag entirely when invoked without
    /// one (hook configs written by an older seahelm).
    func testScriptStampsSourceOnTheWire() throws {
        final class CapturingDS: ControlDataSource {
            var captured: [[String: Any]] = []
            func snapshotPanes() -> [PaneSnapshot] { [] }
            func readPane(paneId: String, source: String, lines: Int) -> String? { nil }
            func ingestHook(json: [String: Any]) -> String? { captured.append(json); return nil }
        }

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seahelm-hook-src-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("seahelm-hook")
        try SeahelmHookInstaller.scriptContents().write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let sockPath = "/tmp/sh-hook-\(UUID().uuidString.prefix(8)).sock"
        let ds = CapturingDS()
        let server = ControlSocketServer(router: ControlRouter(dataSource: ds), path: sockPath)
        server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.1)   // let the accept loop bind

        func runHook(args: [String]) throws {
            let p = Process()
            p.executableURL = scriptURL
            p.arguments = args
            p.environment = ["SEAHELM_SOCKET_PATH": sockPath, "SEAHELM_PANE_ID": "seahelm-repo-main",
                             "PATH": "/usr/bin:/bin"]
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = Pipe()
            try p.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/wt"}"#.utf8))
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
        }

        try runHook(args: ["claude-code"])
        try runHook(args: [])
        // The server handles each connection on its own thread.
        let deadline = Date().addingTimeInterval(2)
        while ds.captured.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }

        XCTAssertEqual(ds.captured.count, 2, "both hook invocations should reach the socket")
        XCTAssertEqual(ds.captured.first?["seahelm_source"] as? String, "claude-code")
        XCTAssertEqual(ds.captured.first?["seahelm_pane_id"] as? String, "seahelm-repo-main")
        XCTAssertNil(ds.captured.last?["seahelm_source"], "untagged call must not emit an empty source")
        XCTAssertEqual(ds.captured.last?["seahelm_pane_id"] as? String, "seahelm-repo-main")
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
