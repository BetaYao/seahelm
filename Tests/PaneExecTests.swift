import XCTest
@testable import seahelm

final class PaneExecTests: XCTestCase {
    // MARK: Output

    func testOutputIsBetweenTheEchoAndTheNextPrompt() {
        let history = """
        ➜  repo git:(main) ls
        a.txt
        ➜  repo git:(main) make test
        building
        3 passed
        ➜  repo git:(main) ✗

        """
        let out = PaneExecOutput.extract(history: history, command: "make test", promptLines: 1)
        XCTAssertEqual(out.text, "building\n3 passed")
        XCTAssertFalse(out.truncated)
    }

    func testMultiLinePromptAndCommand() {
        let history = """
        ~/repo on main
        ❯ printf 'a\\n'
        printf 'b\\n'
        a
        b

        ~/repo on main
        ❯
        """
        // A two-line prompt that starts with a blank line, and a two-line command.
        let out = PaneExecOutput.extract(history: history, command: "printf 'a\\n'\nprintf 'b\\n'", promptLines: 3)
        XCTAssertEqual(out.text, "a\nb")
    }

    /// A command wider than the terminal is soft-wrapped in the scrollback.
    func testWrappedEcho() {
        let history = """
        ➜  seahelm git:(main) ✗ sh -c 'echo out; echo err >&2; exi
        t 3'
        out
        err
        ➜  seahelm git:(main) ✗
        """
        let out = PaneExecOutput.extract(history: history, command: "sh -c 'echo out; echo err >&2; exit 3'",
                                         promptLines: 1)
        XCTAssertEqual(out.text, "out\nerr")
        XCTAssertFalse(out.truncated)
    }

    func testNoOutput() {
        let out = PaneExecOutput.extract(history: "➜ true\n➜ ", command: "true", promptLines: 1)
        XCTAssertEqual(out.text, "")
        XCTAssertFalse(out.truncated)
    }

    func testScrolledPastTheEchoIsTruncated() {
        let out = PaneExecOutput.extract(history: "line 998\nline 999\n➜ ", command: "seq 999", promptLines: 1)
        XCTAssertEqual(out.text, "line 998\nline 999")
        XCTAssertTrue(out.truncated)
    }

    // MARK: Spool

    func testSpoolRecordsParse() {
        XCTAssertEqual(ShellRunIntegration.parsePrompt("12 3\n")?.sequence, 12)
        XCTAssertEqual(ShellRunIntegration.parsePrompt("12 3\n")?.status, 3)
        XCTAssertNil(ShellRunIntegration.parsePrompt(""), "an empty file is a half-written one")
        XCTAssertNil(ShellRunIntegration.parsePrompt("12"))
        XCTAssertEqual(ShellRunIntegration.parseClaim("7 2")?.promptLines, 2)
        XCTAssertEqual(ShellRunIntegration.spoolFile(.prompt, session: "s1", in: URL(fileURLWithPath: "/r")).path,
                       "/r/s1.prompt")
    }

    // MARK: Install

    func testInstallWritesValidZshAndAPrivateSpool() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sh-exec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let zsh = try XCTUnwrap(ShellRunIntegration.ensureInstalled(base: base))
        let mode = try FileManager.default.attributesOfItem(
            atPath: base.appendingPathComponent("run").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        for name in [".zshenv", "seahelm-run.zsh"] {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/zsh")
            check.arguments = ["-n", zsh.appendingPathComponent(name).path]
            try check.run()
            check.waitUntilExit()
            XCTAssertEqual(check.terminationStatus, 0, "\(name) must parse")
        }
        XCTAssertTrue(ShellRunIntegration.runScript.contains(#"$'\e[9013~'"#),
                      "the script binds the key the app presses")
        XCTAssertEqual(ShellRunIntegration.triggerSequence, "\u{1b}[9013~")
    }

    /// Codex typed in a pane runs off its shared daemon, once: a second
    /// `--no-daemon` is a usage error, and the daemon's own commands pass as typed.
    func testCodexTypedInAPaneSkipsTheSharedDaemon() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sh-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let zsh = try XCTUnwrap(ShellRunIntegration.ensureInstalled(base: base))
        let bin = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nprintf '%s|' \"$@\"; echo\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let script = zsh.appendingPathComponent("seahelm-run.zsh").path
        shell.arguments = ["-fic", "source \(script); codex; codex 'fix it'; codex resume --no-daemon x; codex app-server daemon stop"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin"
        env["SEAHELM_PANE_ID"] = "test-pane"
        env["SEAHELM_RUN_DIR"] = base.appendingPathComponent("run").path
        shell.environment = env
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["--no-daemon|", "--no-daemon|fix it|", "resume|--no-daemon|x|", "app-server|daemon|stop|"])
    }

    // MARK: Router

    func testRouterValidatesExecParams() {
        let router = ControlRouter(dataSource: nil)
        for params: [String: Any] in [["command": "ls"], ["pane_id": "p1"], ["pane_id": "p1", "command": "  "],
                                      ["pane_id": "p1", "command": "a\0b"]] {
            guard case .error(let code, _) = router.handle(method: "pane.exec", params: params) else {
                return XCTFail("\(params) should be rejected")
            }
            XCTAssertEqual(code, ControlError.invalidParams)
        }
        guard case .error(_, let message) = router.handle(method: "pane.exec",
                                                         params: ["pane_id": "p1", "command": "ls"]) else {
            return XCTFail("no data source")
        }
        XCTAssertEqual(message, PaneExecError.unavailable.message)
    }
}
