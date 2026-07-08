import Foundation

/// Fallback channel: communicates with any agent via zmx commands.
/// Works with any CLI tool — no agent-side support needed.
class ZmxChannel: SailorChannel {
    let channelType: SailorChannelType = .zmx
    let sessionName: String

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    /// Send a text command via zmx run.
    func sendCommand(_ command: String) {
        let args = [ZmxLocator.executable(), "run", sessionName, command]
        runZmx(args)
    }

    /// Read the last N lines of terminal output via zmx history.
    func readOutput(lines: Int = 50) -> String? {
        let args = [ZmxLocator.executable(), "history", sessionName]
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
