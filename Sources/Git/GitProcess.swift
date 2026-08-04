import Foundation

/// Single entry point for the short-lived `git` invocations the dashboard and
/// side panel make. A thin wrapper over `ProcessRunner.capture`, which is where
/// the pipe-draining and deadline mechanics live — see the comment there for why
/// reading a subprocess pipe only after `waitUntilExit()` is a deadlock.
enum GitProcess {
    static let executable = "/usr/bin/git"

    /// Upper bound on any single invocation.
    static let defaultTimeout: TimeInterval = 5

    typealias Result = ProcessRunner.Capture

    /// Runs `git <arguments>` in `directory`. Returns stdout on a clean exit,
    /// `nil` on launch failure, non-zero exit, or timeout.
    static func run(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = defaultTimeout
    ) -> String? {
        let result = capture(arguments, in: directory, timeout: timeout)
        return result.succeeded ? result.stdout : nil
    }

    /// Full form, for callers that report git's own error text back to the user.
    static func capture(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = defaultTimeout
    ) -> Result {
        ProcessRunner.capture(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout
        )
    }
}
