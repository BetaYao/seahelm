import Foundation

enum CodexSessionPromptLookup {
    static func lastUserPrompt(
        sessionId: String,
        fileManager: FileManager = .default,
        sessionsRoot: URL = defaultSessionsRoot()
    ) -> String? {
        guard !sessionId.isEmpty else { return nil }
        guard let sessionFileURL = sessionFileURL(
            sessionId: sessionId,
            fileManager: fileManager,
            sessionsRoot: sessionsRoot
        ) else {
            return nil
        }

        guard let contents = try? String(contentsOf: sessionFileURL, encoding: .utf8) else {
            return nil
        }

        var lastPrompt: String?
        contents.enumerateLines { line, _ in
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "event_msg",
                let payload = object["payload"] as? [String: Any],
                payload["type"] as? String == "user_message",
                let message = payload["message"] as? String,
                !message.isEmpty
            else {
                return
            }

            lastPrompt = message
        }

        return lastPrompt
    }

    private static func sessionFileURL(
        sessionId: String,
        fileManager: FileManager,
        sessionsRoot: URL
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard fileURL.lastPathComponent.contains(sessionId) else { continue }
            return fileURL
        }

        return nil
    }

    private static func defaultSessionsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }
}
