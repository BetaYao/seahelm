import Foundation

/// Outbound half of the iMessage bridge — drives Messages.app over AppleScript.
///
/// There is no send API either, so this is the counterpart to reading chat.db.
/// It needs two things the receive side doesn't:
///   - `NSAppleEventsUsageDescription` in Info.plist and the user's one-time
///     "allow Seahelm to control Messages" approval;
///   - the `com.apple.security.automation.apple-events` entitlement, because
///     release builds are signed with hardened runtime (`--options runtime` in
///     `scripts/package_release.sh`), which otherwise blocks Apple events even
///     after the user approves.
enum IMessageSender {
    enum SendError: LocalizedError {
        case emptyTarget
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyTarget: return "No iMessage recipient"
            case .scriptFailed(let m): return m
            }
        }
    }

    /// Send `text` to a chat GUID (`iMessage;-;+861…`, `iMessage;+;chat42…`) or
    /// a bare handle.
    ///
    /// Chat GUIDs are preferred and tried first: sending to an existing chat is
    /// what keeps a group reply in the group instead of forking a 1:1 thread,
    /// and it survives handles that Messages knows only by chat. `buddy` is the
    /// fallback for the first message to someone we've never received from.
    static func send(_ text: String, to target: String) throws {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw SendError.emptyTarget }

        let body = escape(text)
        let script: String
        if trimmed.contains(";") {
            script = """
            tell application "Messages"
                send "\(body)" to chat id "\(escape(trimmed))"
            end tell
            """
        } else {
            // `buddy` resolves against the iMessage service; a handle that has
            // no iMessage account raises, which surfaces as scriptFailed.
            script = """
            tell application "Messages"
                set svc to 1st account whose service type = iMessage
                send "\(body)" to participant "\(escape(trimmed))" of svc
            end tell
            """
        }

        try run(script)
    }

    // MARK: - Internals

    private static func run(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw SendError.scriptFailed("Could not compile AppleScript")
        }
        script.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            throw SendError.scriptFailed("\(msg) (\(code))")
        }
    }

    /// AppleScript string literals only escape backslash and double quote; a
    /// raw newline is a syntax error, so those become `\n` escapes.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }
}
