# Agent Worktree Session Fork Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep an agent running in its source Seahelm pane while starting an independent fork of its native conversation in a newly created Git worktree.

**Architecture:** Replace the current UI-only tree transfer with a per-pane runtime identity store, exact Git-repository/path correlation, agent-specific fork adapters, and a two-phase coordinator that launches a new zmx-backed target station. Automatic behavior is allowed only when source pane, native session, repository, target path, and native fork capability are all known; Cursor and ambiguous discoveries become explicit First Mate actions.

**Tech Stack:** Swift 5.10, AppKit, Foundation `Process`, Git worktrees, zmx, JSON-RPC Unix socket, XCTest, XcodeGen.

---

## File map

### New production files

- `Sources/Core/AgentRuntimeIdentity.swift` — persisted per-pane native session identity and thread-safe lookup store.
- `Sources/Git/GitRepositoryIdentity.swift` — canonical Git common-directory identity used for source/target validation.
- `Sources/Core/AgentSessionForkAdapter.swift` — capability model, four agent adapters, argv construction, and adapter registry.
- `Sources/Core/WorktreeForkIntent.swift` — intent state machine and exact target correlation.
- `Sources/Core/WorktreeSessionForkCoordinator.swift` — two-phase fork orchestration with injected launcher/readiness seams.
- `Sources/Core/WorktreeForkPresentationStore.swift` — per-worktree launching/failed/unsupported state consumed by dashboard and First Mate.

### New test files

- `Tests/AgentRuntimeIdentityTests.swift`
- `Tests/GitRepositoryIdentityTests.swift`
- `Tests/AgentSessionForkAdapterTests.swift`
- `Tests/WorktreeForkIntentTests.swift`
- `Tests/WorktreeSessionForkCoordinatorTests.swift`
- `Tests/WorktreeForkPresentationTests.swift`

### Existing files to modify

- `Sources/Core/ClaudeHooksSetup.swift` and `Tests/SeahelmHookInstallerTests.swift` — remove the unsafe reporting-only `WorktreeCreate` hook.
- `Sources/Core/PendingWorktreeTransfer.swift`, `Sources/App/TabCoordinator.swift`, and `Tests/PaneTransferTests.swift` — retire basename/whole-tree automatic transfer.
- `Sources/Core/Config.swift`, `Sources/Terminal/Station.swift`, and `Sources/App/TerminalCoordinator.swift` — persist and restore per-pane runtime identity; support a reserved target launch.
- `Sources/Status/WebhookStatusProvider.swift` and `Sources/Status/WebhookEvent.swift` — report exact pane/session identity and fork readiness.
- `Sources/Core/SessionManager.swift` and `Sources/Core/ShellEscape.swift` — launch an argv-derived fork command in a detached backend session.
- `Sources/Core/ControlProtocol.swift`, `Sources/Core/SeahelmControlDataSource.swift`, `Sources/Core/SeahelmCliInstaller.swift`, and their tests — add `worktree.fork` / `seahelm worktree fork`.
- `Sources/App/MainWindowController.swift` — connect Seahelm-created worktrees to the coordinator behind a disabled-by-default feature preference.
- `Sources/Core/OpenCodePluginInstaller.swift` and `Tests/OpenCodePluginInstallerTests.swift` — emit OpenCode session identity.
- `Sources/Core/FirstMate.swift`, `Sources/Core/PendingOrdersQueue.swift`, `Sources/UI/SidePanel/BridgePanelViewController.swift`, `Sources/UI/Dashboard/DashboardViewController.swift`, `Sources/UI/Dashboard/MiniCardView.swift`, and tests — surface launching, retry, handoff, and unsupported states.

## Task 1: Remove unsafe worktree transfer behavior

**Files:**

- Modify: `Sources/Core/ClaudeHooksSetup.swift`
- Modify: `Sources/App/TabCoordinator.swift`
- Delete: `Sources/Core/PendingWorktreeTransfer.swift`
- Modify: `Tests/SeahelmHookInstallerTests.swift`
- Modify: `Tests/PaneTransferTests.swift`

- [ ] **Step 1: Add an inspectable Claude hook-event list and failing safety test**

Add this test to `ClaudeHooksMigrationTests`:

```swift
func testSeahelmDoesNotInstallReportingOnlyWorktreeCreateHook() {
    XCTAssertFalse(ClaudeHooksSetup.requiredEventNamesForTesting.contains("WorktreeCreate"))
    XCTAssertTrue(ClaudeHooksSetup.requiredEventNamesForTesting.contains("SessionStart"))
}
```

Expose the test seam in `ClaudeHooksSetup` without changing behavior yet:

```swift
static var requiredEventNamesForTesting: Set<String> {
    Set(requiredHooks().keys)
}
```

- [ ] **Step 2: Run the focused test and verify the unsafe baseline fails**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/ClaudeHooksMigrationTests/testSeahelmDoesNotInstallReportingOnlyWorktreeCreateHook test
```

Expected: FAIL because `requiredHooks()` still contains `WorktreeCreate`.

- [ ] **Step 3: Remove `WorktreeCreate` from installed hooks**

Delete this dictionary entry from `requiredHooks()`:

```swift
"WorktreeCreate": hookGroup,
```

Do not replace it with another passive hook. Claude requires a `WorktreeCreate` hook to create and return the target path, which is outside this reporting bridge.

- [ ] **Step 4: Replace the old transfer tests with a source-preservation regression**

Delete tests for `PendingTransferTracker` and `StationManager.transferTree`. Add this test to `PaneTransferTests` before removing the production callback:

```swift
func testDiscoveredWorktreeDoesNotRehomeSourceTree() {
    let coordinator = makeCoordinator()
    let source = WorktreeInfo(path: "/repo", branch: "main", commitHash: "a", isMainWorktree: true)
    let target = WorktreeInfo(path: "/repo-worktrees/task/x", branch: "task/x", commitHash: "b", isMainWorktree: false)
    let sourceTree = coordinator.terminalCoordinator.stationManager.tree(for: source, backend: "zmx")
    coordinator.allWorktrees = [(info: source, tree: sourceTree)]
    coordinator.worktreeRepoCache[source.path] = source.path

    coordinator.reconcileDiscoveredWorktrees(
        tabIndex: coordinator.workspaceManager.addTab(repoPath: source.path, worktrees: [source]),
        oldWorktrees: [source],
        freshWorktrees: [source, target]
    )

    XCTAssertTrue(coordinator.terminalCoordinator.stationManager.tree(forPath: source.path) === sourceTree)
    XCTAssertNotNil(coordinator.terminalCoordinator.stationManager.tree(forPath: target.path))
}
```

Add this helper inside `PaneTransferTests`:

```swift
private func makeCoordinator() -> TabCoordinator {
    let config = Config()
    let coordinator = TabCoordinator(config: config)
    coordinator.terminalCoordinator = TerminalCoordinator(config: config, activeSplitContainer: { nil })
    coordinator.statusPublisher = StatusPublisher(agentConfig: config.agentDetect)
    coordinator.statusAggregator = WorktreeStatusAggregator()
    return coordinator
}
```

- [ ] **Step 5: Remove old intent/transfer wiring**

In `TabCoordinator`:

- remove `pendingTransfers`;
- remove `onWorktreeCreateReceived` registration;
- make `integrateNewWorktrees` always create/register a fresh target tree;
- delete `performPaneTransfer`.

Delete `Sources/Core/PendingWorktreeTransfer.swift`. Keep `StationManager.transferTree` only if another call site remains; otherwise delete it and its tests.

- [ ] **Step 6: Run safety regressions**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/ClaudeHooksMigrationTests \
  -only-testing:seahelmTests/PaneTransferTests test
```

