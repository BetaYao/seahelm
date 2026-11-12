import AppKit

/// A suggestion card placed on its line in this pane (`InlineSuggestions`).
struct SuggestionButtons: Equatable {
    let cardID: String
    let placement: SuggestLinePlacement
}

extension GhosttyNSView {
    /// Ghostty's default `window-padding-x` / `-y` (points, top left): where
    /// the grid starts inside the view. Seahelm's bundled config keeps it.
    static let gridInset: CGFloat = 2

    func setSuggestionButtons(_ buttons: SuggestionButtons?,
                              onTap: ((_ cardID: String, _ index: Int) -> Void)? = nil) {
        if let onTap { suggestionTap = onTap }
        guard buttons != suggestionButtons else { return }
        suggestionButtons = buttons
        rebuildSuggestionButtons()
    }

    /// Kept quiet: the marker is dimmed (a veil in the grid's own background,
    /// so it reads as a prefix), each option gets a thin accent underline, and
    /// only the option under the pointer gets a faint fill. Sublayers like the
    /// presence pills, just under them.
    func rebuildSuggestionButtons() {
        suggestionLayer?.removeFromSuperlayer()
        suggestionLayer = nil
        suggestionHitFrames = []
        defer { window?.invalidateCursorRects(for: self) }
        guard let layer, let surface, let buttons = suggestionButtons else { return }
        let size = ghostty_surface_size(surface)
        guard size.cell_width_px > 0, size.cell_height_px > 0, size.width_px > 0, bounds.width > 0 else { return }
        let scale = CGFloat(size.width_px) / bounds.width
        let cellW = CGFloat(size.cell_width_px) / scale
        let cellH = CGFloat(size.cell_height_px) / scale
        func frame(_ span: SuggestLinePlacement.Span) -> CGRect {
            CGRect(x: Self.gridInset + CGFloat(span.column) * cellW,
                   y: bounds.height - Self.gridInset - CGFloat(span.row + 1) * cellH,
                   width: CGFloat(span.width) * cellW, height: cellH)
        }

        let accent = resolvedCGColor(SemanticColors.accent)
        let container = CALayer()
        container.frame = bounds
        container.zPosition = 101

        let veil = CALayer()
        veil.frame = frame(buttons.placement.marker)
        veil.backgroundColor = (GhosttyBridge.shared.terminalBackgroundColor() ?? .textBackgroundColor)
            .cgColor.copy(alpha: 0.6)
        container.addSublayer(veil)

        for (index, span) in buttons.placement.options.enumerated() {
            let text = frame(span)
            if index == suggestionHovered {
                let fill = CALayer()
                fill.frame = text.insetBy(dx: -cellW * 0.55, dy: -1)
                fill.cornerRadius = 4
                fill.backgroundColor = accent.copy(alpha: 0.16)
                container.addSublayer(fill)
            }
            let underline = CALayer()
            underline.frame = CGRect(x: text.minX, y: text.minY, width: text.width, height: 1)
            underline.backgroundColor = accent.copy(alpha: 0.85)
            container.addSublayer(underline)
            suggestionHitFrames.append((text.insetBy(dx: -cellW * 0.55, dy: 0), index))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(container)
        CATransaction.commit()
        suggestionLayer = container
    }

    /// Follows the pointer for the hover fill.
    func updateSuggestionHover(at point: CGPoint) {
        let index = suggestionHitFrames.first(where: { $0.frame.contains(point) })?.index
        guard index != suggestionHovered else { return }
        suggestionHovered = index
        rebuildSuggestionButtons()
    }

    /// The card and option a click at `point` answers, if it hit one.
    func suggestionHit(at point: CGPoint) -> (cardID: String, index: Int)? {
        guard let buttons = suggestionButtons,
              let hit = suggestionHitFrames.first(where: { $0.frame.contains(point) }) else { return nil }
        return (buttons.cardID, hit.index)
    }

    /// The viewport as text, one string per grid row; nil unless `needle` is
    /// on screen. One read in the common case: a whole-viewport read joins
    /// soft-wrapped rows, so only when its line count is off does it fall back
    /// to reading row by row.
    func viewportRowTexts(ifContaining needle: String) -> [String]? {
        guard let surface else { return nil }
        let rows = Int(ghostty_surface_size(surface).rows)
        guard rows > 0, let all = readViewportRows(0...(rows - 1)), all.contains(needle) else { return nil }
        let lines = all.components(separatedBy: "\n")
        if lines.count == rows { return lines }
        return (0..<rows).map { readViewportRows($0...$0) ?? "" }
    }
}
