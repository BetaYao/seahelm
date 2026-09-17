import Foundation

struct MessageConfig: Equatable {
    var assistantFrom: String = "stop_last_assistant_message"
    var userFields: [String] = ["prompt", "message"]
    var toolDetailKeys: [String: [String]] = [:]
    var toolAliases: [String: String] = [:]
    var coalesceTools: Bool = true
    var screenFallback: Bool = false

    static let `default` = MessageConfig()

    enum CodingKeys: String, CodingKey {
        case assistantFrom = "assistant_from"
        case userFields = "user_fields"
        case toolDetailKeys = "tool_detail_keys"
        case toolAliases = "tool_aliases"
        case coalesceTools = "coalesce_tools"
        case screenFallback = "screen_fallback"
    }
}

extension MessageConfig: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assistantFrom = try c.decodeIfPresent(String.self, forKey: .assistantFrom)
            ?? Self.default.assistantFrom
        userFields = try c.decodeIfPresent([String].self, forKey: .userFields)
            ?? Self.default.userFields
        toolDetailKeys = try c.decodeIfPresent([String: [String]].self, forKey: .toolDetailKeys)
            ?? [:]
        toolAliases = try c.decodeIfPresent([String: String].self, forKey: .toolAliases) ?? [:]
        coalesceTools = try c.decodeIfPresent(Bool.self, forKey: .coalesceTools) ?? true
        screenFallback = try c.decodeIfPresent(Bool.self, forKey: .screenFallback) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assistantFrom, forKey: .assistantFrom)
        try c.encode(userFields, forKey: .userFields)
        try c.encode(toolDetailKeys, forKey: .toolDetailKeys)
        try c.encode(toolAliases, forKey: .toolAliases)
        try c.encode(coalesceTools, forKey: .coalesceTools)
        try c.encode(screenFallback, forKey: .screenFallback)
    }
}
