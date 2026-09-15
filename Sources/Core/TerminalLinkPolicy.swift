import Foundation

/// Where a link action's target came from.
enum TerminalLinkOrigin: Equatable {
    /// A URL matched in the visible grid text. What the user clicked is exactly
    /// what will open, so the click itself is the consent.
    case visibleText

    /// An OSC 8 hyperlink. The producer chooses the target independently of the
    /// text it is drawn under, so the target is untrusted.
    case hyperlink
}

/// What to do with a link target, before anything touches Launch Services.
enum TerminalLinkDecision: Equatable {
    /// Hand the URL to the default application.
    case open(URL)

    /// Show the target and let the user decide first.
    case confirm(URL)

    /// Refuse, and say why. Reserved for targets that are dangerous or
    /// deceptive: the user needs to know the click was seen and declined.
    case deny(String)

    /// Nothing to open, and nothing worth saying.
    case ignore
}

/// Decides whether a link action from libghostty may open, and what exactly it
/// would open.
///
/// Kept free of AppKit so the rules are unit-testable; `TerminalLinkOpener`
/// carries out the verdict.
enum TerminalLinkPolicy {
    static func decide(origin: TerminalLinkOrigin, raw: String) -> TerminalLinkDecision {
        switch origin {
        case .hyperlink:
            return decision(forUntrusted: raw)

        case .visibleText:
            return decision(forVisibleText: raw)
        }
    }

    /// An OSC 8 target is producer-controlled, so it goes through the same
    /// allow/confirm/deny policy Ghostty's own macOS app applies.
    private static func decision(forUntrusted raw: String) -> TerminalLinkDecision {
        switch UntrustedURL(raw).decision {
        case .allow(let url):
            return .open(url)

        case .confirm(let url):
            return .confirm(url)

        case .deny(let reason):
            return .deny(reason.message)
        }
    }

    /// A URL-shaped token, or a path libghostty already resolved against the
    /// pane's working directory. It does that resolution before it sends the
    /// action, so a scheme-less target here is a path and never a relative
    /// reference.
    private static func decision(forVisibleText raw: String) -> TerminalLinkDecision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignore }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            // `file:` is the one shape a visible target can still lie about: the
            // path may name an executable, and Launch Services will run it.
            // Every other scheme goes straight out — the user pointed at that
            // exact text and pressed the modifier.
            return url.isFileURL ? visibleFileDecision(for: url.absoluteString) : .open(url)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        // libghostty resolves a relative path against the pane's working
        // directory before it sends the action, and only when the file is
        // actually there. One that is still relative names nothing we can
        // reach, and clicking a stale path is a no-op in every other terminal.
        guard expanded.hasPrefix("/") else { return .ignore }
        return visibleFileDecision(for: URL(filePath: expanded).absoluteString)
    }

    private static func visibleFileDecision(for urlString: String) -> TerminalLinkDecision {
        switch UntrustedURL(urlString).decision {
        case .allow(let url):
            return .open(url)

        case .confirm(let url):
            return .confirm(url)

        case .deny(let reason):
            // A path that merely does not exist is not worth an alert — the
            // output scrolled, or the click missed the token. A path that could
            // *execute* is the exception: staying silent there reads as a
            // broken menu rather than as a refusal.
            return reason == .unsafeFile ? .deny(reason.message) : .ignore
        }
    }
}
