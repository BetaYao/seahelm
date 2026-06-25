# Bridge Command Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the bottom task input into a First Mate command palette: no-prefix still creates a worktree, while `/`-commands dispatch to existing worktrees, return-to-port, and broadcast — green commands execute directly, red commands enqueue into the Bridge pending list.

**Architecture:** A pure `BridgeCommandParser` (mirroring `FirstMate.evaluate`) turns input text + a worktree list into a `BridgeCommand`. `MainWindowController` routes green commands to injected execution closures and red commands into `PendingOrdersQueue` (reusing the existing Bridge confirm UI). `FirstMateAction` gains a `payload` field and a `.broadcastOrder` kind. The command palette UI is added to `InlineWorktreeCreateView`.

**Tech Stack:** Swift 5.10, AppKit, XCTest (`@testable import amux`).

## Global Constraints

- Swift 5.10, macOS 14.0+, AppKit (not SwiftUI).
- Tests: XCTest, `@testable import amux`, files under `Tests/`, no external test deps.
- Pure logic types (`BridgeCommandParser`) must have no IO and no singletons — side effects live in injected closures.
- `FirstMateAction` is `Equatable`; any new field must keep it `Equatable`.
- `PendingOrdersQueue` and all UI run on the main thread.
- Preserve current no-prefix behavior: an input with no leading `/` always creates a worktree via the existing `onCreate` path.

---

### Task 1: BridgeCommand model + parser

