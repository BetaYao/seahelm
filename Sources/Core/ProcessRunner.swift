import Foundation

enum ProcessRunner {
    /// Outcome of a captured subprocess run.
    struct Capture {
        /// `nil` when the child never exited on its own — launch failure or
        /// timeout. Check `timedOut` to tell those apart.
        let exitCode: Int32?
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var succeeded: Bool { exitCode == 0 }
    }

    /// Runs a subprocess and returns its output, enforcing the two rules that
    /// every hand-rolled `Process` helper in this codebase got wrong at least
    /// once:
    ///
    ///  1. **Drain the pipes while the child runs.** Reading only after
    ///     `waitUntilExit()` deadlocks the moment output exceeds the pipe
    ///     buffer — a few KB, and less once the system is under pipe-KVA
    ///     pressure. The child blocks in `write()`, we block waiting for it to
    ///     exit, and neither side ever moves. This is not theoretical: it hung
    ///     the Changes tab indefinitely and leaked 31 wedged `git` processes.
    ///  2. **Bound the wait.** A child stuck in uninterruptible I/O (a repo on
    ///     a volume that was ejected and remounted) never returns from
    ///     `waitUntilExit()` at all.
    ///
    /// Wedged callers are contagious: each parks a thread and holds two pipes
    /// open forever, and enough of them starve the dispatch pool that delivers
    /// `terminationHandler` — so *unrelated* subprocesses start reporting
    /// spurious timeouts.
    ///
    /// Pass `timeout: nil` only for a child whose runtime is genuinely unbounded
    /// and user-initiated; everything else should carry a deadline.
    static func capture(
        executable: URL,
        arguments: [String],
        currentDirectory: String? = nil,
        standardInput: String? = nil,
        timeout: TimeInterval?,
        maxCapturedBytes: Int = defaultMaxCapturedBytes
    ) -> Capture {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = standardInput.map { _ in Pipe() }
        if let inPipe {
            process.standardInput = inPipe
        }

        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            // Nothing was spawned, so no drain thread exists to close these —
            // close all four ends here or a failing lookup leaks on every call.
            for handle in [
                outPipe.fileHandleForReading, outPipe.fileHandleForWriting,
                errPipe.fileHandleForReading, errPipe.fileHandleForWriting,
                inPipe?.fileHandleForReading, inPipe?.fileHandleForWriting,
            ].compactMap({ $0 }) {
                try? handle.close()
            }
            return Capture(exitCode: nil, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let drained = DispatchGroup()
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        drained.enter()
        ioQueue.async {
            let data = drain(outPipe.fileHandleForReading, maxCapturedBytes: maxCapturedBytes)
            lock.lock(); stdoutData = data; lock.unlock()
            drained.leave()
        }
        drained.enter()
        ioQueue.async {
            let data = drain(errPipe.fileHandleForReading, maxCapturedBytes: maxCapturedBytes)
            lock.lock(); stderrData = data; lock.unlock()
            drained.leave()
        }
        if let inPipe, let standardInput {
            // Off-thread for the same reason we drain off-thread: a child that
            // never reads its stdin would otherwise block us mid-write.
            ioQueue.async {
                let handle = inPipe.fileHandleForWriting
                // A child that exits without draining stdin (`git credential
                // fill` does exactly that) leaves us writing to a closed pipe.
                // The default disposition for EPIPE is SIGPIPE, which kills the
                // *whole app* — `try?` catches the Swift error but never sees
                // the signal. Ask the kernel for EPIPE instead.
                _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? handle.write(contentsOf: Data(standardInput.utf8))
                try? handle.close()
            }
        }

        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                // Best-effort reap; a process wedged in kernel I/O won't die on
                // SIGTERM, so give up after a beat and leak the reader threads
                // rather than the caller.
                _ = exited.wait(timeout: .now() + 1)
                process.terminationHandler = nil
                // Give the readers the same beat to notice EOF and close. Once
                // the child is signalled this is immediate, and without it the
                // descriptors outlive the call: returning early left them open
                // until the reader threads happened to wake, so a caller that
                // timed out in a loop accumulated fds it had no way to reclaim.
                // Still bounded — a genuinely wedged child must not park us.
                _ = drained.wait(timeout: .now() + 1)
                return Capture(
                    exitCode: nil,
                    stdout: "",
                    stderr: "timed out after \(Int(timeout))s",
                    timedOut: true
                )
            }
        } else {
            exited.wait()
        }
        process.terminationHandler = nil

