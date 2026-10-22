import Foundation

/// The zsh side of `pane.exec`: run a command in a pane's shell only when the
/// shell is at an empty primary prompt, and never on top of what someone is
/// typing.
///
/// `pane.run` types text and presses Return, which is right for an agent's
/// composer and wrong for a shell holding a half-typed line: the command is
/// glued onto the draft. Here the shell reports its own state instead, so it
/// works for a pane that is not on screen (no Ghostty surface to ask):
/// - each prompt writes `<session>.prompt` — a sequence number and the last
///   command's exit status — and each command removes it, so the file exists
///   exactly while the shell sits at its prompt;
/// - the app leaves the command in `<session>.cmd` and presses a private key
///   bound to `_seahelm_run`, which looks at the real edit buffer: empty at a
///   primary prompt → it takes the command (`.claimed`) and accepts the line;
///   anything else → it hands it back (`.refused`) untouched;
/// - the command has finished when `.prompt` returns with a higher number.
///
/// Installed by wrapping Ghostty's own ZDOTDIR trick (`GhosttyBridge`): our
/// `.zshenv` sources Ghostty's — which restores the user's `ZDOTDIR` and reads
/// their `.zshenv` — then loads the script. zsh only; other shells never write
/// `.ready` and `pane.exec` refuses them. File writes are zsh builtins, so a
/// prompt costs no extra process.
enum ShellRunIntegration {
    /// The key the widget is bound to: a CSI sequence no keyboard sends.
    static let triggerSequence = "\u{1b}[9013~"

