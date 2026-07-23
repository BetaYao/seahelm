import SwiftUI

/// Sumi 墨 palette + status/agent mapping, ported verbatim from
/// `seahelm-watch-theme.jsx`. Re-toned for a near-black physical dial.
enum Ink {
    static let night = Color(hex: 0x0A0A0C)   // deepest bg
    static let lamp  = Color(hex: 0x221F1B)   // card
    static let lamp2 = Color(hex: 0x2A2621)   // raised card
    static let stone = Color(hex: 0x39342E)   // line / border
    static let ash   = Color(hex: 0x7C7368)   // dim / meta
    static let bone  = Color(hex: 0xEBE5D8)   // text
    static let ember = Color(hex: 0xD86B53)   // focus / selected / the pick
    static let green = Color(hex: 0x6E9159)   // running / done
    static let amber = Color(hex: 0xC6993F)   // waiting on you
    static let red   = Color(hex: 0x9A3B2B)   // failed / error

    static let line = Color.white.opacity(0.06)
}

/// PaneStatus → ring color + zh label + whether it "breathes" (pulsing dot).
struct StatusStyle {
    let color: Color
    let zh: String
    let label: String
    let breathe: Bool

    static func of(_ s: PaneStatus) -> StatusStyle {
        switch s {
        case .running: return .init(color: Ink.green, zh: "运行中", label: "RUNNING", breathe: true)
        case .waiting: return .init(color: Ink.amber, zh: "等你",   label: "WAITING", breathe: true)
        case .done:    return .init(color: Ink.green, zh: "已完成", label: "DONE",    breathe: false)
        case .failed:  return .init(color: Ink.red,   zh: "失败",   label: "FAILED",  breathe: false)
        case .idle:    return .init(color: Ink.ash,   zh: "空闲",   label: "IDLE",    breathe: false)
        case .unknown: return .init(color: Ink.ash,   zh: "未知",   label: "UNKNOWN", breathe: false)
        }
    }
}

/// Agent → short mono glyph + accent color (from seahelm-watch-data.jsx SH_AGENT).
struct AgentStyle {
    let mono: String
    let color: Color
    let name: String

    static func of(_ a: String) -> AgentStyle {
        switch a.lowercased() {
        case "claudecode", "claude":   return .init(mono: "C",  color: Ink.ember, name: "Claude")
        case "codex":                  return .init(mono: "Cx", color: Color(hex: 0xC9C1B2), name: "Codex")
        case "opencode":               return .init(mono: "oc", color: Ink.green, name: "OpenCode")
        case "aider":                  return .init(mono: "ai", color: Ink.amber, name: "Aider")
        case "gemini":                 return .init(mono: "G",  color: Color(hex: 0x8FA6C4), name: "Gemini")
        default:                       return .init(mono: "?",  color: Ink.ash, name: a.isEmpty ? "Agent" : a)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension Font {
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
