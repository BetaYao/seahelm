# New Task → Auto-Launch Agent + Auto-Summarized Title — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user creates a new task, pre-create its persistent backend session with the chosen agent (Claude/Codex) already running in the worktree — so it works in the background regardless of GUI focus — and show the task description as the card title (upgrading to the agent's own summary when available).

**Architecture:** zmx/tmux sessions are persistent server-side, named by `SessionManager.persistentSessionName(for:)`; the GUI surface only *attaches*. We pre-create the session detached with the agent running, leaving the surface lifecycle untouched. The fragile timer-based `launchAgent` keystroke path is removed. The title resolver gains a task-description tier between the Claude summary and the last-prompt fallback.

**Tech Stack:** Swift 5.10 / AppKit, XCTest, `Process` via `ProcessRunner`, tmux + zmx CLIs, XcodeGen.

**Verified runtime facts (do not re-derive):**
- `claude [options] [prompt]` and `codex [OPTIONS] [PROMPT]` both take the prompt as a positional arg and start interactive — so the task is passed as an argument, no send-keys race.
- `zmx run <name> <argv...>` creates the session if missing and **execs argv directly (no shell)**, inheriting the launching process's cwd. To run a shell line it needs `<shell> -lic '<line>'`. Keepalive form (verified): `zmx run <name> $SHELL -lic '<cmd>; exec "$0" -li' $SHELL`.
- tmux (verified): `tmux new-session -d -s <name> -c <cwd>` then `tmux send-keys -t <name> '<cmd>' Enter` — session persists, cwd correct, shell stays alive after the agent exits.
- `tmux has-session -t <name>` exits 0 (prints nothing) when it exists → `ProcessRunner.output(...)` returns `""` (non-nil) when present, `nil` when missing.

---

## Build & Test Commands

- Regenerate project after adding/removing files: `xcodegen generate`
- Build: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
- Run one test class: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/<ClassName>`
- Run one test method: `... -only-testing:amuxTests/<ClassName>/<methodName>`

> New `.swift` files under `Sources/` and `Tests/` are picked up by XcodeGen's globbing; run `xcodegen generate` before building/testing whenever a task creates a file.

---

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|-----------|
| `Sources/Core/ShellEscape.swift` | single-quote shell escaping helper | **new** |
| `Sources/Core/AgentType.swift` | `launchCommand(withTask:)` composing `<cmd> '<task>'` | modify |
| `Sources/Core/WorktreeTaskStore.swift` | persist task description per worktree path | **new** |
| `Sources/Core/WorktreeTitleResolver.swift` | add task-description tier | modify |
| `Sources/Core/SessionManager.swift` | `detachedLaunchCommands(...)` + `sessionExists(...)` + `createDetachedSession(...)` | modify |
| `Sources/App/MainWindowController.swift` | wire pre-launch + task store into create closure; delete `launchAgent` | modify |
| `Tests/ShellEscapeTests.swift` | escaping tests | **new** |
| `Tests/WorktreeTaskStoreTests.swift` | store round-trip tests | **new** |
| `Tests/SessionLaunchCommandTests.swift` | `detachedLaunchCommands` argv tests | **new** |
| `Tests/AgentTypeTests.swift` | add `launchCommand(withTask:)` tests | modify |
| `Tests/WorktreeTitleResolverTests.swift` | add task-tier tests | modify |

---

## Task 1: ShellEscape helper

**Files:**
- Create: `Sources/Core/ShellEscape.swift`
- Test: `Tests/ShellEscapeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/ShellEscapeTests.swift`:

```swift
import XCTest
@testable import amux

final class ShellEscapeTests: XCTestCase {
    func testWrapsPlainStringInSingleQuotes() {
        XCTAssertEqual(ShellEscape.singleQuote("fix the login bug"), "'fix the login bug'")
    }

    func testEscapesEmbeddedSingleQuote() {
        // can't => 'can'\''t'
        XCTAssertEqual(ShellEscape.singleQuote("can't"), "'can'\\''t'")
    }

    func testKeepsDollarAndDoubleQuoteLiteral() {
        XCTAssertEqual(ShellEscape.singleQuote("echo $HOME \"x\""), "'echo $HOME \"x\"'")
    }