Expected: PASS; source tree remains registered and Claude hook configuration excludes `WorktreeCreate`.

- [ ] **Step 7: Commit the safety baseline**

```bash
git add Sources/Core/ClaudeHooksSetup.swift Sources/App/TabCoordinator.swift \
  Sources/Core/PendingWorktreeTransfer.swift Sources/Core/StationManager.swift \
  Tests/SeahelmHookInstallerTests.swift Tests/PaneTransferTests.swift
git commit -m "fix: stop rehoming agents on worktree discovery"
```

## Task 2: Add per-pane runtime identity and Git repository identity

**Files:**

- Create: `Sources/Core/AgentRuntimeIdentity.swift`
- Create: `Sources/Git/GitRepositoryIdentity.swift`
- Modify: `Sources/Core/Config.swift`
- Modify: `Sources/App/TabCoordinator.swift`
- Modify: `Sources/App/TerminalCoordinator.swift`
- Create: `Tests/AgentRuntimeIdentityTests.swift`
- Create: `Tests/GitRepositoryIdentityTests.swift`
- Modify: `Tests/AgentSessionRefTests.swift`

- [ ] **Step 1: Write failing identity-store tests**

Create `Tests/AgentRuntimeIdentityTests.swift`:

```swift
import XCTest
@testable import seahelm

final class AgentRuntimeIdentityTests: XCTestCase {
    private let ref = AgentSessionRef(
        agent: "codex", sessionId: "f637907b-a9b7-429a-941c-b407fe2487ee")!

    func testIdentityIsKeyedByStablePaneID() {
        let store = AgentRuntimeIdentityStore()
        let identity = AgentRuntimeIdentity(
            paneID: "amux-seahelm-main-2", nativeSession: ref,
            observedCwd: "/repo", repositoryIdentity: "/repo/.git", observedAt: Date())
        store.record(identity)
        XCTAssertEqual(store.identity(forPaneID: "amux-seahelm-main-2"), identity)
    }

    func testEventWithoutPaneIDIsNotForkEligible() {
        let store = AgentRuntimeIdentityStore()
        XCTAssertFalse(store.record(
            paneID: nil, nativeSession: ref, cwd: "/repo", repositoryIdentity: "/repo/.git"))
        XCTAssertTrue(store.all().isEmpty)
    }
}
```

- [ ] **Step 2: Write the failing Git common-directory test**

Create `Tests/GitRepositoryIdentityTests.swift` using a temporary repository and linked worktree:

```swift
func testMainAndLinkedWorktreeShareRepositoryIdentity() throws {
    let fixture = try GitWorktreeFixture()
    defer { fixture.cleanup() }
    let linked = try fixture.addWorktree(named: "feature")
    XCTAssertEqual(
        GitRepositoryIdentity.resolve(path: fixture.root.path),
        GitRepositoryIdentity.resolve(path: linked.path))
}
```

Create `Tests/Helpers/GitWorktreeFixture.swift` with the complete fixture:

```swift
import Foundation

final class GitWorktreeFixture {
    let root: URL
    private let parent: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-git-fixture-\(UUID().uuidString)")
        root = parent.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try run(["init", "-b", "main"], at: root)
        try "seed".write(to: root.appendingPathComponent("seed.txt"),
                         atomically: true, encoding: .utf8)
        try run(["add", "seed.txt"], at: root)
        try run(["-c", "user.name=Seahelm Tests", "-c", "user.email=tests@seahelm.local",
                 "commit", "-m", "seed"], at: root)
    }

    func addWorktree(named name: String) throws -> URL {
        let target = parent.appendingPathComponent("repo-worktrees/\(name)")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try run(["worktree", "add", "-b", name, target.path], at: root)
        return target
    }

    func cleanup() { try? FileManager.default.removeItem(at: parent) }

    private func run(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            throw NSError(domain: "GitWorktreeFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "git failed"])
        }
    }
}
```

- [ ] **Step 3: Run both new test classes and verify they fail to compile**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/AgentRuntimeIdentityTests \
  -only-testing:seahelmTests/GitRepositoryIdentityTests test
```

Expected: FAIL because the new production types do not exist.

- [ ] **Step 4: Implement the identity model and store**

Create `Sources/Core/AgentRuntimeIdentity.swift`:

```swift
import Foundation

struct AgentRuntimeIdentity: Codable, Equatable {
    let paneID: String
    let nativeSession: AgentSessionRef
    let observedCwd: String
    let repositoryIdentity: String
    let observedAt: Date
}

final class AgentRuntimeIdentityStore {
    private let lock = NSLock()
    private var identities: [String: AgentRuntimeIdentity]

    init(initial: [String: AgentRuntimeIdentity] = [:]) { identities = initial }

    func record(_ identity: AgentRuntimeIdentity) {
        lock.lock(); defer { lock.unlock() }
        identities[identity.paneID] = identity
    }

    @discardableResult
    func record(paneID: String?, nativeSession: AgentSessionRef, cwd: String,
                repositoryIdentity: String) -> Bool {
        guard let paneID, !paneID.isEmpty else { return false }
        record(AgentRuntimeIdentity(paneID: paneID, nativeSession: nativeSession,
                                    observedCwd: cwd, repositoryIdentity: repositoryIdentity,
                                    observedAt: Date()))
        return true
    }

    func identity(forPaneID paneID: String) -> AgentRuntimeIdentity? {
        lock.lock(); defer { lock.unlock() }
        return identities[paneID]
    }

    func all() -> [String: AgentRuntimeIdentity] {
        lock.lock(); defer { lock.unlock() }
        return identities
    }
}
```

- [ ] **Step 5: Implement Git common-directory resolution**

Create `Sources/Git/GitRepositoryIdentity.swift`:

```swift
import Foundation

