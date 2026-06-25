import Foundation

struct ParsedCommand {
    let command: String
    let args: String
    let rawMessage: InboundMessage
}

enum CommandParser {
    /// Parse a slash command from an inbound message.
    /// "/idea 做一个登录页" → ParsedCommand(command: "idea", args: "做一个登录页")
    /// "hello" → nil (not a command)
    static func parse(_ message: InboundMessage) -> ParsedCommand? {
        let trimmed = message.content.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }

        let withoutSlash = String(trimmed.dropFirst())
        guard !withoutSlash.isEmpty else { return nil }

        let parts = withoutSlash.split(separator: " ", maxSplits: 1)
        let command = String(parts[0]).lowercased()
        let args = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""

        return ParsedCommand(command: command, args: args, rawMessage: message)
    }
}
