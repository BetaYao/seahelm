import Foundation

/// Resolves the human-facing title for a worktree, shared by the top capsule and
/// the mini cards.
/// Order: Claude/Cursor session title → task description → last user prompt → branch.
enum CabinTitleResolver {
    static func resolve(
        worktreePath: String,
        lastUserPrompt: String,
        branch: String,
        sessionTitle: (String) -> String? = { path in
            SessionTitleLookup.title(worktreePath: path)
                ?? CursorSessionTitleLookup.title(worktreePath: path)
        },
        taskDescription: (String) -> String? = { CabinTaskStore.shared.task(forWorktree: $0) }
    ) -> String {
        if let summary = sessionTitle(worktreePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let task = taskDescription(worktreePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !task.isEmpty {
            return task
        }
        let prompt = lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return prompt }
        return branch
    }
}