enum GitRepositoryIdentity {
    static func resolve(path: String) -> String? {
        guard let raw = ProcessRunner.output(["git", "-C", path, "rev-parse", "--git-common-dir"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: path).appendingPathComponent(raw)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
```

- [ ] **Step 6: Persist identities without breaking legacy session recovery**

Add to `Config`:

```swift
var agentRuntimeIdentities: [String: AgentRuntimeIdentity]
```

Use JSON key `agent_runtime_identities`, default it to `[:]`, and leave `agentSessions` intact for backward-compatible zmx recovery. Add this round-trip test to `AgentSessionRefTests`:

```swift
func testConfigRoundTripCarriesRuntimeIdentity() throws {
    var config = Config()
    let ref = AgentSessionRef(agent: "codex", sessionId: uuid)!
    config.agentRuntimeIdentities["amux-repo-main"] = AgentRuntimeIdentity(
        paneID: "amux-repo-main", nativeSession: ref, observedCwd: "/repo",
        repositoryIdentity: "/repo/.git", observedAt: Date(timeIntervalSince1970: 1))
    let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
    XCTAssertEqual(decoded.agentRuntimeIdentities["amux-repo-main"]?.nativeSession, ref)
}
```

- [ ] **Step 7: Record hook identity against the emitting pane**

Change `TabCoordinator.recordAgentSession` to accept `paneID`, resolve its real station by stable session name, update both `agentSessions[paneID]` and `agentRuntimeIdentities[paneID]`, and refuse fork identity when repository resolution fails:

```swift
private func recordAgentSession(worktreePath: String, paneID: String?, ref: AgentSessionRef) {
    guard let paneID, let repositoryIdentity = GitRepositoryIdentity.resolve(path: worktreePath) else { return }
    let identity = AgentRuntimeIdentity(paneID: paneID, nativeSession: ref,
        observedCwd: worktreePath, repositoryIdentity: repositoryIdentity, observedAt: Date())
    runtimeIdentityStore.record(identity)
    config.agentRuntimeIdentities[paneID] = identity
    config.agentSessions[paneID] = ref
    StationRegistry.shared.station(forSessionName: paneID)?.agentSessionRef = ref
    saveConfig()
}
```

Add this property beside `pendingOrders` in `TabCoordinator`:

```swift
lazy var runtimeIdentityStore = AgentRuntimeIdentityStore(initial: config.agentRuntimeIdentities)
```

Update `WebhookStatusProvider.onAgentSessionResolved` to include `event.paneId`, and update the callback wiring accordingly.

- [ ] **Step 8: Run identity and existing restore tests**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/AgentRuntimeIdentityTests \
  -only-testing:seahelmTests/GitRepositoryIdentityTests \
  -only-testing:seahelmTests/AgentSessionRefTests \
  -only-testing:seahelmTests/SessionRestoreConfigTests test
```

Expected: PASS.

- [ ] **Step 9: Commit runtime identity**

```bash
git add Sources/Core/AgentRuntimeIdentity.swift Sources/Git/GitRepositoryIdentity.swift \
  Sources/Core/Config.swift Sources/App/TabCoordinator.swift Sources/App/TerminalCoordinator.swift \
  Sources/Status/WebhookStatusProvider.swift Tests/AgentRuntimeIdentityTests.swift \
  Tests/GitRepositoryIdentityTests.swift Tests/Helpers/GitWorktreeFixture.swift \
  Tests/AgentSessionRefTests.swift
git commit -m "feat: track native agent sessions per pane"
```

## Task 3: Implement native session fork adapters

**Files:**

- Create: `Sources/Core/AgentSessionForkAdapter.swift`
- Create: `Tests/AgentSessionForkAdapterTests.swift`

- [ ] **Step 1: Write the complete adapter contract tests**

Create `Tests/AgentSessionForkAdapterTests.swift`:

```swift
import XCTest
@testable import seahelm

final class AgentSessionForkAdapterTests: XCTestCase {
    private let id = "f637907b-a9b7-429a-941c-b407fe2487ee"

    func testCodexForkArgv() throws {
        let ref = AgentSessionRef(agent: "codex", sessionId: id)!
        XCTAssertEqual(try CodexForkAdapter().forkArgv(session: ref, targetPath: "/wt"),
                       ["codex", "fork", id, "-C", "/wt"])
    }

    func testClaudeForkArgv() throws {
        let ref = AgentSessionRef(agent: "claude", sessionId: id)!
        XCTAssertEqual(try ClaudeForkAdapter().forkArgv(session: ref, targetPath: "/wt"),
                       ["claude", "--resume", id, "--fork-session"])
    }

    func testOpenCodeForkArgv() throws {
        let ref = AgentSessionRef(agent: "opencode", sessionId: id)!
        XCTAssertEqual(try OpenCodeForkAdapter().forkArgv(session: ref, targetPath: "/wt"),
                       ["opencode", "/wt", "--session", id, "--fork"])
    }

    func testCursorIsResumeOnly() {
        XCTAssertEqual(CursorForkAdapter().capability(helpText: "--resume [chatId]"), .resumeOnly)
    }

    func testMissingForkFlagIsUnavailable() {
        XCTAssertEqual(ClaudeForkAdapter().capability(helpText: "--resume <id>"),
                       .unavailable(reason: "installed Claude CLI lacks --fork-session"))
    }
}
```

- [ ] **Step 2: Run the adapter tests and verify they fail to compile**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/AgentSessionForkAdapterTests test
```

Expected: FAIL because adapter types do not exist.

- [ ] **Step 3: Implement capability and adapter types**

Create `Sources/Core/AgentSessionForkAdapter.swift` with:

```swift
import Foundation

enum ForkCapability: Equatable {
    case nativeFork
    case resumeOnly
    case unavailable(reason: String)
}

enum AgentSessionForkError: Error, Equatable {
    case wrongAgent(expected: String, actual: String)
    case unsupported(String)
}

protocol AgentSessionForkAdapter {
    var agent: String { get }
    func capability(helpText: String) -> ForkCapability
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String]
}

struct CodexForkAdapter: AgentSessionForkAdapter {
    let agent = "codex"
    func capability(helpText: String) -> ForkCapability {
        helpText.contains("fork") ? .nativeFork : .unavailable(reason: "installed Codex CLI lacks fork")
    }
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String] {
        guard session.agent == agent else { throw AgentSessionForkError.wrongAgent(expected: agent, actual: session.agent) }
        return ["codex", "fork", session.sessionId, "-C", targetPath]
    }
}

struct ClaudeForkAdapter: AgentSessionForkAdapter {
    let agent = "claude"
    func capability(helpText: String) -> ForkCapability {
        helpText.contains("--fork-session") ? .nativeFork
            : .unavailable(reason: "installed Claude CLI lacks --fork-session")
    }
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String] {
        guard session.agent == agent else { throw AgentSessionForkError.wrongAgent(expected: agent, actual: session.agent) }
        return ["claude", "--resume", session.sessionId, "--fork-session"]
    }
}

struct OpenCodeForkAdapter: AgentSessionForkAdapter {
    let agent = "opencode"
    func capability(helpText: String) -> ForkCapability {
        helpText.contains("--fork") ? .nativeFork
            : .unavailable(reason: "installed OpenCode CLI lacks --fork")
    }
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String] {
        guard session.agent == agent else { throw AgentSessionForkError.wrongAgent(expected: agent, actual: session.agent) }
        return ["opencode", targetPath, "--session", session.sessionId, "--fork"]
    }
}

struct CursorForkAdapter: AgentSessionForkAdapter {
    let agent = "cursor"
    func capability(helpText: String) -> ForkCapability { .resumeOnly }
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String] {
        throw AgentSessionForkError.unsupported("Cursor exposes resume but not native fork")
    }
}
```

Add the provider contract and registry in the same file:

```swift
protocol AgentForkAdapterProviding {
    func adapter(for agent: String) -> AgentSessionForkAdapter?
    func capability(for adapter: AgentSessionForkAdapter) -> ForkCapability
}

