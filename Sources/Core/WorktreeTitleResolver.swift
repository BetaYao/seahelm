import Foundation

/// Resolves the human-facing title for a worktree, shared by the top capsule and
/// the mini cards.
/// Order: integration state → Claude/Cursor session title → task description →
/// last user prompt → branch.
enum WorktreeTitleResolver {
    static func resolve(
        worktreePath: String,
        lastUserPrompt: String,
        branch: String,
        /// The integration checkout has no agent and no task, so every later
        /// source would describe a shell. Its own state is the only honest
        /// title, and it goes first for that reason.
        integrationStatus: (String) -> String? = { IntegrationStatusStore.shared.status(forWorktree: $0) },
        sessionTitle: (String) -> String? = { path in
            SessionTitleLookup.title(worktreePath: path)
                ?? CursorSessionTitleLookup.title(worktreePath: path)
        },
        taskDescription: (String) -> String? = { WorktreeTaskStore.shared.task(forWorktree: $0) }
    ) -> String {
        if let state = integrationStatus(worktreePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !state.isEmpty {
            return state
        }
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
