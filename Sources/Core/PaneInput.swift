import Foundation

/// Input to a pane's terminal and reading it back: typed commands (with
/// pasted images), key presses, recent output. The app holds the sessions,
/// so this is the app's; it decides nothing about what the agent is doing
/// (docs/app-reads-core.md). Pulled out of `Fleet`.
final class PaneInput {
    static let shared = PaneInput()

    private let lock = NSLock()
    /// Each pane's channel to its seahelmd session.
    private var channels: [String: AgentChannel] = [:]

    @discardableResult
    func attach(terminalID: String, paneSessionKey: String) -> AgentChannel {
        let channel = SeahelmdChannel(paneSessionKey: paneSessionKey)
        lock.lock(); channels[terminalID] = channel; lock.unlock()
        return channel
    }

    func detach(terminalID: String) {
        lock.lock(); channels.removeValue(forKey: terminalID); lock.unlock()
    }

    /// Send a command to a specific agent.
    /// Prefer typing into the live terminal surface (exactly like the user) so no control-channel
    /// artifacts leak into the command line. Fall back to the control channel
    /// only when the surface isn't available (e.g. pane not currently rendered).
    /// Send a command to a specific agent.
    /// - Parameter submitWithAttachments: When the command peels to images,
    ///   default behaviour leaves them in the composer (Telegram / mail — let
    ///   the operator add a note). Pass `true` for automated first-brief
    ///   delivery after a new worktree launch so the agent actually starts.
    /// - Parameter agentType: The agent the caller knows is in the pane, for when
    ///   the registry has not caught up — it learns the type from a screen scan,
    ///   and an agent it does not know yet gets images typed as paths.
    func sendCommand(to terminalID: String, command: String, submitWithAttachments: Bool = false,
                     agentType: AgentType? = nil) {
        let station = StationRegistry.shared.station(forId: terminalID)
        // `canDeliverInput`, not merely "a Station exists" — the two come apart
        // for any pane whose tab has not been opened in this run, and that gap
        // is what silently swallowed every message sent to a backgrounded pane
        // from Telegram, mail, and the control socket alike.
        if let station, station.canDeliverInput {
            let agent = agentType ?? Fleet.shared.pane(for: terminalID)?.agentType
            let (images, prose) = PasteMedia.peelCachedMedia(from: command)
            // Claude / Codex / OpenCode attach clipboard PNGs on ctrl+v.
            // Cursor Agent attaches from a typed path instead (see
            // `AgentImagePaste.supports`). Images land in the composer; Enter
            // only when the caller opts in (fresh worktree brief). Plain text
            // still auto-sends.
            if !images.isEmpty, AgentImagePaste.supports(agent) {
                DispatchQueue.main.async {
                    AgentImagePaste.attach(images, to: station) { notAttached in
                        var rest = prose
                        if !notAttached.isEmpty {
                            let paths = notAttached.map { ShellEscape.backslash($0.path) }
                                .joined(separator: " ")
                            rest = [prose, paths].filter { !$0.isEmpty }.joined(separator: "\n")
                        }
                        if !rest.isEmpty {
                            station.sendText(rest)
                        }
                        if submitWithAttachments {
                            DispatchQueue.main.asyncAfter(deadline: .now() + Station.enterSubmitDelay) {
                                station.sendEnterKey()
                            }
                        }
                    }
                }
                return
            }
            // Agents without image-paste: paths stay as text. Submit only when
            // asked (same policy as the paste path above).
            if !images.isEmpty {
                DispatchQueue.main.async {
                    if submitWithAttachments {
                        Self.submitTypedInput(command, on: station)
                    } else {
                        station.sendText(command)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                Self.submitTypedInput(command, on: station)
            }
            return
        }

        let sessionKey = station?.paneSessionKey ?? ""
        lock.lock()
        let channel = channels[terminalID]
        lock.unlock()
        // Channel sends spawn a subprocess (seahelmd/tmux) and wait for it — callers
        // are mostly main-thread interaction sites, so keep it off-thread.
        DispatchQueue.global(qos: .userInitiated).async {
            // `seahelmd send` in preference to the registered channel's `seahelmd run`.
            if !sessionKey.isEmpty, SeahelmdChannel(paneSessionKey: sessionKey).sendPrompt(command) { return }
            channel?.sendCommand(command)
        }
    }

    /// Type `text` then Return after `enterSubmitDelay`. Used for prose-only
    /// orders; image/attachment delivery never calls this.
    private static func submitTypedInput(_ text: String, on station: Station) {
        guard !text.isEmpty else { return }
        station.sendText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Station.enterSubmitDelay) {
            station.sendEnterKey()
        }
    }

    /// Answer an on-screen choice dialog by arrow keys: Down × index, then Return.
    /// For agent TUIs without digit shortcuts (opencode's question tool) — their
    /// `selectedIndex` defaults to the first row for native question tools, while
    /// viewport-discovered prompts pass their currently highlighted row.
    func answerChoiceByArrows(to terminalID: String, index: Int, from selectedIndex: Int = 0) {
        let offset = index - selectedIndex
        pressKeys(to: terminalID,
                  keys: Array(repeating: offset >= 0 ? "down" : "up", count: abs(offset)) + ["enter"])
    }

    /// Press named keys in a pane (`Station.pressKeysOnSurface`). Same
    /// surface-versus-session split as `sendCommand`: a pane whose tab was never
    /// opened gets the bytes through seahelmd, or the keys would vanish while looking
    /// like they were pressed.
    func pressKeys(to terminalID: String, keys: [String]) {
        guard let station = StationRegistry.shared.station(forId: terminalID) else { return }
        guard station.canDeliverInput else {
            guard let sessionKey = station.paneSessionKey, !sessionKey.isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Station.pressKeys(keys, viaSession: sessionKey)
            }
            return
        }
        DispatchQueue.main.async { station.pressKeysOnSurface(keys) }
    }

    /// Read recent output from a specific agent
    func readOutput(from terminalID: String, lines: Int = 50) -> String? {
        lock.lock()
        let channel = channels[terminalID]
        lock.unlock()

        return channel?.readOutput(lines: lines)
    }

    /// Get the channel for a specific agent (for direct access)
    func channel(for terminalID: String) -> AgentChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channels[terminalID]
    }
}