**Files:**
- Create: `Sources/Core/BridgeCommand.swift`
- Test: `Tests/BridgeCommandParserTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `struct WorktreeRef: Equatable { let branch: String; let path: String }`
  - `enum BridgeCommand: Equatable { case newWorktree(task: String); case orderExisting(worktreePath: String, task: String); case commit(worktreePath: String); case returnToPort(worktreePath: String); case broadcast(task: String) }`
  - `enum BridgeCommandError: Equatable { case emptyTask; case unknownCommand(String); case unknownBranch(String); case missingArgument(String) }`
  - `enum BridgeCommandParser { static func parse(_ text: String, worktrees: [WorktreeRef]) -> Result<BridgeCommand, BridgeCommandError> }`

Parser rules:
- Trim input. Empty → `.failure(.emptyTask)`.
- No leading `/` → `.success(.newWorktree(task: trimmed))`.
- `/new <task>` → `.newWorktree`. Empty task → `.failure(.emptyTask)`.
- `/order <branch> <task>` → resolve branch in `worktrees`; unknown → `.unknownBranch`; missing task → `.emptyTask`; missing branch → `.missingArgument("order")`.
- `/commit <branch>` → resolve branch; unknown → `.unknownBranch`; missing → `.missingArgument("commit")`.
- `/return <branch>` → resolve branch; same errors as commit.
- `/broadcast <task>` → `.broadcast`; empty task → `.emptyTask`.
- Unrecognized `/word` → `.failure(.unknownCommand(word))`.
- Branch resolution is exact-match on `WorktreeRef.branch`; first match wins.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import amux

final class BridgeCommandParserTests: XCTestCase {
    let wts = [
        WorktreeRef(branch: "feat-x", path: "/repo/feat-x"),
        WorktreeRef(branch: "fix-y", path: "/repo/fix-y"),
    ]

    func testNoPrefixIsNewWorktree() {
        XCTAssertEqual(BridgeCommandParser.parse("add dark mode", worktrees: wts),
                       .success(.newWorktree(task: "add dark mode")))
    }

    func testEmptyIsError() {
        XCTAssertEqual(BridgeCommandParser.parse("   ", worktrees: wts), .failure(.emptyTask))
    }

    func testNewExplicit() {
        XCTAssertEqual(BridgeCommandParser.parse("/new build login", worktrees: wts),
                       .success(.newWorktree(task: "build login")))
    }

    func testOrderResolvesBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/order feat-x keep going", worktrees: wts),
                       .success(.orderExisting(worktreePath: "/repo/feat-x", task: "keep going")))
    }

    func testOrderUnknownBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/order nope do it", worktrees: wts),
                       .failure(.unknownBranch("nope")))
    }

    func testOrderMissingTask() {
        XCTAssertEqual(BridgeCommandParser.parse("/order feat-x", worktrees: wts), .failure(.emptyTask))
    }

    func testReturnResolvesBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/return fix-y", worktrees: wts),
                       .success(.returnToPort(worktreePath: "/repo/fix-y")))
    }

    func testCommitResolvesBranch() {
        XCTAssertEqual(BridgeCommandParser.parse("/commit feat-x", worktrees: wts),
                       .success(.commit(worktreePath: "/repo/feat-x")))
    }

    func testBroadcast() {
        XCTAssertEqual(BridgeCommandParser.parse("/broadcast run tests", worktrees: wts),
                       .success(.broadcast(task: "run tests")))
    }

    func testUnknownCommand() {
        XCTAssertEqual(BridgeCommandParser.parse("/frobnicate x", worktrees: wts),
                       .failure(.unknownCommand("frobnicate")))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug test -only-testing:seamuxTests/BridgeCommandParserTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `BridgeCommandParser` / `BridgeCommand` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

struct WorktreeRef: Equatable {
    let branch: String
    let path: String
}

enum BridgeCommand: Equatable {
    case newWorktree(task: String)
    case orderExisting(worktreePath: String, task: String)
    case commit(worktreePath: String)
    case returnToPort(worktreePath: String)
    case broadcast(task: String)
}

enum BridgeCommandError: Equatable {
    case emptyTask
    case unknownCommand(String)
    case unknownBranch(String)
    case missingArgument(String)
}

enum BridgeCommandParser {
    static func parse(_ text: String, worktrees: [WorktreeRef]) -> Result<BridgeCommand, BridgeCommandError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTask) }
        guard trimmed.hasPrefix("/") else { return .success(.newWorktree(task: trimmed)) }

        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map(String.init) ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        func resolveBranchArg(_ verbName: String) -> Result<(path: String, rest: String), BridgeCommandError> {
            let argParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let branch = argParts.first.map(String.init) else { return .failure(.missingArgument(verbName)) }
            guard let wt = worktrees.first(where: { $0.branch == branch }) else { return .failure(.unknownBranch(branch)) }
            let tail = argParts.count > 1 ? String(argParts[1]).trimmingCharacters(in: .whitespaces) : ""
            return .success((wt.path, tail))
        }

        switch verb {
        case "new":
            return rest.isEmpty ? .failure(.emptyTask) : .success(.newWorktree(task: rest))
        case "order":
            return resolveBranchArg("order").flatMap { r in
                r.rest.isEmpty ? .failure(.emptyTask) : .success(.orderExisting(worktreePath: r.path, task: r.rest))
            }
        case "commit":
            return resolveBranchArg("commit").map { .commit(worktreePath: $0.path) }
        case "return":
            return resolveBranchArg("return").map { .returnToPort(worktreePath: $0.path) }
        case "broadcast":
            return rest.isEmpty ? .failure(.emptyTask) : .success(.broadcast(task: rest))
        default:
            return .failure(.unknownCommand(verb))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2.
Expected: PASS (all 10 tests).

- [ ] **Step 5: Add `BridgeCommand.swift` to the project and commit**

Add the file to `project.yml`'s source globbing if it is path-based (the `Sources/` glob already covers `Sources/Core/`, so usually no edit needed). Regenerate if `project.yml` lists files explicitly: `xcodegen generate`.

```bash
git add Sources/Core/BridgeCommand.swift Tests/BridgeCommandParserTests.swift
git commit -m "feat: pure BridgeCommandParser for First Mate command input"
```

---

### Task 2: Extend FirstMateAction for command payload + broadcast kind

**Files:**
- Modify: `Sources/Core/FirstMate.swift:5-22` (add `.broadcastOrder` kind, add `payload` field)
- Test: `Tests/FirstMateActionPayloadTests.swift`

**Interfaces:**
- Consumes: `FirstMateActionKind`, `FirstMateAction` from Task baseline.
- Produces: `FirstMateAction` now has `let payload: String?` (defaulted via initializer for existing call sites). `FirstMateActionKind` gains `case broadcastOrder`.

**Note:** `FirstMate.evaluate`'s existing `make(...)` helper constructs actions without a payload; add `payload: String? = nil` so existing call sites compile unchanged.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import amux

final class FirstMateActionPayloadTests: XCTestCase {
    func testActionCarriesPayload() {
        let a = FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "",
                                branch: "", project: "", terminalID: "", message: "broadcast to 3",
                                payload: "run the tests")
        XCTAssertEqual(a.kind, .broadcastOrder)
        XCTAssertEqual(a.payload, "run the tests")
    }

    func testDefaultPayloadIsNil() {
        let a = FirstMateAction(kind: .returnToPort, zone: .red, worktreePath: "/w",
                                branch: "b", project: "p", terminalID: "t", message: "m")
        XCTAssertNil(a.payload)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug test -only-testing:seamuxTests/FirstMateActionPayloadTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — extra argument `payload` / `.broadcastOrder` not a member.

- [ ] **Step 3: Edit `Sources/Core/FirstMate.swift`**

Change the enum:

```swift
enum FirstMateActionKind: Equatable {
    case watchWaiting
    case watchError
    case inspect
    case autoCommit
    case suggestNextOrder
    case returnToPort
    case broadcastOrder
}
```

Change the struct (add `payload` with a default in a memberwise-compatible initializer):

```swift
struct FirstMateAction: Equatable {
    let kind: FirstMateActionKind
    let zone: FirstMateZone
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let message: String
    let payload: String?