struct AgentSessionForkAdapterRegistry: AgentForkAdapterProviding {
    private let adapters: [String: AgentSessionForkAdapter]
    private let helpText: (String) -> String

    init(helpText: @escaping (String) -> String = { executable in
        ProcessRunner.output([executable, "--help"]) ?? ""
    }) {
        let values: [AgentSessionForkAdapter] = [
            CodexForkAdapter(), ClaudeForkAdapter(), OpenCodeForkAdapter(), CursorForkAdapter()
        ]
        adapters = Dictionary(uniqueKeysWithValues: values.map { ($0.agent, $0) })
        self.helpText = helpText
    }

    func adapter(for agent: String) -> AgentSessionForkAdapter? { adapters[agent] }
    func capability(for adapter: AgentSessionForkAdapter) -> ForkCapability {
        adapter.capability(helpText: helpText(adapter.agent == "cursor" ? "cursor-agent" : adapter.agent))
    }
}
```

Do not use version-number comparisons.

- [ ] **Step 4: Run adapter tests**

Run the command from Step 2.

Expected: PASS with five tests.

- [ ] **Step 5: Commit adapters**

```bash
git add Sources/Core/AgentSessionForkAdapter.swift Tests/AgentSessionForkAdapterTests.swift
git commit -m "feat: add native session fork adapters"
```

## Task 4: Replace basename tracking with an exact fork-intent state machine

**Files:**

- Create: `Sources/Core/WorktreeForkIntent.swift`
- Create: `Tests/WorktreeForkIntentTests.swift`

- [ ] **Step 1: Write failing intent-correlation tests**

Create tests covering exact path, same-name cross-repo rejection, expiry, and single consumption:

```swift
func testExactTargetAndRepositoryConsumeIntent() {
    let tracker = WorktreeForkIntentTracker(ttl: 30)
    let intent = fixtureIntent(target: "/repo-wt/feature", repository: "/repo/.git")
    tracker.record(intent)
    XCTAssertEqual(tracker.resolve(targetPath: "/repo-wt/feature",
                                   repositoryIdentity: "/repo/.git")?.id, intent.id)
    XCTAssertNil(tracker.resolve(targetPath: "/repo-wt/feature",
                                 repositoryIdentity: "/repo/.git"))
}

func testSameBasenameInDifferentRepositoryDoesNotMatch() {
    let tracker = WorktreeForkIntentTracker(ttl: 30)
    tracker.record(fixtureIntent(target: "/a-wt/feature", repository: "/a/.git"))
    XCTAssertNil(tracker.resolve(targetPath: "/b-wt/feature", repositoryIdentity: "/b/.git"))
}
```

Add this helper inside `WorktreeForkIntentTests`:

```swift
private func fixtureIntent(target: String, repository: String) -> WorktreeForkIntent {
    WorktreeForkIntent(
        id: UUID(), sourcePaneID: "amux-repo-main", sourceWorktreePath: "/repo",
        repositoryIdentity: repository,
        nativeSession: AgentSessionRef(agent: "codex",
            sessionId: "f637907b-a9b7-429a-941c-b407fe2487ee")!,
        requestedTargetPath: target, createdAt: Date(), state: .recorded)
}
```

- [ ] **Step 2: Run the intent tests and verify they fail to compile**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/WorktreeForkIntentTests test
```

Expected: FAIL because intent types do not exist.

- [ ] **Step 3: Implement the state machine and tracker**

Create:

```swift
import Foundation

struct WorktreeForkIntent: Equatable, Identifiable {
    enum State: Equatable { case recorded, targetResolved, launching, ready, failed(String), expired }
    let id: UUID
    let sourcePaneID: String
    let sourceWorktreePath: String
    let repositoryIdentity: String
    let nativeSession: AgentSessionRef
    let requestedTargetPath: String
    let createdAt: Date
    var state: State
}

final class WorktreeForkIntentTracker {
    private let lock = NSLock()
    private let ttl: TimeInterval
    private var intents: [UUID: WorktreeForkIntent] = [:]

    init(ttl: TimeInterval = 30) { self.ttl = ttl }

    func record(_ intent: WorktreeForkIntent) {
        lock.lock(); defer { lock.unlock() }
        intents[intent.id] = intent
    }

    func resolve(targetPath: String, repositoryIdentity: String, now: Date = Date()) -> WorktreeForkIntent? {
        lock.lock(); defer { lock.unlock() }
        for (id, var intent) in intents where now.timeIntervalSince(intent.createdAt) > ttl {
            intent.state = .expired; intents[id] = intent
        }
        guard let pair = intents.first(where: {
            $0.value.state == .recorded &&
            URL(fileURLWithPath: $0.value.requestedTargetPath).standardizedFileURL.path ==
                URL(fileURLWithPath: targetPath).standardizedFileURL.path &&
            $0.value.repositoryIdentity == repositoryIdentity
        }) else { return nil }
        var resolved = pair.value
        resolved.state = .targetResolved
        intents[pair.key] = resolved
        return resolved
    }

    func transition(id: UUID, to state: WorktreeForkIntent.State) {
        lock.lock(); defer { lock.unlock() }
        guard var intent = intents[id] else { return }
        intent.state = state; intents[id] = intent
    }
}
```

Add `state(id:)` and `nonTerminalIntents()` accessors used by coordinator recovery tests; both return copies under the lock.

- [ ] **Step 4: Run intent tests**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit exact intent correlation**

```bash
git add Sources/Core/WorktreeForkIntent.swift Tests/WorktreeForkIntentTests.swift
git commit -m "feat: correlate worktree forks by repository and path"
```

## Task 5: Build the two-phase fork coordinator

**Files:**

- Create: `Sources/Core/WorktreeSessionForkCoordinator.swift`
- Modify: `Sources/Core/SessionManager.swift`
- Modify: `Sources/Core/ShellEscape.swift`
- Modify: `Sources/App/TerminalCoordinator.swift`
- Modify: `Sources/Terminal/Station.swift`
- Create: `Tests/WorktreeSessionForkCoordinatorTests.swift`
- Modify: `Tests/SessionLaunchCommandTests.swift`

- [ ] **Step 1: Write failing coordinator success and rollback tests**

Use fakes for every side effect:

```swift
func testSuccessfulForkKeepsSourceAndMarksTargetReady() async throws {
    let fixture = CoordinatorFixture(capability: .nativeFork, readiness: true)
    let result = await fixture.coordinator.fork(fixture.intent)
    XCTAssertEqual(result, .ready(targetPaneID: "target-session"))
    XCTAssertEqual(fixture.launcher.launched.count, 1)
    XCTAssertFalse(fixture.launcher.destroyed.contains("source-session"))
    XCTAssertEqual(fixture.tracker.state(id: fixture.intent.id), .ready)
}

func testReadinessTimeoutDestroysOnlyTargetAttempt() async throws {
    let fixture = CoordinatorFixture(capability: .nativeFork, readiness: false)
    let result = await fixture.coordinator.fork(fixture.intent)
    XCTAssertEqual(result, .failed("agent did not become ready"))
    XCTAssertEqual(fixture.launcher.destroyed, ["target-session"])
    XCTAssertFalse(fixture.launcher.destroyed.contains("source-session"))
}

func testCursorNeverLaunchesConcurrentResume() async throws {
    let fixture = CoordinatorFixture(agent: "cursor", capability: .resumeOnly, readiness: true)
    XCTAssertEqual(await fixture.coordinator.fork(fixture.intent), .unsupportedResumeOnly)
    XCTAssertTrue(fixture.launcher.launched.isEmpty)
}
```

