import Foundation

protocol KeyboardModeDelegate: AnyObject {
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate)
    func keyboardHintDidChange(_ hint: String)
}

final class KeyboardModeController {
    weak var delegate: KeyboardModeDelegate?

    private(set) var mode: KeyboardMode = .normal
    private(set) var substate: KeyboardSubstate = .none

    /// Descent path into the leader (`Space`) which-key tree, or nil when the leader
    /// is inactive. `[]` means the leader is open at the root awaiting the first key;
    /// each element is a chosen key one level deeper (e.g. `["s"]` = the `split ▸`
    /// submenu). Rendering + the 400ms reveal delay live in the UI layer (WP-3); this
    /// is the pure state machine only. The leader is only meaningful in NORMAL mode
    /// with no blocking substate.
    private(set) var leaderPath: [String]?

    /// True while the leader menu is active (root or any submenu).
    var isLeaderActive: Bool { leaderPath != nil }

    func enterInsert() {
        closeLeader()
        setMode(.insert, substate: .none)
    }

    func enterNormal() {
        setMode(.normal, substate: .none)
    }

    /// Returns true if the controller consumed the Esc (caller must NOT pass it on).
    /// Only Cmd+Esc exits insert mode; a plain Esc always passes through to the terminal.
    /// `now` is accepted for call-site compatibility but no longer used.
    @discardableResult
    func handleEsc(hasCommand: Bool, now: TimeInterval) -> Bool {
        guard mode == .insert else { return false }
        if hasCommand {
            enterNormal()
            return true
        }
        return false   // plain Esc passes through to the terminal
    }

    // MARK: - Leader (Space / which-key)

    /// Open the leader menu at the root. Only valid in NORMAL mode with no blocking
    /// substate; otherwise a no-op. Returns true if the leader became active.
    @discardableResult
    func openLeader() -> Bool {
        guard mode == .normal, substate == .none, leaderPath == nil else { return false }
        leaderPath = []
        return true
    }

    /// Descend one level by choosing `key` in the current leader menu. No-op when the
    /// leader is inactive. Callers validate `key` against the menu tree (WP-3); this
    /// only records the path.
    func descendLeader(_ key: String) {
        guard leaderPath != nil else { return }
        leaderPath?.append(key)
    }

    /// Go back one level. From the root (`[]`) this closes the leader entirely.
    /// Returns true if the leader is still active afterwards.
    @discardableResult
    func leaderBack() -> Bool {
        guard var path = leaderPath else { return false }
        if path.isEmpty {
            leaderPath = nil
            return false
        }
        path.removeLast()
        leaderPath = path
        return true
    }

    /// Close the leader unconditionally (e.g. after a command fires or on Esc).
    func closeLeader() {
        leaderPath = nil
    }

    func beginDelete(agentId: String) {
        closeLeader()
        setMode(.normal, substate: .deletePending(agentId: agentId))
    }

    @discardableResult
    func confirmDelete() -> String? {
        guard case .deletePending(let agentId) = substate else { return nil }
        setMode(.normal, substate: .none)
        return agentId
    }

    func cancelDelete() {
        guard case .deletePending = substate else { return }
        setMode(.normal, substate: .none)
    }

    func beginCreateForm() { closeLeader(); setMode(.normal, substate: .createForm) }
    func endCreateForm() {
        guard case .createForm = substate else { return }
        setMode(.normal, substate: .none)
    }

    /// Temporarily push a one-off hint to the delegate, then restore `hintText` after 1.5s.
    func flashHint(_ text: String) {
        delegate?.keyboardHintDidChange(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.delegate?.keyboardHintDidChange(self.hintText)
        }
    }

    private func setMode(_ newMode: KeyboardMode, substate newSub: KeyboardSubstate) {
        let changed = newMode != mode || newSub != substate
        mode = newMode
        substate = newSub
        if changed {
            delegate?.keyboardModeDidChange(mode, substate: substate)
            delegate?.keyboardHintDidChange(hintText)
        }
    }

    var hintText: String {
        switch substate {
        case .deletePending:
            return "DELETE?  ·  d / y confirm  ·  esc cancel"
        case .createForm:
            return "CREATE  ·  tab field  ·  \u{2190}\u{2192} change  ·  \u{23CE} create  ·  esc cancel"
        case .none:
            switch mode {
            case .insert:
                return "TERMINAL  ·  \u{2318}esc / \u{2303}\u{2303} back"
            case .normal:
                return "NAV  ·  \u{2191}\u{2193} move  ·  \u{23CE}/\u{2192} enter  ·  \u{2318}esc / \u{2303}\u{2303} back  ·  n new  ·  ? keys"
            }
        }
    }
}
