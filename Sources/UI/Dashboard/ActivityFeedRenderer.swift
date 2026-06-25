// Sources/UI/Dashboard/ActivityFeedRenderer.swift
import AppKit

enum ActivityFeedRenderer {
    /// Render activity events into attributed strings for display.
    /// Events should be passed in newest-first order.
    /// Returns at most `maxLines` attributed strings.
    static func render(events: [ActivityEvent], maxLines: Int) -> [NSAttributedString] {
        let visible = Array(events.prefix(maxLines))
        return visible.enumerated().map { index, event in
            attributedString(for: event, index: index, total: visible.count)
        }
    }

    /// Compute opacity for a given index (0 = newest = full opacity).
    static func opacity(forIndex index: Int, total: Int) -> CGFloat {
        guard total > 1 else { return 1.0 }
        let progress = CGFloat(index) / CGFloat(total - 1)
        // Fade from 1.0 down to 0.15
        return max(0.15, 1.0 - progress * 0.85)
    }

    private static func attributedString(for event: ActivityEvent, index: Int, total: Int) -> NSAttributedString {
        let alpha = opacity(forIndex: index, total: total)
        let fontSize: CGFloat = 11

        let marker: String
        let markerColor: NSColor
        let toolColor: NSColor
        let detailColor: NSColor

        if event.isError {
            marker = "✗ "
            markerColor = SemanticColors.danger.withAlphaComponent(alpha)
            toolColor = SemanticColors.danger.withAlphaComponent(alpha)
            detailColor = SemanticColors.danger.withAlphaComponent(alpha * 0.7)
        } else {
            marker = "▸ "
            markerColor = SemanticColors.accent.withAlphaComponent(alpha)
            toolColor = SemanticColors.text.withAlphaComponent(alpha)
            detailColor = SemanticColors.muted.withAlphaComponent(alpha * 0.8)
        }

        let result = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let monoMedium = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)

        result.append(NSAttributedString(string: marker, attributes: [
            .font: monoFont,
            .foregroundColor: markerColor,
        ]))

        // Pad tool name to 6 chars for alignment
        let paddedTool = event.tool.padding(toLength: 6, withPad: " ", startingAt: 0)
        result.append(NSAttributedString(string: paddedTool + " ", attributes: [
            .font: monoMedium,
            .foregroundColor: toolColor,
        ]))

        result.append(NSAttributedString(string: event.detail, attributes: [
            .font: monoFont,
            .foregroundColor: detailColor,
        ]))

        return result
    }
}