    init(kind: FirstMateActionKind, zone: FirstMateZone, worktreePath: String,
         branch: String, project: String, terminalID: String, message: String,
         payload: String? = nil) {
        self.kind = kind
        self.zone = zone
        self.worktreePath = worktreePath
        self.branch = branch
        self.project = project
        self.terminalID = terminalID
        self.message = message
        self.payload = payload
    }
}
```

(The existing `make(...)` helper in `evaluate` already omits `payload`, so it picks up the default.)

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command plus the existing engine tests: `-only-testing:seamuxTests/FirstMateActionPayloadTests` and any `FirstMate` test class.
Expected: PASS, and existing First Mate engine tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/FirstMate.swift Tests/FirstMateActionPayloadTests.swift
git commit -m "feat: add payload field and broadcastOrder kind to FirstMateAction"
```

---

### Task 3: Route parsed commands (green direct / red enqueue)

**Files:**
- Create: `Sources/Core/BridgeCommandRouter.swift`
- Test: `Tests/BridgeCommandRouterTests.swift`

**Interfaces:**
- Consumes: `BridgeCommand` (Task 1), `FirstMateAction`/`.broadcastOrder`/`.returnToPort`/`payload` (Task 2), `PendingOrdersQueue` (existing).
- Produces:
  - `struct BridgeCommandRouter` with closures:
    - `createWorktree: (String) -> Void` (task text)
    - `orderExisting: (String, String) -> Void` (worktreePath, task)
    - `commit: (String) -> Void` (worktreePath)
    - `activeAgentCount: () -> Int` (for broadcast confirm message)
    - `branchForPath: (String) -> String` (for red-zone action labels)
    - `projectForPath: (String) -> String`
  - `func route(_ command: BridgeCommand)` — green calls closures; red enqueues into the injected `PendingOrdersQueue`.

Routing:
- `.newWorktree(task)` → `createWorktree(task)`
- `.orderExisting(path, task)` → `orderExisting(path, task)`
- `.commit(path)` → `commit(path)`
- `.returnToPort(path)` → `queue.enqueue(FirstMateAction(kind: .returnToPort, zone: .red, worktreePath: path, branch: branchForPath(path), project: projectForPath(path), terminalID: "", message: "\(branchForPath(path)) 返港删除?"))`
- `.broadcast(task)` → `queue.enqueue(FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "", branch: "", project: "", terminalID: "", message: "广播给 \(activeAgentCount()) 个 agent", payload: task))`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import amux

final class BridgeCommandRouterTests: XCTestCase {
    func makeRouter(queue: PendingOrdersQueue,
                    created: @escaping (String) -> Void = { _ in },
                    ordered: @escaping (String, String) -> Void = { _, _ in },
                    committed: @escaping (String) -> Void = { _ in },
                    agentCount: @escaping () -> Int = { 0 }) -> BridgeCommandRouter {
        BridgeCommandRouter(queue: queue, createWorktree: created, orderExisting: ordered,
                            commit: committed, activeAgentCount: agentCount,
                            branchForPath: { _ in "feat-x" }, projectForPath: { _ in "repo" })
    }

    func testNewWorktreeCallsClosureNotQueue() {
        let q = PendingOrdersQueue()
        var got: String?
        makeRouter(queue: q, created: { got = $0 }).route(.newWorktree(task: "do it"))
        XCTAssertEqual(got, "do it")
        XCTAssertTrue(q.all().isEmpty)
    }

    func testOrderCallsClosure() {
        let q = PendingOrdersQueue()
        var got: (String, String)?
        makeRouter(queue: q, ordered: { got = ($0, $1) }).route(.orderExisting(worktreePath: "/p", task: "go"))
        XCTAssertEqual(got?.0, "/p")
        XCTAssertEqual(got?.1, "go")
        XCTAssertTrue(q.all().isEmpty)
    }

