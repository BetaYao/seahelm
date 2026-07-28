import AppKit

extension NSColor {
    convenience init(hex: Int) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension NSView {
    /// Resolve a dynamic NSColor to CGColor using this view's effective appearance.
    /// Use instead of `someColor.cgColor` to avoid NSAppearance.current mismatches.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        let saved = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        let cg = color.cgColor
        NSAppearance.current = saved
        return cg
    }
}

enum SemanticColors {
    // Use `static let` so each dynamic NSColor is created once and cached.
    // The NSColor(name:) block still resolves per-appearance at draw time,
    // but the NSColor wrapper object itself is allocated only once.
    static let bg: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            // Bare TUI navy (#08222a). Slightly translucent so the window glass
            // blur still reads through behind the panes.
            ? NSColor(srgbRed: 0x08 / 255.0, green: 0x22 / 255.0, blue: 0x2a / 255.0, alpha: 0.55)
            : NSColor(srgbRed: 0xec / 255.0, green: 0xf3 / 255.0, blue: 0xfb / 255.0, alpha: 0.70)
    }

    static let panel: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x0e2d37)
            : NSColor(srgbRed: 0xff / 255.0, green: 0xff / 255.0, blue: 0xff / 255.0, alpha: 0.84)
    }

    static let panel2: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x103440)
            : NSColor(srgbRed: 0xf8 / 255.0, green: 0xfb / 255.0, blue: 0xff / 255.0, alpha: 0.90)
    }

    static let text: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xcfe0e0) : NSColor(hex: 0x1f232b)
    }

    static let muted: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x7fa0a3) : NSColor(hex: 0x636b78)
    }

    static let subtle: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x7fa0a3) : NSColor(hex: 0x717a88)
    }

    static let line: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x96d7e1) : NSColor(hex: 0xc6cfdb)
    }

    static let running: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x1bb062) : NSColor(hex: 0x1f9d63)
    }

    static let waiting: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x5b93f0) : NSColor(hex: 0x2563eb)
    }

    static let idle: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x557170) : NSColor(hex: 0x8a93a1)
    }

    static let accent: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x1fc8da) : NSColor(hex: 0x0e9bb5)
    }

    static let danger: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xe84635) : NSColor(hex: 0xdc2626)
    }

    /// Amber "needs input" accent — waiting statuses that want the user's attention.
    static let attention: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xe0a458) : NSColor(hex: 0xd08706)
    }

    // MARK: - Pre-computed derived colors

    static let cardBgSelected: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x1fc8da) : NSColor(hex: 0x0e9bb5)
        let p2 = a.isDark ? NSColor(hex: 0x12333d) : NSColor(hex: 0xf7f8fb)
        return acc.withAlphaComponent(0.12).blended(withFraction: 0.88, of: p2) ?? p2
    }
    static let cardBorderSelected: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x1fc8da) : NSColor(hex: 0x0e9bb5)
        let ln = a.isDark ? NSColor(hex: 0x96d7e1) : NSColor(hex: 0xd7dbe3)
        return acc.withAlphaComponent(0.55).blended(withFraction: 0.45, of: ln) ?? ln
    }
    static let cardBgHover: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x1fc8da) : NSColor(hex: 0x0e9bb5)
        let p2 = a.isDark ? NSColor(hex: 0x12333d) : NSColor(hex: 0xf7f8fb)
        return acc.withAlphaComponent(0.06).blended(withFraction: 0.94, of: p2) ?? p2
    }
    static let cardBorderHover: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x1fc8da) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.35)
    }
    static let lineAlpha45: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x96d7e1) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.45)
    }
    static let lineAlpha40: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x96d7e1) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.40)
    }
    static let lineAlpha22: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x96d7e1) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.22)
    }
    static let accentAlpha15: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x1fc8da) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.15)
    }
    static let mutedAlpha50: NSColor = NSColor(name: nil) { a in
        let m = a.isDark ? NSColor(hex: 0x7fa0a3) : NSColor(hex: 0x636b78)
        return m.withAlphaComponent(0.5)
    }

    // MARK: - Zoom-specific tokens

    static let tileBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(hex: 0x0e2d37)
            : NSColor(srgbRed: 0xff / 255.0, green: 0xff / 255.0, blue: 0xff / 255.0, alpha: 0.88)
    }
    static let tileBarBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(hex: 0x0a2630)
            : NSColor(srgbRed: 0xf4 / 255.0, green: 0xf7 / 255.0, blue: 0xfc / 255.0, alpha: 0.92)
    }
}
