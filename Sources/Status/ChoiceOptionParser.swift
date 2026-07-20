import Foundation

/// Extracts the tappable choices from a Claude permission prompt or an
/// AskUserQuestion selection box on screen, so the UI can render them as buttons
/// and a tap can send the matching number key (Happy-style: surface the agent's
/// own choice points instead of forcing suggestions).
///
/// Both render as a consecutive numbered list near the bottom, e.g.
///   Do you want to proceed?
///   ❯ 1. Yes
///     2. Yes, and don't ask again for bash commands
///     3. No, and tell Claude what to do differently
enum ChoiceOptionParser {
    struct Option: Equatable {
        let index: Int      // 1-based; the number key that selects it
        let label: String
        let selected: Bool  // the ❯/› cursor is on this row
    }

    // Cursor markers: ❯ (U+276F), › (U+203A), >, •, * — matched as literals.
    private static let line = try! NSRegularExpression(
        pattern: "^\\s*([❯›>•*]?)\\s*(\\d+)\\.\\s+(.+?)\\s*$")

    /// Parse the last numbered choice list near the bottom of a screen snapshot.
    /// Returns [] unless there are ≥2 options numbered consecutively from 1
    /// (avoids matching stray "1. foo" prose in normal output). Wrapped option
    /// labels and footer text after the list are both supported.
    static func parse(_ screen: String, bottomLines: Int = 25) -> [Option] {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(bottomLines)
        var current: [Option] = []
        var lastValid: [Option] = []
        var continuationColumn = Int.max

        func finishRun() {
            if current.count >= 2, current.contains(where: \.selected) {
                lastValid = current
            }
            current.removeAll()
            continuationColumn = Int.max
        }

        for raw in lines {
            let s = String(raw)
            let ns = s as NSString
            if let m = line.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
               let idx = Int(ns.substring(with: m.range(at: 2))) {
                if idx == 1 { finishRun() }
                guard idx == current.count + 1 else {
                    finishRun()
                    continue
                }
                let cursor = ns.substring(with: m.range(at: 1))
                let label = ns.substring(with: m.range(at: 3))
                current.append(Option(index: idx, label: label, selected: !cursor.isEmpty))
                continuationColumn = m.range(at: 3).location
                continue
            }

            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard !current.isEmpty else {
                // Only harmless choice-dialog chrome may trail a completed run.
                // Any real content means an older list in the viewport is stale.
                if !trimmed.isEmpty, !isChoiceFooter(trimmed) {
                    lastValid.removeAll()
                }
                continue
            }
            let leading = s.prefix { $0 == " " || $0 == "\t" }.count
            if !trimmed.isEmpty, leading >= continuationColumn, let previous = current.popLast() {
                current.append(Option(index: previous.index,
                                      label: previous.label + " " + trimmed,
                                      selected: previous.selected))
            } else {
                // A footer (for example Codex's "Press enter to confirm") ends
                // the list but must not discard the valid options above it.
                finishRun()
            }
        }
        finishRun()
        return lastValid
    }

    private static func isChoiceFooter(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("press enter") && (lower.contains("confirm") || lower.contains("cancel"))
    }
}
