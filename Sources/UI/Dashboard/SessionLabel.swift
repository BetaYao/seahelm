import AppKit

/// A colour a session row can be tagged with, drawn as a ribbon down the row's
/// left edge and picked from the row's right-click menu.
///
/// Stored by `rawValue` in `worktree-labels.json`, so the ids have to stay
/// stable — renaming a case silently drops every row already wearing it.
/// Colour only on purpose: the ribbon is a glance, not a field to fill in.
enum SessionLabel: String, CaseIterable {
    case red
    case orange
    case yellow
    case green
    case teal
    case blue
    case purple
    case pink

    /// Menu title for the swatch.
    var title: String {
        rawValue.capitalized
    }

    /// Ribbon colour. Light themes need the darker, denser variant — the dark
    /// one is picked to carry on the near-black list background and washes out
    /// on white.
    var color: NSColor {
        NSColor(name: nil) { [self] appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? darkSurfaceColor : Self.color(hex: lightHex)
        }
    }

    /// The dark-theme variant whatever the appearance, for a surface that is
    /// dark in both: the island stays near-black in light mode, where `color`
    /// would hand it the dense variant meant for a white list.
    var darkSurfaceColor: NSColor {
        Self.color(hex: darkHex)
    }

    private var darkHex: UInt32 {
        switch self {
        case .red: return 0xFF6B6B
        case .orange: return 0xFFA24C
        case .yellow: return 0xF5D64E
        case .green: return 0x6BD68A
        case .teal: return 0x1FC8DA
        case .blue: return 0x6AA6FF
        case .purple: return 0xB48CFF
        case .pink: return 0xFF8FC7
        }
    }

    private var lightHex: UInt32 {
        switch self {
        case .red: return 0xD92D20
        case .orange: return 0xB54708
        case .yellow: return 0x9A7400
        case .green: return 0x1E7A3C
        case .teal: return 0x0E9BB5
        case .blue: return 0x1B5FD9
        case .purple: return 0x6B35D6
        case .pink: return 0xC02580
        }
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
