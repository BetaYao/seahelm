import AppKit

enum AgentStatus: String, Codable {
    case running = "Running"
    case idle = "Idle"
    case waiting = "Waiting"
    case error = "Error"
    case exited = "Exited"
    case unknown = "Unknown"

    var color: NSColor {
        switch self {
        case .running:  return SemanticColors.running
        case .idle:     return SemanticColors.idle
        case .waiting:  return SemanticColors.waiting
        case .error:    return SemanticColors.danger
        case .exited:   return SemanticColors.idle
        case .unknown:  return SemanticColors.subtle
        }
    }

    var icon: String {
        switch self {
        case .running:  return "●"
        case .idle:     return "○"
        case .waiting:  return "◐"
        case .error:    return "✕"
        case .exited:   return "◻"
        case .unknown:  return "?"
        }
    }
}
