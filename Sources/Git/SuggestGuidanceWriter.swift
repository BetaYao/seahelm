import Foundation

enum SuggestGuidanceWriter {
    private static let startMarker = "<!-- seahelm:suggest:start -->"
    private static let endMarker = "<!-- seahelm:suggest:end -->"
    private static let worktreeStartMarker = "<!-- seahelm:worktree:start -->"
    private static let worktreeEndMarker = "<!-- seahelm:worktree:end -->"

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

    /// Tells any agent that can run a shell how to hand its pane over when it
    /// moves into another worktree.
    ///
    /// seahelm normally notices by itself, from the cwd every hook payload
    /// carries — but only while the worktree is still undiscovered, and a 5s
    /// discovery sweep closes that window fast. Agents whose directory change is
    /// not itself a tool call (Codex's `/cd` fires no hook) therefore lose the
    /// race routinely. Saying it explicitly always works, and works for the
    /// agents seahelm has no other signal from at all.
    static func worktreeMoveBlock() -> String {
        return """
        \(worktreeStartMarker)
        ## Moving into another worktree (seahelm)

        seahelm draws one card per git worktree, and your pane is filed under the one it
        started in. If you move into a different worktree and start working there, say so:

            seahelm pane move "$SEAHELM_PANE_ID" <absolute-worktree-path>

        Your pane — and everything running in it — moves to that worktree's card, instead
        of a stray empty pane appearing there while you keep reporting under the old one.

        Only when you actually work in it. Creating a worktree you do not move into needs
        nothing. seahelm often notices on its own; saying it means it is never missed.
        \(worktreeEndMarker)
        """
    }

    static func upsert(into fileURL: URL) {
        upsert(block: managedBlock(), start: startMarker, end: endMarker, into: fileURL)
        upsert(block: worktreeMoveBlock(), start: worktreeStartMarker, end: worktreeEndMarker, into: fileURL)
    }

    private static func upsert(block: String, start startMarker: String, end endMarker: String, into fileURL: URL) {
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
