import AppKit

enum SailorStatus: String, Codable {
    case running = "Running"
    case idle = "Idle"
    case waiting = "Waiting"
    case error = "Error"
    case exited = "Exited"
    case unknown = "Unknown"

    /// Single source of truth for the status dot's colour — used by the
    /// dashboard worktree card and the "group by status" headers alike.
    var color: NSColor {
        switch self {
        case .running:  return SemanticColors.running
        case .waiting:  return SemanticColors.attention
        case .idle:     return SemanticColors.idle
        case .error:    return SemanticColors.danger
        case .exited:   return SemanticColors.idle
        case .unknown:  return SemanticColors.subtle
        }
    }

    /// Dot glyph. `running` is drawn as a spinning arc by `SpinnerDotView`;
    /// this glyph is its static fallback (and what the group header shows).
    var glyph: String {
        switch self {
        case .running:  return "◐"
        case .waiting:  return "●"
        case .idle:     return "○"
        case .error:    return "✕"
        case .exited:   return "◌"
        case .unknown:  return "◌"
        }
    }

    /// Text glyph for notifications, the island, and ShipLog markdown — plain
    /// characters that read well inline (distinct from the dashboard `glyph`).
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

    /// Human label for the "group by status" section headers.
    var groupLabel: String {
        switch self {
        case .running:  return "Running"
        case .waiting:  return "Needs input"
        case .idle:     return "Idle"
        case .error:    return "Error"
        case .exited:   return "Dormant"
        case .unknown:  return "Unknown"
        }
    }
}
