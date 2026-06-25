import Foundation

enum SuggestGuidanceWriter {
    private static let startMarker = "<!-- seahelm:suggest:start -->"
    private static let endMarker = "<!-- seahelm:suggest:end -->"

    static func managedBlock() -> String {
        return """
        \(startMarker)
        ## Quick options for the user (seahelm)

        When you finish a turn and can anticipate the user's likely next steps, run:

            seahelm-suggest 'first option' 'second option'

        Each option is a short imperative phrase (max ~5 options). Do NOT print options
        as text in your reply — the user sees them as clickable buttons in seahelm.
        \(endMarker)
        """
    }

    static func upsert(into fileURL: URL) {
        let block = managedBlock()
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

        let updated: String
        if let startRange = existing.range(of: startMarker),
           let endRange = existing.range(of: endMarker),
           startRange.lowerBound < endRange.lowerBound {
            // Replace the existing managed block in place.
            updated = existing.replacingCharacters(in: startRange.lowerBound..<endRange.upperBound, with: block)
        } else if existing.isEmpty {
            updated = block + "\n"
        } else {
            let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
            updated = existing + separator + block + "\n"
        }

        try? updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func writeForWorktree(_ worktreePath: String) {
        let root = URL(fileURLWithPath: worktreePath)
        for name in ["CLAUDE.md", "AGENTS.md"] {
            upsert(into: root.appendingPathComponent(name))
        }
    }
}