    static var baseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/seahelm")
    }
    /// Where the scripts live; the value given to zsh as `ZDOTDIR`.
    static var zshDirectory: URL { baseDirectory.appendingPathComponent("shell/zsh") }
    /// Per-session spool: `<session>.cmd` (offered), `.claimed`, `.refused`,
    /// `.prompt` (at the prompt: "<seq> <last status>") and `.ready` (the shell
    /// has bound the widget).
    static var runDirectory: URL { baseDirectory.appendingPathComponent("run") }

    enum Spool: String {
        case command = "cmd", claimed, refused, prompt, ready
    }

    /// Forget a session's spool once its shell is gone.
    static func removeSpool(session: String, in directory: URL = runDirectory) {
        for kind in [Spool.command, .claimed, .refused, .prompt, .ready] {
            try? FileManager.default.removeItem(at: spoolFile(kind, session: session, in: directory))
        }
    }

    /// `.prompt`'s "<seq> <status>".
    static func parsePrompt(_ text: String) -> (sequence: Int, status: Int)? {
        let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// `.claimed`'s "<seq> <prompt lines>": the prompt the command was taken at,
    /// and how many lines that prompt takes.
    static func parseClaim(_ text: String) -> (sequence: Int, promptLines: Int)? {
        let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func spoolFile(_ kind: Spool, session: String, in directory: URL = runDirectory) -> URL {
        directory.appendingPathComponent("\(session).\(kind.rawValue)")
    }

    /// Write the scripts (when they differ) and create the private spool
    /// directory. Returns the directory to use as `ZDOTDIR`, or nil when either
    /// could not be set up — the shell then keeps Ghostty's plain integration.
    @discardableResult
    static func ensureInstalled(base: URL = baseDirectory) -> URL? {
        let fm = FileManager.default
        let zsh = base.appendingPathComponent("shell/zsh")
        let run = base.appendingPathComponent("run")
        do {
            try fm.createDirectory(at: zsh, withIntermediateDirectories: true)
            try fm.createDirectory(at: run, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: run.path)
            for (name, contents) in [(".zshenv", zshenv), ("seahelm-run.zsh", runScript)] {
                let url = zsh.appendingPathComponent(name)
                if (try? String(contentsOf: url, encoding: .utf8)) != contents {
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            return zsh
        } catch {
            NSLog("[ShellRunIntegration] install failed: \(error)")
            return nil
        }
    }

    /// Ghostty's integration first — it restores the user's `ZDOTDIR` and reads
    /// their `.zshenv` — then the run widget for interactive shells.
    static let zshenv = #"""
    # Managed by Seahelm; rewritten on launch.
    'builtin' 'typeset' _seahelm_dir=${${(%):-%x}:A:h}
    'builtin' 'typeset' _seahelm_ghostty="${GHOSTTY_RESOURCES_DIR-}/shell-integration/zsh/.zshenv"
    if [[ -n "${GHOSTTY_RESOURCES_DIR-}" && -r "$_seahelm_ghostty" ]]; then
        'builtin' 'source' '--' "$_seahelm_ghostty"
    else
        if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
            'builtin' 'export' ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
            'builtin' 'unset' 'GHOSTTY_ZSH_ZDOTDIR'
        else
            'builtin' 'unset' 'ZDOTDIR'
        fi
        [[ ! -r "${ZDOTDIR-$HOME}/.zshenv" ]] || 'builtin' 'source' '--' "${ZDOTDIR-$HOME}/.zshenv"
    fi
    [[ ! -o 'interactive' || ! -r "$_seahelm_dir/seahelm-run.zsh" ]] || 'builtin' 'source' '--' "$_seahelm_dir/seahelm-run.zsh"
    'builtin' 'unset' '_seahelm_dir' '_seahelm_ghostty'
    """#

    /// The prompt reporting and the widget. The key is bound on the first
    /// prompt rather than here, so it lands after the user's `.zshrc` has picked
    /// its keymaps; `.ready` tells the app the shell can take a command. The
    /// precmd hook goes first in line so `$?` is still the command's status.
    static let runScript = #"""
    # Managed by Seahelm; rewritten on launch. Reports whether this shell is at
    # its prompt and lets `seahelm pane exec` run a command here, only at an
    # empty primary prompt.
    if [[ -z "${_seahelm_run_id-}" && -n "${SEAHELM_PANE_ID:-${ZMX_SESSION-}}" ]]; then
        'builtin' 'typeset' -g _seahelm_run_id="${SEAHELM_PANE_ID:-$ZMX_SESSION}"
        'builtin' 'typeset' -g _seahelm_run_base="${SEAHELM_RUN_DIR:-$HOME/.config/seahelm/run}/$_seahelm_run_id"
        'builtin' 'typeset' -gi _seahelm_run_seq=0
        'builtin' 'zmodload' -F zsh/files b:zf_rm 2>/dev/null
        function _seahelm_run_rm() {
            if (( ${+builtins[zf_rm]} )); then zf_rm -f -- "$@"; else command rm -f -- "$@"; fi
        }
        function _seahelm_run() {
            builtin emulate -L zsh -o no_aliases
            [[ -r "$_seahelm_run_base.cmd" ]] || return 0
            # PREBUFFER holds earlier lines at a continuation prompt.
            if [[ -n "$BUFFER" || -n "$PREBUFFER" || "$CONTEXT" != start ]]; then
                _seahelm_run_rm "$_seahelm_run_base.cmd"
                : >| "$_seahelm_run_base.refused"
                return 0
            fi
            BUFFER=$(<"$_seahelm_run_base.cmd")
            _seahelm_run_rm "$_seahelm_run_base.cmd"
            # How many lines the prompt takes, so the app can cut the next one
            # off the end of the command's output.
            builtin local prompt="${(%%)PS1}"
            builtin print -r -- "$_seahelm_run_seq $(( ${#prompt} - ${#${prompt//$'\n'/}} + 1 ))" \
                >| "$_seahelm_run_base.claimed"
            CURSOR=${#BUFFER}
            zle .accept-line
        }
        function _seahelm_run_precmd() {
            builtin local -i last=$?
            (( ++_seahelm_run_seq ))
            if (( ! ${+_seahelm_run_bound} )); then
                builtin zle -N _seahelm_run
                builtin local map
                for map in main emacs viins vicmd; do
                    builtin bindkey -M "$map" $'\e[9013~' _seahelm_run
                done
                'builtin' 'typeset' -g _seahelm_run_bound=1
                builtin print -r -- $$ >| "$_seahelm_run_base.ready"
            fi
            builtin print -r -- "$_seahelm_run_seq $last" >| "$_seahelm_run_base.prompt"
        }
        function _seahelm_run_preexec() {
            _seahelm_run_rm "$_seahelm_run_base.prompt"
        }
        'builtin' 'typeset' -ga precmd_functions preexec_functions
        precmd_functions=(_seahelm_run_precmd $precmd_functions)
        preexec_functions+=(_seahelm_run_preexec)
    fi
    """#
}

enum PaneExecError: Error, Equatable {
    case unavailable
    case unknownPane
    /// Not a zmx pane: there is no session to hand the command to.
    case noSession
    /// Something is running in the pane (or a TUI holds the screen).
    case notAtPrompt
    /// The shell never bound the widget: not zsh, or started before this version.
    case noIntegration
    /// Another `pane.exec` is already waiting on this pane.
    case busy
    /// Someone has typed at the prompt; the command was not run.
    case unsentInput
    /// The shell did not answer the key.
    case notTaken
    /// The command is still running after the deadline. It keeps running.
    case timedOut(seconds: Int)

    var message: String {
        switch self {
        case .unavailable: return "pane exec unavailable"
        case .unknownPane: return "pane not found"
        case .noSession: return "pane has no persistent session to run in"
        case .notAtPrompt: return "pane isn't at a shell prompt — something is running there"
        case .noIntegration:
            return "pane's shell can't take commands: exec needs a zsh pane opened by this version of seahelm"
        case .busy: return "another exec is already waiting on this pane"
        case .unsentInput: return "the prompt has unsent input; left it alone and ran nothing"
        case .notTaken: return "the shell didn't take the command"
        case .timedOut(let s): return "still running after \(s)s; it keeps running in the pane"
        }
    }

    var code: Int {
        switch self {
        case .unknownPane: return ControlError.notFound
        case .timedOut: return ControlError.timedOut
        default: return ControlError.invalidRequest
        }
    }
}