Add these complete test doubles below the test class:

```swift
private struct StubForkAdapter: AgentSessionForkAdapter {
    let agent: String
    let capabilityValue: ForkCapability
    func capability(helpText: String) -> ForkCapability { capabilityValue }
    func forkArgv(session: AgentSessionRef, targetPath: String) throws -> [String] {
        [agent, "fork", session.sessionId, targetPath]
    }
}

private final class FakeAdapterProvider: AgentForkAdapterProviding {
    let adapterValue: AgentSessionForkAdapter
    init(agent: String, capability: ForkCapability) {
        adapterValue = StubForkAdapter(agent: agent, capabilityValue: capability)
    }
    func adapter(for agent: String) -> AgentSessionForkAdapter? {
        adapterValue.agent == agent ? adapterValue : nil
    }
    func capability(for adapter: AgentSessionForkAdapter) -> ForkCapability {
        adapter.capability(helpText: "stub")
    }
}

private final class FakeForkLauncher: WorktreeForkLaunching {
    struct Launch: Equatable { let sessionName: String; let cwd: String; let argv: [String] }
    var launched: [Launch] = []
    var destroyed: [String] = []
    var existingTargetSession = false
    func reserveTarget(for intent: WorktreeForkIntent) -> String? { "target-session" }
    func launch(sessionName: String, cwd: String, argv: [String]) -> Bool {
        launched.append(Launch(sessionName: sessionName, cwd: cwd, argv: argv)); return true
    }
    func destroyTarget(sessionName: String) { destroyed.append(sessionName) }
    func targetExists(sessionName: String) -> Bool { existingTargetSession }
}

private struct FakeReadiness: WorktreeForkReadinessObserving {
    let ready: Bool
    func waitUntilReady(paneID: String, timeout: TimeInterval) async -> Bool { ready }
}

private struct CoordinatorFixture {
    let tracker = WorktreeForkIntentTracker(ttl: 30)
    let launcher = FakeForkLauncher()
    let intent: WorktreeForkIntent
    let coordinator: WorktreeSessionForkCoordinator

    init(agent: String = "codex", capability: ForkCapability = .nativeFork,
         readiness: Bool, existingTargetSession: Bool = false) {
        let ref = AgentSessionRef(agent: agent,
            sessionId: "f637907b-a9b7-429a-941c-b407fe2487ee")!
        intent = WorktreeForkIntent(
            id: UUID(), sourcePaneID: "source-session", sourceWorktreePath: "/repo",
            repositoryIdentity: "/repo/.git", nativeSession: ref,
            requestedTargetPath: "/repo-wt/feature", createdAt: Date(), state: .targetResolved)
        launcher.existingTargetSession = existingTargetSession
        tracker.record(intent)
        coordinator = WorktreeSessionForkCoordinator(
            tracker: tracker,
            adapters: FakeAdapterProvider(agent: agent, capability: capability),
            launcher: launcher,
            readiness: FakeReadiness(ready: readiness),
            readinessTimeout: 0.01,
            validateTarget: { _, _ in true })
    }
}
```

- [ ] **Step 2: Run coordinator tests and verify they fail to compile**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/WorktreeSessionForkCoordinatorTests test
```

Expected: FAIL because coordinator protocols and result types do not exist.

- [ ] **Step 3: Add safe argv-to-command conversion**

Add to `ShellEscape`:

```swift
static func commandLine(argv: [String]) -> String {
    argv.map(singleQuote).joined(separator: " ")
}
```

Add tests proving a target path containing spaces remains one quoted token. Keep `SessionManager.createDetachedSession` as the only zmx spawning implementation.

- [ ] **Step 4: Define coordinator seams and result**

Create the following interfaces in `WorktreeSessionForkCoordinator.swift`:

```swift
protocol WorktreeForkLaunching {
    func reserveTarget(for intent: WorktreeForkIntent) -> String?
    func launch(sessionName: String, cwd: String, argv: [String]) -> Bool
    func destroyTarget(sessionName: String)
}

protocol WorktreeForkReadinessObserving {
    func waitUntilReady(paneID: String, timeout: TimeInterval) async -> Bool
}

enum WorktreeForkResult: Equatable {
    case ready(targetPaneID: String)
    case unsupportedResumeOnly
    case unavailable(String)
    case failed(String)
}
```

Give `WorktreeSessionForkCoordinator` an injected validator:

```swift
typealias WorktreeForkTargetValidator = (_ targetPath: String, _ repositoryIdentity: String) -> Bool
```

The production initializer supplies a closure that checks file existence and `GitRepositoryIdentity.resolve`; tests supply `{ _, _ in true }`.

- [ ] **Step 5: Implement coordinator orchestration**

The coordinator implementation must follow this order exactly:

```swift
func fork(_ intent: WorktreeForkIntent) async -> WorktreeForkResult {
    guard let adapter = adapters.adapter(for: intent.nativeSession.agent) else {
        return fail(intent, "no adapter for \(intent.nativeSession.agent)")
    }
    switch adapters.capability(for: adapter) {
    case .resumeOnly: return .unsupportedResumeOnly
    case .unavailable(let reason): return .unavailable(reason)
    case .nativeFork: break
    }
    guard validateTarget(intent.requestedTargetPath, intent.repositoryIdentity) else {
        return fail(intent, "target is not a worktree of the source repository")
    }
    guard let targetPaneID = launcher.reserveTarget(for: intent) else {
        return fail(intent, "could not reserve target pane")
    }
    tracker.transition(id: intent.id, to: .launching)
    do {
        let argv = try adapter.forkArgv(session: intent.nativeSession,
                                        targetPath: intent.requestedTargetPath)
        guard launcher.launch(sessionName: targetPaneID,
                              cwd: intent.requestedTargetPath, argv: argv) else {
            launcher.destroyTarget(sessionName: targetPaneID)
            return fail(intent, "agent process did not launch")
        }
    } catch {
        launcher.destroyTarget(sessionName: targetPaneID)
        return fail(intent, error.localizedDescription)
    }
    guard await readiness.waitUntilReady(paneID: targetPaneID, timeout: readinessTimeout) else {
        launcher.destroyTarget(sessionName: targetPaneID)
        return fail(intent, "agent did not become ready")
    }
    tracker.transition(id: intent.id, to: .ready)
    return .ready(targetPaneID: targetPaneID)
}
```

Implement `fail` as the single place that stores `.failed(message)`.

- [ ] **Step 6: Add the real TerminalCoordinator launcher**

Add methods that:

1. resolve the already-discovered target `SplitTree`;
2. obtain its primary station/session name;
3. assign the source `AgentSessionRef` only as recovery metadata;
4. call `SessionManager.createDetachedSession` with `ShellEscape.commandLine(argv:)` and target cwd;
5. destroy only that target tree/backend session on rollback.

Do not call `transferTree`. Do not unregister any source `ShipLog` entry.

- [ ] **Step 7: Run coordinator and launch-command tests**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/WorktreeSessionForkCoordinatorTests \
  -only-testing:seahelmTests/SessionLaunchCommandTests \
  -only-testing:seahelmTests/TerminalCoordinatorTests test
```

