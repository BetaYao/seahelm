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

    /// Parse the numbered choice list from the bottom of a screen snapshot.
    /// Returns [] unless there are ≥2 options numbered consecutively from 1
    /// (avoids matching stray "1. foo" prose in normal output).
    static func parse(_ screen: String, bottomLines: Int = 25) -> [Option] {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).suffix(bottomLines)
        var opts: [Option] = []
        for raw in lines {
            let s = String(raw)
            let ns = s as NSString
            guard let m = line.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  let idx = Int(ns.substring(with: m.range(at: 2))) else {
                // A non-option line between options breaks the run; keep only a
                // trailing contiguous block.
                if !opts.isEmpty && !s.trimmingCharacters(in: .whitespaces).isEmpty { opts.removeAll() }
                continue
            }
            let cursor = ns.substring(with: m.range(at: 1))
            let label = ns.substring(with: m.range(at: 3))
            opts.append(Option(index: idx, label: label, selected: !cursor.isEmpty))
        }
        // Validate: consecutive 1..n, at least 2.
        guard opts.count >= 2 else { return [] }
        for (i, o) in opts.enumerated() where o.index != i + 1 { return [] }
        return opts
    }
}