    func testReturnEnqueuesRed() {
        let q = PendingOrdersQueue()
        makeRouter(queue: q).route(.returnToPort(worktreePath: "/p"))
        XCTAssertEqual(q.all().count, 1)
        XCTAssertEqual(q.all().first?.action.kind, .returnToPort)
        XCTAssertEqual(q.all().first?.action.worktreePath, "/p")
    }

    func testBroadcastEnqueuesWithPayloadAndCount() {
        let q = PendingOrdersQueue()
        makeRouter(queue: q, agentCount: { 3 }).route(.broadcast(task: "run tests"))
        XCTAssertEqual(q.all().count, 1)
        XCTAssertEqual(q.all().first?.action.kind, .broadcastOrder)
        XCTAssertEqual(q.all().first?.action.payload, "run tests")
        XCTAssertTrue(q.all().first?.action.message.contains("3") ?? false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug test -only-testing:seamuxTests/BridgeCommandRouterTests -skipPackagePluginValidation -skipMacroValidation`
Expected: FAIL — `BridgeCommandRouter` not found.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

struct BridgeCommandRouter {
    let queue: PendingOrdersQueue
    let createWorktree: (String) -> Void
    let orderExisting: (String, String) -> Void
    let commit: (String) -> Void
    let activeAgentCount: () -> Int
    let branchForPath: (String) -> String
    let projectForPath: (String) -> String

    func route(_ command: BridgeCommand) {
        switch command {
        case .newWorktree(let task):
            createWorktree(task)
        case .orderExisting(let path, let task):
            orderExisting(path, task)
        case .commit(let path):
            commit(path)
        case .returnToPort(let path):
            let branch = branchForPath(path)
            queue.enqueue(FirstMateAction(kind: .returnToPort, zone: .red, worktreePath: path,
                                          branch: branch, project: projectForPath(path),
                                          terminalID: "", message: "\(branch) 返港删除?"))
        case .broadcast(let task):
            queue.enqueue(FirstMateAction(kind: .broadcastOrder, zone: .red, worktreePath: "",
                                          branch: "", project: "", terminalID: "",
                                          message: "广播给 \(activeAgentCount()) 个 agent", payload: task))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2.
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/BridgeCommandRouter.swift Tests/BridgeCommandRouterTests.swift
git commit -m "feat: BridgeCommandRouter routes green direct / red to queue"
```

---

### Task 4: Wire router + command execution in MainWindowController

**Files:**
- Modify: `Sources/App/MainWindowController.swift:421-459` (build the router; submit handler parses + routes)
- Modify: `Sources/App/MainWindowController.swift:1258-1273` (`handleBridgeApprove` executes `.returnToPort` and `.broadcastOrder`)

**Interfaces:**
- Consumes: `BridgeCommandParser` (Task 1), `BridgeCommandRouter` (Task 3), `FirstMateAction.payload`/`.broadcastOrder` (Task 2), existing `WorktreeDeleter.deleteWorktree`, `AgentHead.shared.allAgents()`/`sendCommand`, `WorktreeDiscovery`/`WorktreeTaskStore`.
- Produces: a `submitCommand(_ text: String)` path the inline view calls (Task 5 connects the UI to it).

**Note:** The existing `onCreate` worktree-creation block (lines 425-458) is reused verbatim as the `createWorktree` closure body. Wrap the no-prefix/`/new` path so it still calls that block. There is no existing `/commit` chain to call; for this task `commit` runs `AgentHead.shared.sendCommand(to:command:)` with a literal `"git add -A && git commit"` style instruction to the worktree's agent (a real inspect chain is out of scope).

- [ ] **Step 1: Add a parser-list + router builder near the inline-create wiring**

After the existing `dashboard.setupInlineCreate(...) { ... }` closure (which stays as the `createWorktree` execution body, refactored into a private method `performWorktreeCreate(task:repoPath:agentType:reuseEnv:)`), add:

```swift
private func currentWorktreeRefs() -> [WorktreeRef] {
    AgentHead.shared.allAgents().map { WorktreeRef(branch: $0.branch, path: $0.worktreePath) }
}

private func makeBridgeRouter() -> BridgeCommandRouter {
    BridgeCommandRouter(
        queue: pendingOrdersQueue,
        createWorktree: { [weak self] task in
            guard let self else { return }
            let repo = self.tabCoordinator.selectedAgent.map { _ in self.tabCoordinator.config.workspacePaths.first } ?? self.tabCoordinator.config.workspacePaths.first
            self.performWorktreeCreate(task: task, repoPath: repo ?? "", agentType: self.dashboardVC?.selectedAgentType ?? .claudeCode, reuseEnv: false)
        },
        orderExisting: { path, task in
            guard let tid = AgentHead.shared.agent(forWorktree: path)?.id else { return }
            AgentHead.shared.sendCommand(to: tid, command: task)
        },
        commit: { path in
            guard let tid = AgentHead.shared.agent(forWorktree: path)?.id else { return }
            AgentHead.shared.sendCommand(to: tid, command: "git add -A && git commit -m 'wip'")
        },
        activeAgentCount: { AgentHead.shared.allAgents().count },
        branchForPath: { path in AgentHead.shared.agent(forWorktree: path)?.branch ?? "" },
        projectForPath: { path in AgentHead.shared.agent(forWorktree: path)?.project ?? "" }
    )
}

func submitBridgeCommand(_ text: String) {
    switch BridgeCommandParser.parse(text, worktrees: currentWorktreeRefs()) {
    case .success(let command):
        makeBridgeRouter().route(command)
    case .failure:
        NSSound.beep()
    }
}
```

(`pendingOrdersQueue` is the same queue already injected into `dashboard.sidePanelVC.pendingOrdersQueue`. If it is currently a local, promote it to a stored property `let pendingOrdersQueue = PendingOrdersQueue()` so both the side panel and the router share one instance.)

- [ ] **Step 2: Extend `handleBridgeApprove` to execute new red kinds**

```swift
func handleBridgeApprove(_ order: PendingOrder) {
    switch order.action.kind {
    case .suggestNextOrder:
        let worktreePath = order.action.worktreePath
        guard let task = WorktreeTaskStore.shared.task(forWorktree: worktreePath),
              let terminalID = AgentHead.shared.agent(forWorktree: worktreePath)?.id else { return }
        AgentHead.shared.sendCommand(to: terminalID, command: task)
    case .returnToPort:
        let path = order.action.worktreePath
        guard let agent = AgentHead.shared.agent(forWorktree: path) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? WorktreeDeleter.deleteWorktree(worktreePath: path,
                                                repoPath: agent.project,
                                                branchName: agent.branch)
        }
    case .broadcastOrder:
        guard let task = order.action.payload else { return }
        for agent in AgentHead.shared.allAgents() {
            AgentHead.shared.sendCommand(to: agent.id, command: task)
        }
    default:
        break
    }
}
```

(Verify `AgentInfo` exposes `project` as the repo path used by `WorktreeDeleter.repoPath`; if the repo root differs from `project`, resolve it via `WorktreeDiscovery.repoRoot(for: path)` instead. Confirm the exact accessor against `Sources/Core/AgentHead.swift` before finalizing.)

- [ ] **Step 3: Build**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/MainWindowController.swift
git commit -m "feat: wire bridge command parsing/routing and red-zone execution"
```

---

### Task 5: Command palette UI in the inline input

**Files:**
- Modify: `Sources/UI/Dashboard/InlineWorktreeCreateView.swift` (recognize `/`, surface a completion list, emit on submit)
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift:364-368` (add an `onSubmitCommand` passthrough alongside `onCreate`)
- Modify: `Sources/App/MainWindowController.swift` (set `onSubmitCommand` to `submitBridgeCommand`)

**Interfaces:**
- Consumes: `submitBridgeCommand(_:)` (Task 4).
- Produces: `InlineWorktreeCreateView.onSubmitCommand: ((String) -> Void)?` — fired on Return when the text starts with `/`; otherwise the existing `onCreate` worktree path fires (unchanged).

**Note:** Keep the change minimal — the completion popover can be a simple `NSMenu`/list of command names (`new, order, commit, return, broadcast`) shown when the field text is exactly `/` or `/<partial>`. Branch completion for `/order <branch>` reuses `repoPathsProvider`-style injection: add a `worktreeBranchesProvider: (() -> [String])?` populated from `AgentHead.shared.allAgents().map { $0.branch }`.

- [ ] **Step 1: Add the submit branch in the text view delegate**

In `InlineWorktreeCreateView`, where Return currently triggers create, branch on prefix:

```swift
private func submitCurrent() {
    let text = promptTextView.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if text.hasPrefix("/") {
        onSubmitCommand?(text)
        clearAfterSubmit()
        onFormEnd?()
    } else {
        // existing worktree-create path
        onCreate?(text, selectedRepoPath ?? "", selectedAgentType, reuseEnvCheckbox.state == .on)
    }
}
```

Add `var onSubmitCommand: ((String) -> Void)?` and a `clearAfterSubmit()` helper that resets the field (mirror the existing post-create reset). Wire `submitCurrent()` to the existing Return handler.

- [ ] **Step 2: Add command-name completion popover**

When the field text matches `^/\w*$`, show a lightweight list (`new, order, commit, return, broadcast`) filtered by the partial; selecting one inserts `/<name> `. Implement with the view's existing styling helpers; do not add new dependencies.

- [ ] **Step 3: Pass the closure through the dashboard**

In `DashboardViewController.setupInlineCreate(...)`, add a parameter `onSubmitCommand: @escaping (String) -> Void` and set `inlineCreateView.onSubmitCommand = onSubmitCommand`.

In `MainWindowController`, pass `{ [weak self] text in self?.submitBridgeCommand(text) }`.

- [ ] **Step 4: Build and smoke-test manually**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED. Launch, type `/return <branch>` → a red pending order appears in Bridge; type `/order <branch> hello` → the agent receives `hello`; type plain text → a worktree is created as before.

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Dashboard/InlineWorktreeCreateView.swift Sources/UI/Dashboard/DashboardViewController.swift Sources/App/MainWindowController.swift
git commit -m "feat: command palette in inline input dispatches bridge commands"
```

---

### Task 6: Orders / Watch even split

**Files:**
- Modify: `Sources/UI/SidePanel/BridgePanelViewController.swift:104-128` (Watch section), `:68-94` (Orders section)

**Interfaces:** none (pure layout).

- [ ] **Step 1: Add a proportional height constraint between the two scroll views**

In `setupWatchSection()`, after both sections exist, pin Watch's scroll height equal to Orders' scroll height. Since the sections are built in order, store the orders scroll reference (already a property `ordersScrollView`) and add in `setupWatchSection()`:

```swift
watchScrollView.heightAnchor.constraint(equalTo: ordersScrollView.heightAnchor).isActive = true
```

Keep the existing `minHeight` `greaterThanOrEqualToConstant` constraints as floors. Lower the Orders floor to match (e.g. both 80) so the equal constraint is not over-constrained at small sizes.

- [ ] **Step 2: Build and verify visually**

Run: `xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED; Bridge panel shows Orders and Watch at roughly equal heights.

- [ ] **Step 3: Commit**

```bash
git add Sources/UI/SidePanel/BridgePanelViewController.swift
git commit -m "feat: even split between Bridge Orders and Watch sections"
```

---

## Self-Review

**Spec coverage:**
- Hybrid command palette → Task 5. ✓
- No-prefix = create worktree → Task 1 (parser) + Task 4 (createWorktree closure) + Task 5 (UI branch). ✓
- Unified entry, zone-based routing → Task 3 router. ✓
- `/broadcast` red with count → Task 3 + Task 4 execution. ✓
- `/return` red, reuse confirm + deletion → Task 4 `handleBridgeApprove`. ✓ (NB: `ReturnToPort` precheck warning surfacing in the confirm cell is a follow-up nicety; deletion itself is wired.)
- `<wt>` resolves by branch from quick-switcher source → Task 1 (parse) + Task 5 (branch completion provider). ✓
- `FirstMateAction` payload + `.broadcastOrder` → Task 2. ✓
- Orders/Watch even split → Task 6. ✓

**Open verification items for the implementer (flagged inline, not placeholders):**
- Confirm `pendingOrdersQueue` is (or is promoted to) a single shared stored property on `MainWindowController`.
- Confirm `AgentInfo.project` is the repo path `WorktreeDeleter` expects; otherwise resolve repo root via `WorktreeDiscovery`.
- Confirm `InlineWorktreeCreateView` exposes `promptTextView.plainText` / `selectedAgentType` accessors used above (they appear in the file's test hooks).

**Placeholder scan:** none — all code steps carry full code; the `/commit` chain is explicitly scoped to a literal sendCommand for now.

**Type consistency:** `BridgeCommand`, `WorktreeRef`, `BridgeCommandRouter` closure signatures match across Tasks 1, 3, 4. `FirstMateAction(... payload:)` initializer used consistently in Tasks 2-4.
