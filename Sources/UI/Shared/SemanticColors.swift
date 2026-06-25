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
            ? NSColor(srgbRed: 0x10 / 255.0, green: 0x18 / 255.0, blue: 0x1d / 255.0, alpha: 0.40)
            : NSColor(srgbRed: 0xec / 255.0, green: 0xf3 / 255.0, blue: 0xfb / 255.0, alpha: 0.70)
    }

    static let panel: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x0f1011)
            : NSColor(srgbRed: 0xff / 255.0, green: 0xff / 255.0, blue: 0xff / 255.0, alpha: 0.84)
    }

    static let panel2: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x101112)
            : NSColor(srgbRed: 0xf8 / 255.0, green: 0xfb / 255.0, blue: 0xff / 255.0, alpha: 0.90)
    }

    static let text: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xf3f5f8) : NSColor(hex: 0x1f232b)
    }

    static let muted: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xa8afbc) : NSColor(hex: 0x636b78)
    }

    static let subtle: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x8b93a3) : NSColor(hex: 0x717a88)
    }

    static let line: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xc6cfdb)
    }

    static let running: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x33c17b) : NSColor(hex: 0x1f9d63)
    }

    static let waiting: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x3b82f6) : NSColor(hex: 0x2563eb)
    }

    static let idle: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x9ca3af) : NSColor(hex: 0x8a93a1)
    }

    static let accent: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
    }

    static let danger: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(hex: 0xff453a) : NSColor(hex: 0xdc2626)
    }

    // MARK: - Pre-computed derived colors

    static let cardBgSelected: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        let p2 = a.isDark ? NSColor(hex: 0x111111) : NSColor(hex: 0xf7f8fb)
        return acc.withAlphaComponent(0.12).blended(withFraction: 0.88, of: p2) ?? p2
    }
    static let cardBorderSelected: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return acc.withAlphaComponent(0.55).blended(withFraction: 0.45, of: ln) ?? ln
    }
    static let cardBgHover: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        let p2 = a.isDark ? NSColor(hex: 0x111111) : NSColor(hex: 0xf7f8fb)
        return acc.withAlphaComponent(0.06).blended(withFraction: 0.94, of: p2) ?? p2
    }
    static let cardBorderHover: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.35)
    }
    static let cardBorderDefault: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.78)
    }
    static let miniCardBorderSelected: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.65)
    }
    static let miniCardShadowSelected: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.25)
    }
    static let miniCardBorderHover: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.45)
    }
    static let miniCardBorderDefault: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.58)
    }
    static let panelAlpha88: NSColor = NSColor(name: nil) { a in
        let p = a.isDark ? NSColor(hex: 0x1a1a1a) : NSColor(hex: 0xffffff)
        return p.withAlphaComponent(0.88)
    }
    static let lineAlpha70: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.70)
    }
    static let lineAlpha75: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.75)
    }
    static let lineAlpha55: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.55)
    }
    static let lineAlpha45: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.45)
    }
    static let lineAlpha40: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.40)
    }
    static let lineAlpha38: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.38)
    }
    static let lineAlpha22: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.22)
    }
    static let lineAlpha18: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.18)
    }
    static let lineAlpha60: NSColor = NSColor(name: nil) { a in
        let ln = a.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.60)
    }
    static let accentAlpha15: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.15)
    }
    static let accentAlpha12: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        return acc.withAlphaComponent(0.12)
    }
    static let mutedAlpha50: NSColor = NSColor(name: nil) { a in
        let m = a.isDark ? NSColor(hex: 0xa8afbc) : NSColor(hex: 0x636b78)
        return m.withAlphaComponent(0.5)
    }
    static let aiBubbleUser: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        let p2 = a.isDark ? NSColor(hex: 0x111111) : NSColor(hex: 0xf7f8fb)
        return acc.blended(withFraction: 0.82, of: p2) ?? p2
    }
    static let aiSendButtonBg: NSColor = NSColor(name: nil) { a in
        let acc = a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
        let p2 = a.isDark ? NSColor(hex: 0x111111) : NSColor(hex: 0xf7f8fb)
        return acc.blended(withFraction: 0.78, of: p2) ?? p2
    }
    static let backdropBlack: NSColor = NSColor.black.withAlphaComponent(0.4)
    static let threadRowBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(srgbRed: 0x1a / 255.0, green: 0x2a / 255.0, blue: 0x1a / 255.0, alpha: 1)
            : NSColor(hex: 0xe8f5e9)
    }
    static let threadRowBorder: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(srgbRed: 51 / 255.0, green: 193 / 255.0, blue: 123 / 255.0, alpha: 0.25)
            : NSColor(srgbRed: 51 / 255.0, green: 193 / 255.0, blue: 123 / 255.0, alpha: 0.35)
    }
    static let threadRowHoverBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(white: 1, alpha: 0.03)
            : NSColor(white: 0, alpha: 0.03)
    }
    static let threadRowHoverBorder: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.04)
    }

    // MARK: - Zoom-specific tokens

    static let arcBlockHover: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x151618) : NSColor(hex: 0xe8edf5)
    }
    static let arcBlockInactive: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x0f1011) : NSColor(hex: 0xf1f5fb)
    }
    static let tileBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(hex: 0x0f1011)
            : NSColor(srgbRed: 0xff / 255.0, green: 0xff / 255.0, blue: 0xff / 255.0, alpha: 0.88)
    }
    static let tileBarBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor(hex: 0x1a1a1a)
            : NSColor(srgbRed: 0xf4 / 255.0, green: 0xf7 / 255.0, blue: 0xfc / 255.0, alpha: 0.92)
    }
    static let tileGhost1Bg: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x1a1a2e)
            : NSColor(hex: 0xe8e8f0)
    }
    static let tileGhost2Bg: NSColor = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x161625)
            : NSColor(hex: 0xdcdce8)
    }
    static let tileGhostBorder: NSColor = NSColor(name: nil) { appearance in
        let ln = appearance.isDark ? NSColor(hex: 0x222222) : NSColor(hex: 0xd7dbe3)
        return ln.withAlphaComponent(0.60)
    }

    static let miniCardShadowDefault: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor.clear : NSColor.black.withAlphaComponent(0.10)
    }

    // MARK: - Project tab tokens

    static let tabSelectedBg: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x0f2a2e) : NSColor(hex: 0xe4f7fa)
    }
    static let tabSelectedBorder: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x22d3ee) : NSColor(hex: 0x0e9bb5)
    }
    static let tabHoverBg: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor(hex: 0x151618) : NSColor(hex: 0xe0e2e8)
    }
    static let tabHoverBorder: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.08)
    }
    static let iconButtonHoverBg: NSColor = NSColor(name: nil) { a in
        a.isDark
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.07)
    }
    static let iconButtonHoverTint: NSColor = NSColor(name: nil) { a in
        a.isDark ? NSColor.white : NSColor(hex: 0x1f232b)
    }
}
