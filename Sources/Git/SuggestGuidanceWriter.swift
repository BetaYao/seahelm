import Foundation

enum SuggestGuidanceWriter {
    private static let startMarker = "<!-- seahelm:suggest:start -->"
    private static let endMarker = "<!-- seahelm:suggest:end -->"

    static func managedBlock() -> String {
        return """
        \(startMarker)
        ## Quick options for the user (seahelm)

        When you finish a turn and can anticipate the user's likely next steps, end your
        reply with one final plain-text line formatted exactly as:

            \(StopHookResponder.sentinel) first option | second option

        Give 2-5 short imperative phrases separated by ` | `. seahelm turns that line into
        clickable buttons for the user. Make it the LAST line of your message; do NOT run
        a tool or shell command to produce it.
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
