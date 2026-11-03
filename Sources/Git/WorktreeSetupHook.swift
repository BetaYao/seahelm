import Foundation

/// A repo's own setup for a new worktree: `.seahelm/setup.sh`, run in the
/// worktree's first pane before its agent starts — `npm install`, copying
/// ignored files over, generating code, whatever a fresh checkout lacks.
///
/// It runs *in the pane*, not hidden in the background, so its output is
/// there to read and a hang is visible. The agent starts only if it succeeds;
/// a failed setup leaves the pane at the shell with the script's own error on
/// screen, which is better than an agent working in a half-built checkout.
///
/// The script gets `SEAHELM_WORKTREE` (the new checkout) and
/// `SEAHELM_REPO_ROOT` (the main checkout, where untracked things like
/// `node_modules` or local config can be copied from), and runs with the new
/// worktree as its working directory.
enum WorktreeSetupHook {
    static let relativePath = ".seahelm/setup.sh"

    /// How long the opening brief keeps waiting for the agent when a setup runs
    /// first. An install can take minutes; the brief must outlast it.
    static let briefWait: TimeInterval = 15 * 60
    static let briefRetryInterval: TimeInterval = 1

    /// The script to run: the new worktree's own copy when the repo checks it
    /// in, else the main checkout's (an untracked script still applies).
    static func script(worktreePath: String, repoPath: String,
                       exists: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> String? {
        for root in [worktreePath, repoPath] {
            let path = (root as NSString).appendingPathComponent(relativePath)
            if exists(path) { return path }
        }
        return nil
    }

    /// The shell words that run `script`. An executable script runs as itself,
    /// so its shebang picks the interpreter; anything else goes through `sh`.
    static func command(script: String, worktreePath: String, repoPath: String,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
        let env = "SEAHELM_WORKTREE=\(ShellEscape.singleQuote(worktreePath))"
            + " SEAHELM_REPO_ROOT=\(ShellEscape.singleQuote(repoPath))"
        let run = isExecutable(script) ? ShellEscape.singleQuote(script) : "sh \(ShellEscape.singleQuote(script))"
        return "\(env) \(run)"
    }

    /// What the new pane's session runs: the setup, then the agent if it
    /// succeeded. Nil when there is neither.
    static func launchLine(setup: String?, agent: String?) -> String? {
        switch (setup, agent) {
        case let (setup?, agent?): return "\(setup) && \(agent)"
        case let (setup?, nil): return setup
        case let (nil, agent?): return agent
        case (nil, nil): return nil
        }
    }

    /// The setup command for a new worktree, or nil when its repo has none.
    static func setupCommand(worktreePath: String, repoPath: String) -> String? {
        script(worktreePath: worktreePath, repoPath: repoPath).map {
            command(script: $0, worktreePath: worktreePath, repoPath: repoPath)
        }
    }
}