Expected: PASS.

- [ ] **Step 8: Commit two-phase launching**

```bash
git add Sources/Core/WorktreeSessionForkCoordinator.swift Sources/Core/SessionManager.swift \
  Sources/Core/ShellEscape.swift Sources/App/TerminalCoordinator.swift Sources/Terminal/Station.swift \
  Tests/WorktreeSessionForkCoordinatorTests.swift Tests/SessionLaunchCommandTests.swift \
  Tests/TerminalCoordinatorTests.swift
git commit -m "feat: launch forked sessions in target worktrees"
```

## Task 6: Add explicit control API and agent-facing CLI

**Files:**

- Modify: `Sources/Core/ControlProtocol.swift`
- Modify: `Sources/Core/SeahelmControlDataSource.swift`
- Modify: `Sources/Core/SeahelmCliInstaller.swift`
- Modify: `Sources/Core/SeahelmSkillInstaller.swift`
- Modify: `Tests/ControlRouterTests.swift`
- Modify: `Tests/SeahelmCliInstallerTests.swift`
- Modify: `Tests/SeahelmSkillInstallerTests.swift`

- [ ] **Step 1: Write failing router tests for exact pane/path attribution**

Extend the fake data source with `forkCalls` and add:

```swift
func testWorktreeForkRoutesExactPaneAndAbsolutePath() {
    let ds = FakeControlDataSource()
    ds.forkResult = ["intent_id": "intent-1", "state": "recorded"]
    let router = ControlRouter(dataSource: ds)
    let result = router.handle(method: "worktree.fork", params: [
        "pane_id": "amux-repo-main", "target_path": "/repo-wt/feature"
    ])
    guard case .ok(let payload) = result else { return XCTFail() }
    XCTAssertEqual(payload["state"] as? String, "recorded")
    XCTAssertEqual(ds.forkCalls.first?.paneID, "amux-repo-main")
}

func testWorktreeForkRejectsRelativeTarget() {
    let result = ControlRouter(dataSource: FakeControlDataSource()).handle(
        method: "worktree.fork", params: ["pane_id": "p", "target_path": "../wt"])
    guard case .error(let code, _) = result else { return XCTFail() }
    XCTAssertEqual(code, ControlError.invalidParams)
}
```

- [ ] **Step 2: Run the focused router tests and verify failure**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/ControlRouterTests/testWorktreeForkRoutesExactPaneAndAbsolutePath \
  -only-testing:seahelmTests/ControlRouterTests/testWorktreeForkRejectsRelativeTarget test
```

Expected: FAIL because the method is unknown.

- [ ] **Step 3: Extend `ControlDataSource` and router**

Add:

```swift
func forkAgentSession(paneID: String, targetPath: String) -> [String: Any]?
```

with a default `nil` implementation. Route `worktree.fork`, requiring a non-empty pane ID and an absolute standardized target path. `SeahelmControlDataSource` resolves stable session names, looks up the runtime identity, validates repository identity, records an intent, and schedules coordinator launch without blocking the socket thread.

- [ ] **Step 4: Add CLI parsing tests and implementation**

Update the expected usage text and script-shape assertions for:

```text
seahelm worktree fork <absolute-path> [--pane <pane-id>]
```

When `--pane` is absent, the generated Python uses `SEAHELM_PANE_ID`; when both are absent it exits 2. It sends:

```python
if g == "worktree":
    if len(a) < 2 or a[0] != "fork":
        die("usage: seahelm worktree fork <absolute-path> [--pane <pane-id>]")
    rest = a[1:]
    pane = opt(rest, "--pane") or os.environ.get("SEAHELM_PANE_ID")
    if not pane:
        die("pane id unavailable; pass --pane or run inside a Seahelm pane")
    target = os.path.abspath(rest[0])
    print(json.dumps(call("worktree.fork", {"pane_id": pane, "target_path": target})))
    return
```

Increment the managed CLI version marker so existing installations update.

- [ ] **Step 5: Teach installed agent guidance to request the fork explicitly**

Update the managed Seahelm skill's worktree guidance to require this sequence whenever the user asks an agent to branch ongoing work into a new worktree:

```text
1. Create the Git worktree and obtain its absolute path.
2. Run `seahelm worktree fork <absolute-path>` from the source pane.
3. Continue source work only when the user explicitly asks for both branches to proceed.
```

Add a `SeahelmSkillInstallerTests` assertion for the exact command so all supported agents receive the portable path without relying on shell-command parsing.

- [ ] **Step 6: Run router, CLI, and skill installer tests**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/ControlRouterTests \
  -only-testing:seahelmTests/SeahelmCliInstallerTests \
  -only-testing:seahelmTests/SeahelmSkillInstallerTests test
```

Expected: PASS.

- [ ] **Step 7: Commit the portable explicit path**

```bash
git add Sources/Core/ControlProtocol.swift Sources/Core/SeahelmControlDataSource.swift \
  Sources/Core/SeahelmCliInstaller.swift Sources/Core/SeahelmSkillInstaller.swift \
  Tests/ControlRouterTests.swift Tests/SeahelmCliInstallerTests.swift Tests/SeahelmSkillInstallerTests.swift
git commit -m "feat: expose worktree session fork control command"
```

## Task 7: Wire Seahelm-created worktrees behind a feature preference

**Files:**

- Modify: `Sources/Core/Config.swift`
- Modify: `Sources/App/MainWindowController.swift`
- Modify: `Sources/App/TabCoordinator.swift`
- Modify: `Tests/SessionRestoreConfigTests.swift`
- Create: `Tests/WorktreeCreateForkRoutingTests.swift`

- [ ] **Step 1: Add failing config-default and routing tests**

Add:

```swift
func testWorktreeSessionForkDefaultsOff() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
    XCTAssertFalse(config.worktreeSessionForkEnabled)
}
```

Create routing tests proving:

- disabled preference preserves the existing fresh-agent launch;
- enabled preference plus matching selected pane/agent records a fork intent;
- enabled preference without per-pane native identity falls back to the existing fresh launch;
- selected source pane is not closed or rehomed.

- [ ] **Step 2: Run routing tests and verify they fail**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/SessionRestoreConfigTests/testWorktreeSessionForkDefaultsOff \
  -only-testing:seahelmTests/WorktreeCreateForkRoutingTests test
