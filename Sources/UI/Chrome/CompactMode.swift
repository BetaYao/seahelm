import CoreGraphics

/// Narrow-window presentation: collapse the fleet and (when useful) show panes as tabs.
///
/// Thresholds and hysteresis live here so AppKit (and later GPUI) share one rule.
/// See `docs/superpowers/specs/2026-11-14-compact-pane-tabs-design.md`.
enum CompactMode {
    /// Enter compact when content width is strictly below this.
    static let enterWidth: CGFloat = 760
    /// Leave compact when content width is at or above this.
    static let exitWidth: CGFloat = 820

    /// Hysteresis: widths in `[enterWidth, exitWidth)` keep the current mode.
    static func shouldBeActive(width: CGFloat, currentlyActive: Bool) -> Bool {
        if currentlyActive {
            return width < exitWidth
        }
        return width < enterWidth
    }

    /// Sidebar is hidden when compact forces it, or the user prefers it collapsed.
    static func effectiveCollapsed(compactActive: Bool, userSidebarCollapsed: Bool) -> Bool {
        compactActive || userSidebarCollapsed
    }

    /// Pane tab strip: compact only, with 2+ panes (the document pane counts).
    static func shouldShowPaneTabs(compactActive: Bool, paneCount: Int) -> Bool {
        compactActive && paneCount > 1
    }
}

/// Whether the terminal header hosts the compact pane tab strip.
enum HeaderStripMode: Equatable {
    case none
    /// Compact: the pane tab strip, full header width.
    case terminalOnly
}
