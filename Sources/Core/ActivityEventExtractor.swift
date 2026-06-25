import Foundation

enum ActivityEventExtractor {

    static func extract(from event: WebhookEvent) -> ActivityEvent {
        let toolName = event.data?["tool_name"] as? String ?? "Unknown"
        let toolInput = event.data?["tool_input"] as? [String: Any] ?? [:]
        let toolResult = event.data?["tool_result"] as? String

        let detail = extractDetail(toolName: toolName, toolInput: toolInput)
        let isError = detectError(event: event, toolName: toolName, toolResult: toolResult)

        return ActivityEvent(
            tool: toolName,
            detail: detail,
            isError: isError,
            timestamp: Date()
        )
    }

    static func summary(toolName: String, toolInput: [String: Any], isError: Bool = false) -> String {
        let detail = extractDetail(toolName: toolName, toolInput: toolInput)
        let base = detail == toolName ? toolName : "\(toolName) \(detail)"
        return isError ? "Failed \(base)" : base
    }

    static func shortPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents.filter { $0 != "/" }
        if components.count <= 2 {
            return components.joined(separator: "/")
        }
        return components.suffix(2).joined(separator: "/")
    }

    private static func extractDetail(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Read", "Write":
            if let path = toolInput["file_path"] as? String {
                return shortPath(path)
            }
            return toolName
        case "Edit":
            if let path = toolInput["file_path"] as? String {
                return shortPath(path)
            }
            return toolName
        case "MultiEdit":
            if let path = toolInput["file_path"] as? String {
                return shortPath(path)
            }
            return toolName
        case "Bash":
            if let cmd = toolInput["command"] as? String {
                return truncate(cmd, maxLen: 60)
            }
            return toolName
        case "Grep":
            if let pattern = toolInput["pattern"] as? String {
                return "\"\(pattern)\""
            }
            return toolName
        case "Glob":
            if let pattern = toolInput["pattern"] as? String {
                return pattern
            }
            return toolName
        case "Agent":
            if let prompt = toolInput["prompt"] as? String {
                return truncate(prompt, maxLen: 40)
            }
            return toolName
        case "Task":
            if let description = toolInput["description"] as? String {
                return truncate(description, maxLen: 40)
            }
            if let prompt = toolInput["prompt"] as? String {
                return truncate(prompt, maxLen: 40)
            }
            return toolName
        case "WebSearch":
            if let query = toolInput["query"] as? String {
                return "\"\(truncate(query, maxLen: 40))\""
            }
            return toolName
        case "WebFetch":
            if let url = toolInput["url"] as? String {
                return truncate(url, maxLen: 60)
            }
            return toolName
        default:
            return toolName
        }
    }

    private static func detectError(event: WebhookEvent, toolName: String, toolResult: String?) -> Bool {
        if event.event == .toolUseFailed {
            return true
        }
        if toolName == "Bash", let result = toolResult {
            if let range = result.range(of: "Exit code: ", options: .caseInsensitive) {
                let afterPrefix = result[range.upperBound...]
                let codeStr = afterPrefix.prefix(while: { $0.isNumber })
                if let code = Int(codeStr), code != 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func truncate(_ str: String, maxLen: Int) -> String {
        if str.count <= maxLen { return str }
        return String(str.prefix(maxLen)) + "..."
    }
}