```

Expected: FAIL because the preference and routing seam do not exist.

- [ ] **Step 3: Add the disabled-by-default preference**

Add `worktreeSessionForkEnabled` to `Config`, JSON key `worktree_session_fork_enabled`, initialized and decoded as `false`. Do not add a Settings UI toggle in this task; the flag can be enabled in config for the compatibility rollout.

- [ ] **Step 4: Extract fresh-vs-fork launch selection**

Move the launch decision out of `performWorktreeCreate` into a pure helper:

```swift
enum WorktreeAgentLaunchDecision: Equatable {
    case fresh(commandLine: String)
    case fork(sourcePaneID: String, identity: AgentRuntimeIdentity)
}
```

Return `.fork` only when the preference is on, the selected source pane has a current identity, and its `nativeSession.agent` equals the selected target agent's normalized adapter name. Otherwise return the existing fresh command.

- [ ] **Step 5: Schedule fork after worktree integration**

For `.fork`, do not call the fresh `launchCommand(withTask:)` path. On the main queue first call `handleNewBranch`, then record an exact intent using `info.path`, then start coordinator launch. This ordering guarantees the target tree/station exists before reservation.

- [ ] **Step 6: Run create-routing and existing WorktreeCreator tests**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/WorktreeCreateForkRoutingTests \
  -only-testing:seahelmTests/WorktreeCreatorTests \
  -only-testing:seahelmTests/SessionRestoreConfigTests test
```

Expected: PASS.

- [ ] **Step 7: Commit Seahelm-created worktree routing**

```bash
git add Sources/Core/Config.swift Sources/App/MainWindowController.swift Sources/App/TabCoordinator.swift \
  Tests/SessionRestoreConfigTests.swift Tests/WorktreeCreateForkRoutingTests.swift
git commit -m "feat: fork eligible sessions for new worktrees"
```

## Task 8: Report OpenCode native session identity

**Files:**

- Modify: `Sources/Core/OpenCodePluginInstaller.swift`
- Modify: `Sources/Status/WebhookEvent.swift`
- Modify: `Tests/OpenCodePluginInstallerTests.swift`
- Modify: `Tests/WebhookEventTests.swift`

- [ ] **Step 1: Add failing plugin-shape and event-parser tests**

Require the plugin to contain `session.created`, `session.updated`, `event.properties.info.id`, `SEAHELM_PANE_ID`, and `session_start`. Add a generic event parser test:

```swift
func testGenericOpenCodeSessionIdentityEvent() throws {
    let data = Data(#"{"source":"opencode","session_id":"ses_123","event":"session_start","cwd":"/repo","seahelm_pane_id":"amux-repo-main"}"#.utf8)
    let event = try WebhookEvent.parse(from: data)
    XCTAssertEqual(event.source, "opencode")
    XCTAssertEqual(event.sessionId, "ses_123")
    XCTAssertEqual(event.paneId, "amux-repo-main")
}
```

- [ ] **Step 2: Run OpenCode tests and verify the plugin-shape test fails**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/OpenCodePluginInstallerTests \
  -only-testing:seahelmTests/WebhookEventTests/testGenericOpenCodeSessionIdentityEvent test
```

Expected: parser test passes; plugin-shape assertions fail because lifecycle reporting is absent.

- [ ] **Step 3: Extend the OpenCode plugin event hook**

Keep the existing suggestion tool and add an `event` hook. For `session.created` and `session.updated`, obtain `event.properties.info`, require its `id`, and send this generic payload through the Seahelm CLI/control socket:

```javascript
const pane = process.env.SEAHELM_PANE_ID || process.env.ZMX_SESSION
if (pane && info?.id) {
  await $`${SEAHELM} session identify --agent opencode --session ${info.id} --cwd ${directory} --pane ${pane}`
    .quiet().nothrow()
}
```

Add `seahelm session identify` to `SeahelmCliInstaller` as a thin `hook` RPC producer with `source`, `session_id`, `event: "session_start"`, `cwd`, and `seahelm_pane_id`. Keep all values as separate argv/JSON values.

- [ ] **Step 4: Increment plugin and CLI markers and run tests**

Run the command from Step 2 plus `SeahelmCliInstallerTests`.

Expected: PASS; managed installations update because markers changed.

- [ ] **Step 5: Commit OpenCode identity reporting**

```bash
git add Sources/Core/OpenCodePluginInstaller.swift Sources/Core/SeahelmCliInstaller.swift \
  Sources/Status/WebhookEvent.swift Tests/OpenCodePluginInstallerTests.swift \
  Tests/SeahelmCliInstallerTests.swift Tests/WebhookEventTests.swift
git commit -m "feat: report opencode session identity"
```

## Task 9: Surface launching, failure, retry, and Cursor fallback

**Files:**

- Create: `Sources/Core/WorktreeForkPresentationStore.swift`
- Modify: `Sources/Core/FirstMate.swift`
- Modify: `Sources/Core/PendingOrdersQueue.swift`
- Modify: `Sources/App/TabCoordinator.swift`
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift`
- Modify: `Sources/UI/Dashboard/MiniCardView.swift`
- Modify: `Sources/UI/SidePanel/BridgePanelViewController.swift`
- Create: `Tests/WorktreeForkPresentationTests.swift`
- Modify: `Tests/FirstMateActionPayloadTests.swift`
- Modify: `Tests/DashboardViewControllerClickTests.swift`

- [ ] **Step 1: Write failing presentation-state tests**

Define expected behavior:

```swift
func testLaunchingOverridesCardStatusText() {
    let store = WorktreeForkPresentationStore()
    store.set(.launching(agent: "Codex"), for: "/wt")
    XCTAssertEqual(store.statusText(for: "/wt"), "Forking Codex…")
}

func testCursorCreatesHandoffOrderNotAutomaticLaunch() {
    let action = WorktreeForkPresentation.cursorFallback(
        worktreePath: "/wt", sourcePaneID: "source", message: "Cursor cannot fork this chat")
    XCTAssertEqual(action.options, ["Start fresh with handoff", "Move session here"])
    XCTAssertEqual(action.kind, .forkAgent)
}
```

- [ ] **Step 2: Run presentation tests and verify they fail to compile**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/WorktreeForkPresentationTests test
```

Expected: FAIL because presentation types and `.forkAgent` do not exist.

- [ ] **Step 3: Implement presentation store and action payloads**

Use:

```swift
enum WorktreeForkPresentationState: Equatable {
    case launching(agent: String)
    case failed(message: String)
    case unsupported(message: String)
}
```

The store is main-thread-owned, keyed by canonical worktree path, and has an observer API matching `PendingOrdersQueue`. Add `.forkAgent` to `FirstMateActionKind` and payload constants `fork-retry`, `cursor-fresh-handoff`, and `cursor-exclusive-move`.

Add this factory beside the presentation store so the test uses a defined API:

```swift
enum WorktreeForkPresentation {
    static func cursorFallback(worktreePath: String, sourcePaneID: String,
                               message: String) -> FirstMateAction {
        FirstMateAction(
            kind: .forkAgent, zone: .red, worktreePath: worktreePath,
            branch: URL(fileURLWithPath: worktreePath).lastPathComponent,
            project: "", terminalID: sourcePaneID, message: message,
            payload: "cursor-fork-fallback",
            options: ["Start fresh with handoff", "Move session here"])
    }
}
```

- [ ] **Step 4: Connect coordinator results to presentation state**

Before launch set `.launching`. On `.ready`, remove presentation state. On `.failed` or `.unavailable`, set the matching state and enqueue a `.forkAgent` order with `Retry fork`. On `.unsupportedResumeOnly`, enqueue the two Cursor options and do not call the launcher.

- [ ] **Step 5: Display launch state without inventing a SailorStatus**

Add `launchStatusText: String?` to `SailorDisplayInfo`. `TabCoordinator.buildSailorDisplayInfos` reads it from the presentation store. Extend `MiniCardView.configure` with the optional value and use:

```swift
statusTextLabel.stringValue = launchStatusText ?? status.capitalized
statusTextLabel.textColor = launchStatusText == nil
    ? SailorDisplayHelpers.statusColor(status)
    : SemanticColors.muted
