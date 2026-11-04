import Foundation

/// Where a line came from. Decides only what the surface *can do* — show a
/// sheet, open a panel — never what a command means.
struct CommandSurface: Equatable {
    /// `CommandSession` key: `desktop`, `telegram:<chat>`, `mail:<thread>`.
    let sessionKey: String
    /// The desktop has a selection to bind through and sheets to confirm with.
    let isDesktop: Bool
    /// Who is speaking, where the surface knows — a mail address, a Telegram id.
    let commander: String?

    static let desktop = CommandSurface(sessionKey: "desktop", isDesktop: true, commander: nil)

    init(sessionKey: String, isDesktop: Bool = false, commander: String? = nil) {
        self.sessionKey = sessionKey
        self.isDesktop = isDesktop
        self.commander = commander
    }
}

/// A button offered beside a reply.
///
/// The command language has no idea how a surface draws one: Telegram makes it
/// an inline keyboard, the desktop ignores it (its answer is the dashboard) and
/// mail drops it (a mail client cannot call back). What the layer below is told
/// is only what the button *means*.
struct CommandButton: Equatable {
    enum Effect: Equatable {
        /// Run this line, as if the tapper had typed it.
        case line(String)
    }

    let label: String
    let effect: Effect

    /// The common case: the button is the line it says.
    static func line(_ label: String, _ line: String) -> CommandButton {
        CommandButton(label: label, effect: .line(line))
    }
}

struct CommandReply: Equatable {
    let text: String
    let isError: Bool
    /// The desktop's listing is the dashboard; `/status` there navigates.
    let showsOverview: Bool
    /// The desktop drops reply text — the dashboard is its answer — except an
    /// outcome with something to act on: a PR link, a worktree held back.
    let presentsOnDesktop: Bool
    /// Offered beside the text on surfaces that can draw buttons. Always a
    /// shortcut for something the text already says how to type, so a surface
    /// that drops them loses nothing.
    let buttons: [CommandButton]

    init(_ text: String, isError: Bool = false, showsOverview: Bool = false,
         presentsOnDesktop: Bool = false, buttons: [CommandButton] = []) {
        self.text = text
        self.isError = isError
        self.showsOverview = showsOverview
        self.presentsOnDesktop = presentsOnDesktop
        self.buttons = buttons
    }

    /// Errors surface on the desktop too: a right-click Return that fails to
    /// parse or is refused used to only beep, which reads as "nothing happened".
    static func error(_ text: String) -> CommandReply {
        CommandReply(text, isError: true, presentsOnDesktop: true)
    }
}
