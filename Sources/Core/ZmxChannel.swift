import Foundation

/// Fallback channel: communicates with any agent via zmx commands.
/// Works with any CLI tool — no agent-side support needed.
class ZmxChannel: SailorChannel {
    let channelType: SailorChannelType = .zmx
    let paneSessionKey: String

    init(paneSessionKey: String) {
        self.paneSessionKey = paneSessionKey
    }

    /// Send a text command via zmx run.
    func sendCommand(_ command: String) {
        let args = [ZmxLocator.executable(), "run", paneSessionKey, command]
        runZmx(args)
    }

    /// Read the last N lines of terminal output via zmx history.
    func readOutput(lines: Int = 50) -> String? {
        let args = [ZmxLocator.executable(), "history", paneSessionKey]
        guard let output = runZmxWithOutput(args) else {
            return nil
        }
        guard lines > 0 else {
            return output
        }
        return Self.tailLines(output, count: lines)
    }

    /// Types a prompt into the session and submits it, bypassing the on-screen
    /// surface entirely.
    ///
    /// A pane whose tab is not open has no attached surface, and a write to one
    /// is dropped while still reporting success. Everything reaching a pane from
    /// off the desktop — mail above all — therefore has to go to the session,
    /// which is there whether or not anyone is looking at it.
    ///
    /// The Return is a second write on purpose: an agent TUI treats a `\r` that
    /// arrives in the same burst as the pasted text as a literal newline rather
    /// than a submit, so the prompt would sit in the composer forever. Same
    /// reasoning as `ShipLog.sendCommand`.
    func sendPrompt(_ text: String) -> Bool {
        guard !text.isEmpty, sendRaw(text) else { return false }
        Thread.sleep(forTimeInterval: Station.enterSubmitDelay)
        return submit()
    }

    /// Raw input to the session's PTY, submitting nothing. Arrow keys and other
    /// escape sequences go through here.
    func sendRaw(_ text: String) -> Bool {
        guard !paneSessionKey.isEmpty, !text.isEmpty else { return false }
        return runZmxChecked([ZmxLocator.executable(), "send", paneSessionKey, text])
    }

    /// The Return, always as a write of its own — see `sendPrompt`.
    func submit() -> Bool {
        guard !paneSessionKey.isEmpty else { return false }
        return runZmxChecked([ZmxLocator.executable(), "send", paneSessionKey, "\r"])
    }

    private func runZmxChecked(_ args: [String]) -> Bool {
        ProcessRunner.capture(executable: URL(fileURLWithPath: "/usr/bin/env"),
                              arguments: args, timeout: Self.commandTimeout).succeeded
    }

    /// The session's own scrollback, stripped of the escape sequences a TUI
    /// paints itself with. Reads the persistent session rather than the surface,
    /// so it works for a pane whose tab was never opened.
    func recentTranscript(lines: Int) -> String? {
        guard let raw = readOutput(lines: lines) else { return nil }
        return Self.stripTerminalControl(raw)
    }

    /// Enough of an ANSI/OSC scrub to make a transcript readable in a mail.
    static func stripTerminalControl(_ text: String) -> String {
        var out = text
        // `\#u{…}` rather than `\u{…}`: a raw string leaves escapes uninterpreted,
        // so the plain form would look for a literal backslash-u.
        for pattern in [#"\#u{1B}\][^\#u{07}\#u{1B}]*(?:\#u{07}|\#u{1B}\\)"#,   // OSC …BEL/ST
                        #"\#u{1B}\[[0-9;?]*[ -/]*[@-~]"#,                        // CSI
                        #"\#u{1B}[@-Z\\-_]"#,                                    // lone escapes
                        #"[\#u{00}-\#u{08}\#u{0B}\#u{0C}\#u{0E}-\#u{1F}]"#] {    // stray control bytes
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isChrome($0) }
            .joined(separator: "\n")
    }

    /// Furniture an agent TUI repaints around the conversation — rules, meters,
    /// the prompt caret, permission banners. Reading a transcript in a mail is
    /// about what was said, and left in, the chrome outweighs it.
    private static func isChrome(_ line: String) -> Bool {
        // Box-drawing rules are pure decoration once the colours are gone.
        if let first = line.first, "─━═│┃╭╮╰╯├┤┌┐└┘".contains(first) { return true }
        // Meters and progress bars.
        if line.contains("█") || line.contains("░") || line.contains("▓") { return true }
        if line == "❯" || line == ">" || line == "⏺" { return true }
        for marker in ["⏵⏵", "✻ Churned", "⚠ Transcript saving",
                       // Seahelm's own control line, which is an instruction to
                       // the agent rather than anything it said.
                       "::seahelm-suggest::"] where line.contains(marker) {
            return true
        }
        return false
    }

    /// Deadline for one zmx call. zmx talks to a local socket, so anything past
    /// this means the session is wedged, not slow.
    static let commandTimeout: TimeInterval = 15
    /// `zmx history` can be huge; we only need the latest viewport-ish slice for
    /// status detection. Keeping this small prevents transient polling spikes
    /// from retaining tens of MB per pane.
    static let historyCaptureLimit = 256 * 1024

    private func runZmx(_ args: [String]) {
        // Output already goes to /dev/null, so there is no pipe to fill — but
        // still bound the wait so a wedged zmx can't park the caller's thread.
        ProcessRunner.runSync(args, timeout: Self.commandTimeout)
    }

    /// `zmx history` dumps a pane's entire scrollback — hundreds of KB is normal
    /// — so this must never read the pipe only after the child exits.
    private func runZmxWithOutput(_ args: [String]) -> String? {
        let result = ProcessRunner.capture(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: args,
            timeout: Self.commandTimeout,
            maxCapturedBytes: Self.historyCaptureLimit
        )
        if result.timedOut {
            NSLog("[ZmxChannel] Timed out reading: \(args.joined(separator: " "))")
            return nil
        }
        return result.stdout.isEmpty ? nil : result.stdout
    }

    /// Keep the last N lines without splitting the whole transcript into an
    /// intermediate array.
    private static func tailLines(_ text: String, count: Int) -> String {
        guard count > 0, !text.isEmpty else { return "" }
        var idx = text.endIndex
        var newlinesSeen = 0
        while idx > text.startIndex {
            idx = text.index(before: idx)
            if text[idx] == "\n" {
                newlinesSeen += 1
                if newlinesSeen == count {
                    return String(text[text.index(after: idx)...])
                }
            }
        }
        return text
    }
}
