import AppKit

enum ThemeMode: String {
    case dark
    case light
    case system

    static func applyAppearance(_ mode: ThemeMode) {
        switch mode {
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}

enum Theme {
    static var background: NSColor { SemanticColors.bg }
    static var surface: NSColor { SemanticColors.panel }
    static var border: NSColor { SemanticColors.line }
    static var textPrimary: NSColor { SemanticColors.text }
    static var textSecondary: NSColor { SemanticColors.muted }
    static var accent: NSColor { SemanticColors.accent }

    static let cardCornerRadius: CGFloat = 4
}
