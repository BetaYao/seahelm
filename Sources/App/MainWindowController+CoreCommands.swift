import AppKit

/// The command language, run by seahelm-core (`command.run`): the desktop's
/// Helm line comes through here. The desktop talks to the dashboard
/// selection, which is passed in as the binding; what comes back is applied.
/// Chats keep their own bindings in seahelm-gateway. The language is the
/// core's alone: when the core does not answer, the line is not run.
extension MainWindowController {
    func routeCommand(_ text: String, reply: @escaping (CommandReply) -> Void) {
        var context: [String: Any] = [
            "desktop": true,
            // First Mate running here: what is for it comes back to hand over.
            // (When the core runs First Mate, the core uses its own first.)
            "first_mate_here": tabCoordinator.firstMate.isRunning,
        ]
        if let key = desktopBoundPaneKey { context["binding"] = ["pane": key] }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // `/new` waits for `git worktree add`.
            let result = CoreSocketClient.call("command.run", ["text": text, "context": context], timeout: 120)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    NSLog("[Command] desktop: seahelm-core ran it")
                    self.apply(outcome, line: text, reply: reply)
                case .failure(.rpc(_, let message)):
                    NSLog("[Command] desktop: seahelm-core refused it")
                    reply(.error(message))
                case .failure(let failure):
                    NSLog("[Command] desktop: seahelm-core did not answer (\(failure))")
                    reply(.error("seahelm-core is not running — commands are the core's. Try again in a moment."))
                }
            }
        }
    }

    private func apply(_ outcome: [String: Any], line: String, reply: @escaping (CommandReply) -> Void) {
        // What the core says the desktop talks to now: a worktree to select.
        // First Mate (no pane) leaves the selection alone.
        if let binding = outcome["binding"] as? [String: Any], binding["first_mate"] as? Bool != true,
           let path = binding["worktree_path"] as? String, !path.isEmpty {
            selectWorktree(path: path)
        }
        if let text = outcome["first_mate"] as? String {
            _ = sayToFirstMate(text)
        }
        let buttons = (outcome["buttons"] as? [[String: Any]] ?? []).compactMap { b -> CommandButton? in
            guard let label = b["label"] as? String, let line = b["line"] as? String else { return nil }
            return .line(label, line)
        }
        let isError = outcome["is_error"] as? Bool ?? false
        let isStatus = line.trimmingCharacters(in: .whitespaces).lowercased() == "/status"
        reply(CommandReply(outcome["text"] as? String ?? "", isError: isError,
                           showsOverview: isStatus,
                           presentsOnDesktop: isError, buttons: buttons))
    }
}
