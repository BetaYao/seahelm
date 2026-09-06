import Foundation

/// The command language over an empty fleet.
///
/// What answers before the window has wired a real host — tests and headless
/// runs. `/help` and `/idea` work in full; everything that needs a pane or a
/// worktree says so.
final class HeadlessCommandHost: CommandHost {
    static let shared = HeadlessCommandHost()

    func fleetIndex() -> FleetIndex { .empty }
    var desktopBoundPaneKey: String? { nil }
    var integrationEnabled: Bool { false }

    func createWorktree(task: String, repoPath: String, completion: @escaping (String?) -> Void) {
        completion(nil)
    }
    func selectWorktree(path: String) {}
    func sendText(paneId: String, text: String) -> Bool { false }
    func transcript(paneSessionKey: String) -> String? { nil }
    func activity(paneId: String) -> [String] { [] }
    func assessReturn(worktreePath: String, completion: @escaping (WorktreeReturnFacts) -> Void) {
        completion(WorktreeReturnFacts(branch: ""))
    }
    func performReturn(_ plan: WorktreeReturnPlan, worktree: WorktreeRef,
                       completion: @escaping (WorktreeReturnOutcome) -> Void) {
        var outcome = WorktreeReturnOutcome()
        outcome.failure = "Not running."
        completion(outcome)
    }
    func isIntegrationCheckout(worktreePath: String) -> Bool { false }
    func forgetRepo(path: String) {}
    func integrate(mode: IntegrationConflictMode, force: Bool,
                   completion: @escaping (String, Bool) -> Void) {
        completion("Integration is not available here.", false)
    }
    func addIdea(text: String, source: String) -> String {
        IdeaStore.shared.add(text: text, project: "external", source: source, tags: []).text
    }
    func openIssue(title: String) {}
    func addRepo() {}
    func confirm(_ summary: String, completion: @escaping (Bool) -> Void) { completion(false) }
}
