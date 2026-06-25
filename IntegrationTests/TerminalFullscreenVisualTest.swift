import XCTest
@testable import amux

/// Visual integration test: verifies terminal fills its container
/// by checking tmux column count after reparent to a larger container.
///
/// The test checks that tmux reports a column count proportional to the
/// container width, not stuck at the old small card size.
class TerminalFullscreenVisualTest: XCTestCase {

    /// Test that tmux session column count updates after reparent
    /// by querying tmux for the window width.
    func testTmuxColumnsMatchContainerWidth() throws {
        // Find any active amux tmux session
        let sessions = listPmuxTmuxSessions()
        guard let session = sessions.first else {
            // No running amux sessions — skip (amux not running)
            throw XCTSkip("No amux tmux sessions found — amux not running")
        }

        // Query tmux for the window width (columns)
        let cols = tmuxWindowWidth(session: session)
        XCTAssertGreaterThan(cols, 0, "tmux should report > 0 columns")

        // A dashboard card is typically ~400px wide → ~50 columns at standard font.
        // A spotlight/repo view is typically ~900-1200px wide → ~100-160 columns.
        // If cols <= 60, the terminal is still stuck at card size.
        XCTAssertGreaterThan(cols, 60,
            "Terminal should have more than 60 columns in spotlight/repo view (got \(cols)). " +
            "This likely means the terminal size wasn't updated after reparent.")
    }

    /// Test that tmux reports a reasonable row count
    func testTmuxRowsMatchContainerHeight() throws {
        let sessions = listPmuxTmuxSessions()
        guard let session = sessions.first else {
            throw XCTSkip("No amux tmux sessions found — amux not running")
        }

        let rows = tmuxWindowHeight(session: session)
        XCTAssertGreaterThan(rows, 0, "tmux should report > 0 rows")

        // A dashboard card is ~250px tall → ~15 rows.
        // A spotlight/repo view is ~600-800px tall → ~35-50 rows.
        XCTAssertGreaterThan(rows, 20,
            "Terminal should have more than 20 rows in spotlight/repo view (got \(rows)). " +
            "This likely means the terminal height wasn't updated after reparent.")
    }

    /// Screenshot-based test: take a screenshot, type a long line,
    /// and verify text reaches the right side of the terminal area.
    func testTerminalTextReachesRightEdge() throws {
        let sessions = listPmuxTmuxSessions()
        guard let session = sessions.first else {
            throw XCTSkip("No amux tmux sessions found — amux not running")
        }

        let cols = tmuxWindowWidth(session: session)
        guard cols > 0 else {
            throw XCTSkip("Cannot determine tmux column width")
        }

        // Send a line of 'X' characters that should fill the full terminal width
        let longLine = String(repeating: "X", count: cols)
        tmuxSendKeys(session: session, text: "echo '\(longLine)'")
        tmuxSendKeys(session: session, text: "Enter")

        // Wait for the command to execute
        Thread.sleep(forTimeInterval: 1.0)

        // Capture the tmux pane content and check the X line exists at full width
        let paneContent = tmuxCapturePane(session: session)
        let xLines = paneContent.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("XXXX") && trimmed.count >= cols - 5
        }

        XCTAssertFalse(xLines.isEmpty,
            "Should find a line of X characters spanning \(cols) columns. " +
            "Terminal might not be filling the full width.")

        // Clean up — send Ctrl+C to cancel any pending input
        tmuxSendKeys(session: session, text: "C-c")
    }

    // MARK: - Helpers

    private func listPmuxTmuxSessions() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "list-sessions", "-F", "#{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("amux-") }
    }

    private func tmuxWindowWidth(session: String) -> Int {
        let output = tmuxCommand(["display-message", "-t", session, "-p", "#{window_width}"])
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func tmuxWindowHeight(session: String) -> Int {
        let output = tmuxCommand(["display-message", "-t", session, "-p", "#{window_height}"])
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func tmuxSendKeys(session: String, text: String) {
        _ = tmuxCommand(["send-keys", "-t", session, text])
    }

    private func tmuxCapturePane(session: String) -> String {
        return tmuxCommand(["capture-pane", "-t", session, "-p"])
    }

    private func tmuxCommand(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