```

Do not add `launching` to `SailorStatus`; it is orchestration state, not agent state.

- [ ] **Step 6: Route retry and Cursor choices**

In the existing First Mate option handler:

- `Retry fork` reuses the failed intent after revalidating target/repository/capability;
- `Start fresh with handoff` launches a new Cursor chat in target cwd with a prompt built from `WorktreeTaskStore`, source branch, and last user prompt, explicitly labeled lossy;
- `Move session here` opens a confirmation order and only after approval stops the source process and resumes Cursor in the target;
- neither Cursor path is automatic.

- [ ] **Step 7: Run presentation and dashboard tests**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/WorktreeForkPresentationTests \
  -only-testing:seahelmTests/FirstMateActionPayloadTests \
  -only-testing:seahelmTests/DashboardViewControllerClickTests test
```

Expected: PASS.

- [ ] **Step 8: Commit fork UI and fallbacks**

```bash
git add Sources/Core/WorktreeForkPresentationStore.swift Sources/Core/FirstMate.swift \
  Sources/Core/PendingOrdersQueue.swift Sources/App/TabCoordinator.swift \
  Sources/UI/Dashboard/DashboardViewController.swift Sources/UI/Dashboard/MiniCardView.swift \
  Sources/UI/SidePanel/BridgePanelViewController.swift Tests/WorktreeForkPresentationTests.swift \
  Tests/FirstMateActionPayloadTests.swift Tests/DashboardViewControllerClickTests.swift
git commit -m "feat: surface worktree session fork progress"
```

## Task 10: Recovery, orphan protection, and end-to-end verification

**Files:**

- Modify: `Sources/Core/Config.swift`
- Modify: `Sources/Core/SessionManager.swift`
- Modify: `Sources/App/AppDelegate.swift`
- Modify: `Sources/Core/WorktreeSessionForkCoordinator.swift`
- Modify: `Tests/SessionManagerTests.swift`
- Modify: `Tests/WorktreeSessionForkCoordinatorTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Write failing recovery and orphan-protection tests**

Add tests proving:

```swift
func testLaunchingIntentProtectsReservedSessionFromOrphanCleanup() {
    var config = Config()
    config.worktreeForkLaunches = [PersistedWorktreeForkLaunch(
        intentID: UUID(), sourcePaneID: "amux-source", targetPath: "/wt",
        repositoryIdentity: "/repo/.git",
        nativeSession: AgentSessionRef(agent: "codex",
            sessionId: "f637907b-a9b7-429a-941c-b407fe2487ee")!,
        targetSessionName: "amux-target", state: .launching,
        recordedAt: Date(timeIntervalSince1970: 1))]
    let active = SessionManager.expectedSessionNames(config: config, discoveredWorktreePaths: [])
    XCTAssertTrue(active.contains("amux-target"))
}

func testRecoveryAdoptsReadyTargetWithoutLaunchingDuplicate() async {
    let fixture = CoordinatorFixture(readiness: true, existingTargetSession: true)
    await fixture.coordinator.recoverNonTerminalIntents()
    XCTAssertTrue(fixture.launcher.launched.isEmpty)
    XCTAssertEqual(fixture.tracker.state(id: fixture.intent.id), .ready)
}
```

- [ ] **Step 2: Run recovery tests and verify failure**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/SessionManagerTests/testLaunchingIntentProtectsReservedSessionFromOrphanCleanup \
  -only-testing:seahelmTests/WorktreeSessionForkCoordinatorTests/testRecoveryAdoptsReadyTargetWithoutLaunchingDuplicate test
```

Expected: FAIL because intents/reservations are not persisted or included in expected sessions.

- [ ] **Step 3: Persist only non-terminal launch reservations**

Add this compact model beside `WorktreeForkIntent`:

```swift
struct PersistedWorktreeForkLaunch: Codable, Equatable {
    enum State: String, Codable { case targetResolved = "target_resolved", launching }
    let intentID: UUID
    let sourcePaneID: String
    let targetPath: String
    let repositoryIdentity: String
    let nativeSession: AgentSessionRef
    let targetSessionName: String
    let state: State
    let recordedAt: Date
}
```

Add `[PersistedWorktreeForkLaunch] worktreeForkLaunches` to `Config`, store it under `worktree_fork_launches`, and default it to `[]`. Remove entries on ready/failed/expired after presentation state has been recorded.

- [ ] **Step 4: Protect and reconcile reserved backend sessions**

Make `SessionManager.expectedSessionNames` include non-terminal reserved target session names. At app startup, coordinator recovery:

1. validates target path and repository identity;
2. adopts an existing ready backend session;
3. marks an existing-but-not-ready session failed after the normal timeout;
4. marks a missing session failed and offers retry;
5. never relaunches automatically from persisted state;
6. never touches the source session.

- [ ] **Step 5: Document user-visible support and limitations**

Update README's supported-agent section with a compact table:

- Codex: native fork;
- Claude Code: native `--fork-session` when installed CLI supports it;
- OpenCode: native fork plus plugin identity;
- Cursor: explicit lossy handoff or confirmed exclusive resume;
- automatic fork requires precise pane/session attribution and is disabled by default during rollout.

- [ ] **Step 6: Run the full unit suite**

Run:

```bash
xcodegen generate
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation test
```

Expected: `** TEST SUCCEEDED **` with zero failed tests.

- [ ] **Step 7: Build the application**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Run the manual compatibility matrix**

For each installed CLI, record version, probed capability, source session ID, generated argv, readiness signal, and observed target cwd:

```bash
claude --version; claude --help
codex --version; codex fork --help
cursor-agent --version; cursor-agent --help
opencode --version; opencode --help
```

Then, with `worktree_session_fork_enabled` enabled in a disposable repository:

1. start the agent in main;
2. create a worktree through Seahelm or `seahelm worktree fork <path>`;
3. verify main pane remains interactive;
4. verify target pane has a different native session ID;
5. run `pwd` through the target agent and verify the exact target path;
6. edit different files in source/target and verify isolation;
7. force a bad target path and verify only target launch is cleaned up.

For an unavailable CLI, record `not installed`; do not infer support.

- [ ] **Step 9: Commit recovery and documentation**

```bash
git add Sources/Core/Config.swift Sources/Core/SessionManager.swift Sources/App/AppDelegate.swift \
  Sources/Core/WorktreeSessionForkCoordinator.swift Tests/SessionManagerTests.swift \
  Tests/WorktreeSessionForkCoordinatorTests.swift README.md
git commit -m "feat: recover worktree session fork launches"
```

- [ ] **Step 10: Review the final branch**

Run:

```bash
git status --short
git log --oneline --decorate -10
git diff main...HEAD --stat
```

Expected: no unintended generated artifacts, one focused commit per task, and changes limited to session identity, fork orchestration, integrations, tests, and documentation described above.