        // The child is gone, so both read ends see EOF almost immediately —
        // unless a grandchild inherited the fd, hence the bound.
        guard drained.wait(timeout: .now() + (timeout ?? 30)) != .timedOut else {
            return Capture(exitCode: nil, stdout: "", stderr: "output stream never closed", timedOut: true)
        }

        lock.lock()
        let out = stdoutData
        let err = stderrData
        lock.unlock()
        return Capture(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            timedOut: false
        )
    }

    /// Retained output cap per stream. Draining continues past this so the
    /// child never blocks; we just stop accumulating.
    static let defaultMaxCapturedBytes = 32 * 1024 * 1024

    private static let ioQueue = DispatchQueue(
        label: "com.seahelm.process-runner.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func drain(_ handle: FileHandle, maxCapturedBytes: Int) -> Data {
        // Closing is not optional. Reaching EOF does not release the read end,
        // and `Process` keeps its pipes alive past this scope, so without an
        // explicit close every call permanently leaks two descriptors. At the
        // poll rates here that reached ~2900 pipes (~48MB of kernel pipe
        // buffers) within minutes — which starves the machine-wide pipe budget
        // until the kernel hands out minimal buffers, and *that* is what makes
        // a mere 5KB write block in the first place. The leak is what turns a
        // latent deadlock into a certain one.
        defer { try? handle.close() }
        var captured = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if captured.count < maxCapturedBytes {
                captured.append(chunk.prefix(maxCapturedBytes - captured.count))
            }
        }
        return captured
    }

    /// Check if a command exists on PATH using login shell
    static func commandExists(_ command: String) -> Bool {
        commandPath(command) != nil
    }

    /// Default deadline for the short lookups here. `output` takes an explicit
    /// one because its callers range from `zmx list` to a user's whole test suite.
    static let lookupTimeout: TimeInterval = 10

    /// Resolve a command using the user's login shell PATH.
    /// `bash -l` sources the user's profile, so this is not the tiny one-liner it
    /// looks like — a chatty nvm/oh-my-zsh init can emit plenty on both streams.
    static func commandPath(_ command: String) -> String? {
        let result = capture(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["bash", "-lc", "command -v \(shellQuote(command))"],
            timeout: lookupTimeout
        )
        guard result.succeeded else { return nil }
        return result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Run a command and return trimmed stdout, or nil on failure.
    /// `timeout: nil` means no deadline — only for genuinely open-ended work
    /// like a user-configured inspection command.
    static func output(_ args: [String], timeout: TimeInterval? = lookupTimeout) -> String? {
        let result = capture(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: args,
            timeout: timeout
        )
        guard result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run a command, ignoring output. Logs errors.
    /// Output goes to /dev/null rather than an unread `Pipe()` — an unread pipe
    /// wedges the child forever once it fills, leaving a process nobody reaps.
    static func runFireAndForget(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("ProcessRunner: failed to run \(args.first ?? "?"): \(error)")
        }
    }

    /// Check if a command exists on PATH, calling back on the main queue.
    static func commandExistsAsync(_ command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = commandExists(command)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Run a command and return trimmed stdout via callback on the main queue.
    static func outputAsync(_ args: [String], completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = output(args)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Run a command synchronously, waiting for exit. Logs errors.
    /// When `currentDirectory` is set, the child inherits that cwd — needed for
    /// `zmx run`, whose session shell starts in the creator's working directory.
    static func runSync(_ args: [String], currentDirectory: String? = nil, timeout: TimeInterval = 60) {
        let result = capture(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: args,
            currentDirectory: currentDirectory,
            timeout: timeout
        )
        if result.timedOut {
            NSLog("ProcessRunner: timed out running \(args.first ?? "?")")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