    func testEmptyString() {
        XCTAssertEqual(ShellEscape.singleQuote(""), "''")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/ShellEscapeTests`
Expected: FAIL — `ShellEscape` undefined / does not compile.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Core/ShellEscape.swift`:

```swift
import Foundation

/// Shell-escaping helpers for building command strings that are interpreted by
/// a POSIX shell (e.g. agent launch commands sent to tmux/zmx sessions).
enum ShellEscape {
    /// Wrap a value in single quotes, safely escaping embedded single quotes.
    /// Everything else (including $, ", spaces) becomes literal.
    static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/ShellEscapeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ShellEscape.swift Tests/ShellEscapeTests.swift amux.xcodeproj
git commit -m "feat(core): add ShellEscape.singleQuote helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: AgentType.launchCommand(withTask:)

**Files:**
- Modify: `Sources/Core/AgentType.swift` (add method after `launchCommand` at line 62-76)
- Test: `Tests/AgentTypeTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/AgentTypeTests.swift` (inside the class):

```swift
    // MARK: - launchCommand(withTask:)

    func testLaunchCommandWithTaskComposesPositionalPrompt() {
        XCTAssertEqual(
            AgentType.claudeCode.launchCommand(withTask: "fix the login bug"),
            "claude 'fix the login bug'"
        )
        XCTAssertEqual(
            AgentType.codex.launchCommand(withTask: "add tests"),
            "codex 'add tests'"
        )
    }

    func testLaunchCommandWithEmptyTaskReturnsBareCommand() {
        XCTAssertEqual(AgentType.claudeCode.launchCommand(withTask: ""), "claude")
        XCTAssertEqual(AgentType.claudeCode.launchCommand(withTask: "   "), "claude")
    }

    func testLaunchCommandWithTaskEscapesQuotes() {
        XCTAssertEqual(
            AgentType.claudeCode.launchCommand(withTask: "can't stop"),
            "claude 'can'\\''t stop'"
        )
    }

    func testLaunchCommandWithTaskNilForNonAIAgent() {
        XCTAssertNil(AgentType.npm.launchCommand(withTask: "anything"))
        XCTAssertNil(AgentType.shellCommand.launchCommand(withTask: "anything"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/AgentTypeTests/testLaunchCommandWithTaskComposesPositionalPrompt`
Expected: FAIL — no such method `launchCommand(withTask:)`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Core/AgentType.swift`, immediately after the existing `launchCommand` computed property (after line 76):

```swift
    /// Full agent invocation including the task as the agent's initial prompt
    /// (a positional argument, e.g. `claude 'fix the bug'`). Returns nil for
    /// non-AI / shell types (those are not auto-launched). The task is
    /// shell-escaped because the result is interpreted by a POSIX shell.
    func launchCommand(withTask task: String) -> String? {
        guard let base = launchCommand else { return nil }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return "\(base) \(ShellEscape.singleQuote(trimmed))"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/AgentTypeTests`
Expected: PASS (existing + 4 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AgentType.swift Tests/AgentTypeTests.swift
git commit -m "feat(core): AgentType.launchCommand(withTask:) for prompt-on-launch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: WorktreeTaskStore

**Files:**
- Create: `Sources/Core/WorktreeTaskStore.swift`
- Test: `Tests/WorktreeTaskStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/WorktreeTaskStoreTests.swift`:

```swift
import XCTest
@testable import amux

final class WorktreeTaskStoreTests: XCTestCase {
    func testSetAndGetRoundTrip() {
        let path = "/tmp/amux-test-worktree-\(UUID().uuidString)"
        WorktreeTaskStore.shared.set("fix the login bug", forWorktree: path)
        XCTAssertEqual(WorktreeTaskStore.shared.task(forWorktree: path), "fix the login bug")
    }

    func testMissingPathReturnsNil() {
        XCTAssertNil(WorktreeTaskStore.shared.task(forWorktree: "/tmp/amux-never-set-\(UUID().uuidString)"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/WorktreeTaskStoreTests`
Expected: FAIL — `WorktreeTaskStore` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Core/WorktreeTaskStore.swift` (mirrors `WorktreeAgentTypeStore`):

```swift
import Foundation

/// Persists the task description entered at worktree-creation time, keyed by
/// worktree path, so the card/capsule title can show the user's task
/// immediately (before the agent has written its own session summary). Stored
/// as JSON alongside config.json (`~/.config/amux/worktree-tasks.json`).
final class WorktreeTaskStore {
    static let shared = WorktreeTaskStore()

    private let fileURL = Config.configDir.appendingPathComponent("worktree-tasks.json")
    private let lock = NSLock()
    private var map: [String: String]   // worktreePath -> task description

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// The task description recorded for this worktree path, if any.
    func task(forWorktree path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[path]
    }

    /// Record (and persist) the task description for a worktree path.
    func set(_ task: String, forWorktree path: String) {
        lock.lock()
        map[path] = task
        let snapshot = map
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [String: String]) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/WorktreeTaskStoreTests`
Expected: PASS (2 tests).

> Note: `testSetAndGetRoundTrip` reads from the in-memory map (the same instance just set it), so it passes regardless of async persist timing.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/WorktreeTaskStore.swift Tests/WorktreeTaskStoreTests.swift amux.xcodeproj
git commit -m "feat(core): WorktreeTaskStore persists task description per worktree

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: WorktreeTitleResolver task-description tier

**Files:**
- Modify: `Sources/Core/WorktreeTitleResolver.swift`
- Test: `Tests/WorktreeTitleResolverTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/WorktreeTitleResolverTests.swift` (inside the class):

```swift
    func testPrefersTaskOverPromptAndBranch() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "some detected prompt",
            branch: "feature/x",
            sessionTitle: { _ in nil },
            taskDescription: { _ in "Implement dark mode" }
        )
        XCTAssertEqual(title, "Implement dark mode")
    }

    func testSummaryStillWinsOverTask() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "prompt",
            branch: "br",
            sessionTitle: { _ in "AI Summary" },
            taskDescription: { _ in "the task" }
        )
        XCTAssertEqual(title, "AI Summary")
    }

    func testFallsThroughEmptyTaskToPrompt() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "the prompt",
            branch: "br",
            sessionTitle: { _ in nil },
            taskDescription: { _ in "   " }
        )
        XCTAssertEqual(title, "the prompt")
    }
```

Also update the three existing tests in this file to pass `taskDescription: { _ in nil }` so they keep exercising the prompt/branch fallbacks (otherwise the default closure reads the real store):

```swift
    func testFallsBackToPromptWhenNoSummary() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/nonexistent/path",
            lastUserPrompt: "Fix the login bug",
            branch: "feature/login",
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "Fix the login bug")
    }

    func testPrefersSessionTitle() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "prompt",
            branch: "br",
            sessionTitle: { _ in "Session Title" },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "Session Title")
    }

    func testFallsBackToBranchWhenEmpty() {
        let title = WorktreeTitleResolver.resolve(
            worktreePath: "/p",
            lastUserPrompt: "",
            branch: "feature/x",
            sessionTitle: { _ in nil },
            taskDescription: { _ in nil }
        )
        XCTAssertEqual(title, "feature/x")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/WorktreeTitleResolverTests/testPrefersTaskOverPromptAndBranch`
Expected: FAIL — `resolve` has no `taskDescription:` parameter.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `Sources/Core/WorktreeTitleResolver.swift` with:

```swift
import Foundation

/// Resolves the human-facing title for a worktree, shared by the top capsule and
/// the mini cards.
/// Order: Claude session summary → task description → last user prompt → branch.
enum WorktreeTitleResolver {
    static func resolve(
        worktreePath: String,
        lastUserPrompt: String,
        branch: String,
        sessionTitle: (String) -> String? = { SessionTitleLookup.title(worktreePath: $0) },
        taskDescription: (String) -> String? = { WorktreeTaskStore.shared.task(forWorktree: $0) }
    ) -> String {
        if let summary = sessionTitle(worktreePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let task = taskDescription(worktreePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !task.isEmpty {
            return task
        }
        let prompt = lastUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return prompt }
        return branch
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/WorktreeTitleResolverTests`
Expected: PASS (3 updated + 3 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/WorktreeTitleResolver.swift Tests/WorktreeTitleResolverTests.swift
git commit -m "feat(core): title resolver prefers stored task description

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: SessionManager detached launch

**Files:**
- Modify: `Sources/Core/SessionManager.swift` (add methods; the enum already has `persistentSessionName`, `parseZmxSessionNames`)
- Test: `Tests/SessionLaunchCommandTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SessionLaunchCommandTests.swift`:

```swift
import XCTest
@testable import amux

final class SessionLaunchCommandTests: XCTestCase {
    func testTmuxBuildsNewSessionThenSendKeys() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "tmux",
            name: "amux-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh"
        )
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(
            cmds[0],
            ["tmux", "new-session", "-d", "-s", "amux-repo-feat", "-c", "/work/repo/feat"]
        )
        XCTAssertEqual(
            cmds[1],
            ["tmux", "send-keys", "-t", "amux-repo-feat", "claude 'fix bug'", "Enter"]
        )
    }

    func testZmxBuildsRunWithShellWrapperAndCd() {
        let cmds = SessionManager.detachedLaunchCommands(
            backend: "zmx",
            name: "amux-repo-feat",
            cwd: "/work/repo/feat",
            agentCommandLine: "claude 'fix bug'",
            shell: "/bin/zsh"
        )
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(
            cmds[0],
            [
                "zmx", "run", "amux-repo-feat",
                "/bin/zsh", "-lic",
                "cd '/work/repo/feat' && claude 'fix bug'; exec \"$0\" -li",
                "/bin/zsh",
            ]
        )
    }

    func testUnknownBackendReturnsEmpty() {
        XCTAssertTrue(SessionManager.detachedLaunchCommands(
            backend: "local",
            name: "n", cwd: "/c", agentCommandLine: "claude", shell: "/bin/zsh"
        ).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/SessionLaunchCommandTests`
Expected: FAIL — no such method `detachedLaunchCommands`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/Core/SessionManager.swift`, add inside the `enum SessionManager` (e.g. before the closing brace):

```swift
    // MARK: - Detached agent launch

    /// Build the backend CLI invocation(s) that create a persistent session
    /// detached, with `agentCommandLine` running in `cwd` and a shell kept alive
    /// afterward. Returns an empty array for backends without persistent
    /// sessions. Pure (no process spawning) — unit-tested.
    static func detachedLaunchCommands(
        backend: String,
        name: String,
        cwd: String,
        agentCommandLine: String,
        shell: String
    ) -> [[String]] {
        switch backend {
        case "tmux":
            // Create the detached interactive shell in cwd, then type the agent
            // command into it. The shell persists after the agent exits.
            return [
                ["tmux", "new-session", "-d", "-s", name, "-c", cwd],
                ["tmux", "send-keys", "-t", name, agentCommandLine, "Enter"],
            ]
        case "zmx":
            // `zmx run` execs argv directly (no shell) and inherits cwd, so wrap
            // in a login shell that cd's, runs the agent, then execs an
            // interactive login shell ($0 = the trailing shell arg) to persist.
            let inner = "cd \(ShellEscape.singleQuote(cwd)) && \(agentCommandLine); exec \"$0\" -li"
            return [["zmx", "run", name, shell, "-lic", inner, shell]]
        default:
            return []
        }
    }

    /// Whether a persistent session with `name` already exists for `backend`.
    static func sessionExists(name: String, backend: String) -> Bool {
        switch backend {
        case "tmux":
            // has-session exits 0 (no stdout) when present → output() non-nil.
            return ProcessRunner.output(["tmux", "has-session", "-t", name]) != nil
        case "zmx":
            let list = ProcessRunner.output(["zmx", "list"]) ?? ""
            return parseZmxSessionNames(listOutput: list).contains(name)
        default:
            return false
        }
    }

    /// Create a detached session running the agent, unless one already exists.
    /// Spawns processes synchronously — call off the main thread.
    /// Returns whether a new session was launched.
    @discardableResult
    static func createDetachedSession(
        name: String,
        backend: String,
        cwd: String,
        agentCommandLine: String
    ) -> Bool {
        guard backend == "tmux" || backend == "zmx" else { return false }
        if sessionExists(name: name, backend: backend) { return false }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let commands = detachedLaunchCommands(
            backend: backend, name: name, cwd: cwd,
            agentCommandLine: agentCommandLine, shell: shell
        )
        guard !commands.isEmpty else { return false }
        for argv in commands {
            ProcessRunner.runSync(argv)
        }
        return true
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test -only-testing:amuxTests/SessionLaunchCommandTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/SessionManager.swift Tests/SessionLaunchCommandTests.swift amux.xcodeproj
git commit -m "feat(core): SessionManager.createDetachedSession for background agent launch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire pre-launch into worktree creation; remove launchAgent

**Files:**
- Modify: `Sources/App/MainWindowController.swift` (create closure at lines 411-434; delete `launchAgent` at 573-586)

This task has no unit test (it's GUI wiring); it is verified by build + the manual checklist in Task 7. Keep the change minimal and exactly as below.

- [ ] **Step 1: Add task store + pre-launch in the create closure (background queue)**

In the `onCreate` closure, the block that currently reads (around lines 419-421):

```swift
                    let info = try WorktreeCreator.createWorktree(repoPath: repoPath, branchName: branchName, baseBranch: base)
                    WorktreeAgentTypeStore.shared.set(agentType, forWorktree: info.path)
                    if reuseEnv, let currentPath { WorktreeCreator.copyEnvironmentFiles(from: currentPath, to: info.path) }
```

becomes:

```swift
                    let info = try WorktreeCreator.createWorktree(repoPath: repoPath, branchName: branchName, baseBranch: base)
                    WorktreeAgentTypeStore.shared.set(agentType, forWorktree: info.path)
                    WorktreeTaskStore.shared.set(taskDescription, forWorktree: info.path)
                    if reuseEnv, let currentPath { WorktreeCreator.copyEnvironmentFiles(from: currentPath, to: info.path) }
                    // Pre-create the persistent session with the agent already
                    // running, server-side, before the GUI attaches. Runs on
                    // this background queue (synchronous process spawns).
                    if let agentCommandLine = agentType.launchCommand(withTask: taskDescription) {
                        SessionManager.createDetachedSession(
                            name: SessionManager.persistentSessionName(for: info.path),
                            backend: self.config.backend,
                            cwd: info.path,
                            agentCommandLine: agentCommandLine
                        )
                    }
```

- [ ] **Step 2: Remove the launchAgent call (main-queue block)**

In the same closure's `DispatchQueue.main.async` block, delete this line (currently line 425):

```swift
                        self.launchAgent(agentType, inWorktree: info.path, taskDescription: taskDescription)
```

- [ ] **Step 3: Delete the now-unused launchAgent method**

Delete the entire method at lines 573-586:

```swift
    /// Best-effort: type the selected agent's launch command into the new
    /// worktree's terminal once its session has had a moment to attach.
    private func launchAgent(_ agentType: AgentType, inWorktree path: String, taskDescription: String? = nil) {
        guard let command = agentType.launchCommand else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let surface = AgentHead.shared.agent(forWorktree: path)?.surface else { return }
            surface.sendText(command + "\r")
            if let taskDescription, !taskDescription.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    surface.sendText(taskDescription + "\r")
                }
            }
        }
    }
```

- [ ] **Step 4: Build the app**

Run: `xcodebuild -project amux.xcodeproj -scheme amux -configuration Debug build`
Expected: BUILD SUCCEEDED, with no remaining references to `launchAgent` (grep to confirm: `grep -rn "launchAgent" Sources` returns nothing).

- [ ] **Step 5: Commit**

```bash
git add Sources/App/MainWindowController.swift
git commit -m "feat(app): launch agent in background session on new task; drop timer-based launch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Full test run + manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full unit-test suite**

Run: `xcodebuild -project amux.xcodeproj -scheme amuxTests -configuration Debug test`
Expected: all tests PASS (including the new ShellEscape / WorktreeTaskStore / SessionLaunchCommand / AgentType / WorktreeTitleResolver tests).

- [ ] **Step 2: Manual verification — background launch (zmx, the default backend)**

1. Launch the app (build & run, or use the `pmux-screenshot-imessage` / `run` skill).
2. Create a new task: pick **Claude**, enter a task like "list the files in this repo".
3. **Without opening the card**, in a terminal run `zmx list` and confirm a new `amux-<repo>-<branch>` session exists with `start_dir` = the new worktree path.
4. Open the card. Expected: Claude is already running and has the task as its first prompt (it did not wait for you to open the card).
5. Repeat for a second task to confirm two agents run in parallel without opening either card first.

- [ ] **Step 3: Manual verification — title**

1. Right after creating the task (before any Claude summary exists), the mini card / capsule shows the **task description** (not the branch name).
2. After Claude has run long enough to write a summary (`~/.claude/projects/<encoded>/<id>.jsonl` gains a `summary` record), within ~8s (the `WorktreeTitleCache` TTL) the title upgrades to Claude's summary.

- [ ] **Step 4: Manual verification — idempotency & shell persistence**

1. Quit and relaunch the app. Confirm creating a task whose session already exists does not spawn a duplicate / restart the agent (`createDetachedSession` returns early on existing sessions).
2. In an opened agent card, exit the agent (e.g. quit Claude). Confirm you land at a shell prompt in the worktree (the session stays alive).

- [ ] **Step 5 (optional): switch backend to tmux and re-verify**

If you also support tmux: set `~/.config/amux/config.json` `"backend": "tmux"`, relaunch, and repeat Step 2. Confirm `tmux ls` shows the session and Claude runs in it.

---

## Self-Review Notes (author)

- **Spec coverage:** Part A (reliable background launch) → Tasks 2, 5, 6. Part B (auto-summarized title) → Tasks 3, 4. Shell-escaping risk → Task 1. zmx CLI verification → resolved up front (verified facts header) and confirmed in Task 7 manual checklist.
- **Type consistency:** `detachedLaunchCommands` / `sessionExists` / `createDetachedSession` signatures match between Task 5 implementation and its tests and the Task 6 call site (`createDetachedSession(name:backend:cwd:agentCommandLine:)`). `launchCommand(withTask:)` matches between Task 2 and Task 6. `WorktreeTaskStore.task(forWorktree:)` / `set(_:forWorktree:)` match across Tasks 3, 4, 6. `WorktreeTitleResolver.resolve` new `taskDescription:` param matches Task 4 tests.
- **No placeholders:** every code step contains full code; every run step has an exact command and expected outcome.
