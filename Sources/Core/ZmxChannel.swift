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
        let allLines = output.components(separatedBy: "\n")
        if allLines.count <= lines {
            return output
        }
        return allLines.suffix(lines).joined(separator: "\n")
    }

    /// Deadline for one zmx call. zmx talks to a local socket, so anything past
    /// this means the session is wedged, not slow.
    static let commandTimeout: TimeInterval = 15

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
            timeout: Self.commandTimeout
        )
        if result.timedOut {
            NSLog("[ZmxChannel] Timed out reading: \(args.joined(separator: " "))")
            return nil
        }
        return result.stdout.isEmpty ? nil : result.stdout
    }
}
