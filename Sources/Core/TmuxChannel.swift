import Foundation

/// Fallback channel: communicates with any agent via tmux commands.
/// Works with any CLI tool — no agent-side support needed.
class TmuxChannel: AgentChannel {
    let channelType: AgentChannelType = .tmux
    let sessionName: String

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    /// Send a text command by injecting keystrokes into the tmux pane
    func sendCommand(_ command: String) {
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        let args = ["tmux", "send-keys", "-t", sessionName, escaped, "Enter"]
        runTmux(args)
    }

    /// Read the last N lines of terminal output via tmux capture-pane
    func readOutput(lines: Int = 50) -> String? {
        let startLine = -(lines - 1)
        let args = ["tmux", "capture-pane", "-t", sessionName, "-p",
                     "-S", String(startLine), "-E", "-1"]
        return runTmuxWithOutput(args)
    }

    // MARK: - Private

    private func runTmux(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[TmuxChannel] Failed to run: \(args.joined(separator: " ")): \(error)")
        }
    }

    private func runTmuxWithOutput(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return output?.isEmpty == true ? nil : output
        } catch {
            NSLog("[TmuxChannel] Failed to read: \(args.joined(separator: " ")): \(error)")
            return nil
        }
    }
}

/// Fallback channel: communicates with any agent via zmx commands.
/// Works with any CLI tool — no agent-side support needed.
class ZmxChannel: AgentChannel {
    let channelType: AgentChannelType = .zmx
    let sessionName: String

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    /// Send a text command via zmx run.
    func sendCommand(_ command: String) {
        let args = ["zmx", "run", sessionName, command]
        runZmx(args)
    }

    /// Read the last N lines of terminal output via zmx history.
    func readOutput(lines: Int = 50) -> String? {
        let args = ["zmx", "history", sessionName]
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

    private func runZmx(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("[ZmxChannel] Failed to run: \(args.joined(separator: " ")): \(error)")
        }
    }

    private func runZmxWithOutput(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return output?.isEmpty == true ? nil : output
        } catch {
            NSLog("[ZmxChannel] Failed to read: \(args.joined(separator: " ")): \(error)")
            return nil
        }
    }
}
