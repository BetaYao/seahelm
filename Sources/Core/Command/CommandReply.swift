import Foundation

/// A button offered beside a reply.
///
/// The command language has no idea how a surface draws one: the desktop
/// ignores it (its answer is the dashboard), a chat in seahelm-gateway makes it
/// an inline keyboard. What the layer below is told is only what the button
/// *means*.
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
