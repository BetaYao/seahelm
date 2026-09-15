import AppKit

/// Carries out the verdict `TerminalLinkPolicy` reaches for a link action, so
/// nothing else in the app has to re-implement the safety rules or the modal
/// confirmations behind them.
enum TerminalLinkOpener {
    /// Handle the link action libghostty just reported.
    ///
    /// Always reported as handled. Returning false makes libghostty fall back to
    /// its own unrestricted `open` spawn — and on macOS that fallback fails
    /// closed for OSC 8 targets (`ghostty/src/os/open.zig`), which is how those
    /// links used to sit there silently doing nothing.
    @discardableResult
    static func handle(origin: TerminalLinkOrigin, raw: String) -> Bool {
        let decision = TerminalLinkPolicy.decide(origin: origin, raw: raw)
        // Actions arrive on libghostty's thread; NSWorkspace and NSAlert are
        // main-thread only.
        DispatchQueue.main.async { perform(decision) }
        return true
    }

    /// Open an already-parsed URL the user pointed at, e.g. from the pane's
    /// context menu.
    static func open(_ url: URL) {
        DispatchQueue.main.async {
            perform(TerminalLinkPolicy.decide(origin: .visibleText, raw: url.absoluteString))
        }
    }

    private static func perform(_ decision: TerminalLinkDecision) {
        switch decision {
        case .open(let url):
            guard !NSWorkspace.shared.open(url) else { return }
            alert(
                title: "Could not open link",
                detail: UntrustedURL(url.absoluteString).displayString,
                buttons: ["OK"]
            )

        case .confirm(let url):
            let response = alert(
                title: "Open this link?",
                detail: """
                    \(UntrustedURL(url.absoluteString).displayString)

                    This hands the link to whichever application claims the "\(url.scheme ?? "")" scheme.
                    """,
                buttons: ["Open", "Cancel"]
            )
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }

        case .deny(let reason):
            alert(title: "Link blocked", detail: reason, buttons: ["OK"])

        case .ignore:
            break
        }
    }

    @discardableResult
    private static func alert(title: String, detail: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        return alert.runModal()
    }
}
