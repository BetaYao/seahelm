import Foundation

protocol KeyboardModeDelegate: AnyObject {
    func keyboardModeDidChange(_ mode: KeyboardMode, substate: KeyboardSubstate)
    func keyboardHintDidChange(_ hint: String)
}

final class KeyboardModeController {
    weak var delegate: KeyboardModeDelegate?

    private(set) var mode: KeyboardMode = .normal
    private(set) var substate: KeyboardSubstate = .none

    func enterInsert() {
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

    func beginDelete(agentId: String) {
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

    func beginCreateForm() { setMode(.normal, substate: .createForm) }
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
                return "INSERT  ·  \u{2318}esc \u{2192} normal"
            case .normal:
                return "NORMAL  ·  hjkl move  ·  \u{23CE} enter term  ·  space Helm  ·  d del  ·  c diff  ·  f files  ·  n new  ·  ? keys"
            }
        }
    }
}
