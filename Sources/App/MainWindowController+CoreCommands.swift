import AppKit

/// The command language, run by seahelm-core (`command.run`): the Helm line,
/// Telegram, mail and a chat button all come through here. The app keeps
/// who each conversation talks to (`CommandSessionStore`, or the desktop's
/// selection), passes it in, and applies what comes back. When the core does
/// not answer, the app's own executor runs the line instead.
extension MainWindowController {
    func routeCommand(_ text: String, surface: CommandSurface, reply: @escaping (CommandReply) -> Void) {
        var context: [String: Any] = [
            "desktop": surface.isDesktop,
            // First Mate running here: what is for it comes back to hand over.
            // (When the core runs First Mate, the core uses its own first.)
            "first_mate_here": tabCoordinator.autopilot.isRunning,
        ]
        if let binding = coreBinding(for: surface) { context["binding"] = binding }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // `/new` waits for `git worktree add`.
            let result = CoreSocketClient.call("command.run", ["text": text, "context": context], timeout: 120)
            DispatchQueue.main.async {
                guard let self else { return }
                // Which runner answered, never the text itself.
                let surfaceName = surface.sessionKey.split(separator: ":").first.map(String.init) ?? surface.sessionKey
                switch result {
                case .success(let outcome):
                    NSLog("[Command] \(surfaceName): seahelm-core ran it")
                    self.apply(outcome, line: text, surface: surface, reply: reply)
                case .failure(.rpc(_, let message)):
                    NSLog("[Command] \(surfaceName): seahelm-core refused it")
                    reply(.error(message))
                case .failure(let failure):
                    NSLog("[Command] \(surfaceName): seahelm-core did not answer (\(failure)); the app ran it")
                    self.commandExecutor.run(text, surface: surface, reply: reply)
                }
            }
        }
    }

    /// Who the conversation talks to, in `command.run`'s shape; nil when nobody.
    private func coreBinding(for surface: CommandSurface) -> [String: Any]? {
        if surface.isDesktop {
            return desktopBoundPaneKey.map { ["pane": $0] }
        }
        let session = tabCoordinator.commandSessions.session(for: surface.sessionKey)
        guard !session.closed else { return nil }
        if let key = session.boundPaneKey {
            return ["pane": key, "worktree_path": session.boundWorktreePath ?? ""]
        }
        if let path = session.boundWorktreePath { return ["worktree_path": path] }
        return nil
    }

    private func apply(_ outcome: [String: Any], line: String, surface: CommandSurface,
                       reply: @escaping (CommandReply) -> Void) {
        if let binding = outcome["binding"] as? [String: Any] {
            rebind(surface, to: binding)
        }
        if let text = outcome["first_mate"] as? String {
            _ = sayToFirstMate(text, from: surface)
        }
        let buttons = (outcome["buttons"] as? [[String: Any]] ?? []).compactMap { b -> CommandButton? in
            guard let label = b["label"] as? String, let line = b["line"] as? String else { return nil }
            return .line(label, line)
        }
        let isError = outcome["is_error"] as? Bool ?? false
        let isStatus = line.trimmingCharacters(in: .whitespaces).lowercased() == "/status"
        reply(CommandReply(outcome["text"] as? String ?? "", isError: isError,
                           showsOverview: surface.isDesktop && isStatus,
                           presentsOnDesktop: isError, buttons: buttons))
    }

    /// What the core says the conversation talks to now: First Mate (a chat
    /// with no pane), a pane, or a worktree whose first pane takes it. On the
    /// desktop, the selection.
    private func rebind(_ surface: CommandSurface, to binding: [String: Any]) {
        let sessions = tabCoordinator.commandSessions
        if binding["first_mate"] as? Bool == true {
            if !surface.isDesktop { sessions.unbind(surface.sessionKey) }
            return
        }
        let path = binding["worktree_path"] as? String ?? ""
        if surface.isDesktop {
            if !path.isEmpty { selectWorktree(path: path) }
            return
        }
        if let key = binding["pane"] as? String {
            let paneId = StationRegistry.shared.station(forSessionName: key)?.id ?? key
            sessions.bind(surface.sessionKey, toPaneKey: key, paneId: paneId, worktreePath: path, commander: surface.commander)
        } else if !path.isEmpty {
            sessions.bind(surface.sessionKey, toWorktreePath: path, commander: surface.commander)
        }
    }
}
