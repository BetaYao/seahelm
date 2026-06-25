# Data Pipeline Core (ShipLog reduce + NormalizedEvent) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Seahelm's status pipeline so that all intelligence enters ShipLog through one `ingest(NormalizedEvent)` entry and leaves through one `IngestOutcome` stream, with recording (faithful log) cleanly separated from interpretation (status reduce) and adjudication (FirstMate).

**Architecture:** Introduce `NormalizedEvent` as the single input language; make `ShipLog` keep two per-station status components (`scanStatus` from screen-scan, `hookStatus` from webhook events) and recompute the public status via `highestPriority` inside a pure reducer; emit `IngestOutcome` to decoupled subscribers (UI, aggregator, FirstMate, external-channel broadcast). This plan covers spec steps 1–4 (the core pipeline). Steps 5–6 (suggestion merge + Stop-hook reverse-trigger) are a separate plan.

**Tech Stack:** Swift 5.10, AppKit, XCTest (`@testable import seahelm`). No new dependencies.

**Source spec:** `docs/superpowers/specs/2026-06-25-data-pipeline-design.md`

## Global Constraints

- Do not change Ghostty C API symbols or any serialization keys: `SailorStatus` rawValue strings, `config.json` CodingKeys, `InboundMessage`/`OutboundMessage` fields, WeCom/WeChat protocol fields, git `worktree` concept.
- Current domain type names are `SailorInfo`, `SailorStatus`, `SailorType`, `SailorChannel`, `Station`, `SailorDef` (the spec writes them as `AgentInfo`/`AgentStatus` etc. — use the real `Sailor*`/`Station` names in code).
- `eventLog` (faithful event record) is in-memory ring buffer only; never persisted to disk.
- Build headless with: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
- Run targeted tests with: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/<Class>` — do NOT run the slow `seahelmUITests` target.
- New `.swift` files must be added to `project.yml`-driven target sources; this project uses XcodeGen. After creating a new source or test file, run `xcodegen generate` before building. (Sources are globbed by directory in `project.yml`, so a new file under `Sources/…` or `Tests/…` is picked up by re-generating.)
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit.

---

## File Structure

- `Sources/Core/SailorInfo.swift` (modify) — add `scanStatus` / `hookStatus` status-component fields.
- `Sources/Core/SailorReducer.swift` (create) — pure status reducer: old snapshot + inputs → new snapshot + delta. No IO.
- `Sources/Status/NormalizedEvent.swift` (create) — the unified input language (`NormalizedEvent` + `Kind` + `EventSource`).
- `Sources/Status/SignalDecoder.swift` (modify) — `decode() -> NormalizedEvent?`.
- `Sources/Status/ScanDecoder.swift` (modify) — produce `.screenObserved`.
- `Sources/Status/HookDecoder.swift` (modify) — produce event-native kinds via the aligned mapping table.
- `Sources/Core/IngestOutcome.swift` (create) — the single output type.
- `Sources/Core/ShipLog.swift` (modify) — `ingest(NormalizedEvent)` single write entry; `notifyObservers`; remove inline broadcast + `onStatusTransition` direct path.
- `Sources/Status/StatusPublisher.swift` (modify) — become a pure lookout: build `ScanDecoder` → `decode()` → `ShipLog.ingest`; delete `scheduleWebhookRefresh` direct path.
- `Sources/Core/FirstMateCoordinator.swift` (modify) — accept `IngestOutcome`, filter high-frequency events.
- Tests under `Tests/`.

---

### Task 1: Add status-component fields + extract pure `SailorReducer`

Behavior-preserving refactor. Today `ShipLog.updateStatus` mutates the snapshot and computes a `changed` flag inline. Extract that into a pure function and add the two component fields (`scanStatus`, `hookStatus`) the later tasks need. The fields are added now (defaulted, not yet driving the public status) so the struct is ready; the merge is wired in Task 3.

**Files:**
- Modify: `Sources/Core/SailorInfo.swift:3-26`
- Create: `Sources/Core/SailorReducer.swift`
- Modify: `Sources/Core/ShipLog.swift:142-193`
- Test: `Tests/SailorReducerTests.swift`

**Interfaces:**
- Consumes: `SailorInfo`, `SailorStatus`, `TaskItem`.
- Produces:
  - `SailorInfo.scanStatus: SailorStatus` (default `.unknown`), `SailorInfo.hookStatus: SailorStatus` (default `.unknown`).
  - `enum SailorReducer { static func apply(to info: SailorInfo, status: SailorStatus, lastMessage: String, roundDuration: TimeInterval, tasks: [TaskItem], lastUserPrompt: String) -> (info: SailorInfo, changed: Bool, previousStatus: SailorStatus) }`

- [ ] **Step 1: Add component fields to `SailorInfo`**

In `Sources/Core/SailorInfo.swift`, after the `activityEvents` line (line 19) add:

```swift
    var scanStatus: SailorStatus = .unknown   // latest screen-scan observation (component)
    var hookStatus: SailorStatus = .unknown   // webhook-accumulated inference (component)
```

(Both have defaults, so the existing memberwise initializer call sites in `ShipLog.swift` keep compiling unchanged.)

- [ ] **Step 2: Write the failing test for `SailorReducer.apply`**

Create `Tests/SailorReducerTests.swift`:

```swift
import XCTest
@testable import seahelm

final class SailorReducerTests: XCTestCase {
    private func makeInfo(status: SailorStatus = .unknown, message: String = "") -> SailorInfo {
        SailorInfo(id: "t1", worktreePath: "/wt", agentType: .unknown,
                   project: "proj", branch: "main", status: status, lastMessage: message,
                   commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                   channel: nil, taskProgress: TaskProgress())
    }

    func testApplyDetectsStatusChange() {
        let info = makeInfo(status: .idle, message: "old")
        let out = SailorReducer.apply(to: info, status: .running, lastMessage: "new",
                                      roundDuration: 5, tasks: [], lastUserPrompt: "")
        XCTAssertTrue(out.changed)
        XCTAssertEqual(out.previousStatus, .idle)
        XCTAssertEqual(out.info.status, .running)
        XCTAssertEqual(out.info.lastMessage, "new")
        XCTAssertEqual(out.info.roundDuration, 5)
    }

    func testApplyNoChangeWhenIdentical() {
        let info = makeInfo(status: .running, message: "same")
        let out = SailorReducer.apply(to: info, status: .running, lastMessage: "same",
                                      roundDuration: 0, tasks: [], lastUserPrompt: "")
        XCTAssertFalse(out.changed)
    }

    func testApplyKeepsExistingUserPromptWhenBlank() {
        var info = makeInfo()
        info.lastUserPrompt = "keep me"
        let out = SailorReducer.apply(to: info, status: .running, lastMessage: "m",
                                      roundDuration: 0, tasks: [], lastUserPrompt: "")
        XCTAssertEqual(out.info.lastUserPrompt, "keep me")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SailorReducerTests`
Expected: FAIL — `SailorReducer` is undefined (and the new test file must be registered: run `xcodegen generate` first if the test target can't see it).

- [ ] **Step 4: Implement `SailorReducer`**

Create `Sources/Core/SailorReducer.swift`:

```swift
import Foundation

/// Pure status reducer: old snapshot + applied inputs → new snapshot + change delta.
/// No IO, no singletons. Mirrors the field-application logic formerly inline in
/// ShipLog.updateStatus so it can be unit-tested and reused by ingest().
enum SailorReducer {
    static func apply(to info: SailorInfo,
                      status: SailorStatus,
                      lastMessage: String,
                      roundDuration: TimeInterval,
                      tasks: [TaskItem],
                      lastUserPrompt: String) -> (info: SailorInfo, changed: Bool, previousStatus: SailorStatus) {
        var next = info
        let previousStatus = info.status
        let changed = info.status != status
            || info.lastMessage != lastMessage
            || info.tasks.count != tasks.count
        next.status = status
        next.lastMessage = lastMessage
        if !lastUserPrompt.isEmpty {
            next.lastUserPrompt = lastUserPrompt
        }
        next.roundDuration = roundDuration
        next.tasks = tasks
        return (next, changed, previousStatus)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/SailorReducerTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Route `ShipLog.updateStatus` through `SailorReducer`**

In `Sources/Core/ShipLog.swift`, replace the body of `updateStatus` (lines 145-162, from `lock.lock()` through the first `lock.unlock()`) so the field mutation + change detection uses the reducer. Replace:

```swift
        lock.lock()
        guard var info = agents[terminalID] else {
            lock.unlock()
            return
        }
        let previousStatus = info.status
        let changed = info.status != status || info.lastMessage != lastMessage
            || info.tasks.count != tasks.count
        info.status = status
        info.lastMessage = lastMessage
        if !lastUserPrompt.isEmpty {
            info.lastUserPrompt = lastUserPrompt
        }
        info.roundDuration = roundDuration
        info.tasks = tasks
        agents[terminalID] = info
        let hasExternalChannels = !externalChannels.isEmpty
        lock.unlock()
```

with:

```swift
        lock.lock()
        guard let current = agents[terminalID] else {
            lock.unlock()
            return
        }
        let reduced = SailorReducer.apply(to: current, status: status,
                                          lastMessage: lastMessage, roundDuration: roundDuration,
                                          tasks: tasks, lastUserPrompt: lastUserPrompt)
        let info = reduced.info
        let previousStatus = reduced.previousStatus
        let changed = reduced.changed
        agents[terminalID] = info
        let hasExternalChannels = !externalChannels.isEmpty
        lock.unlock()
```

(The rest of `updateStatus` — the `if changed { … }` block — is unchanged; it already reads `info`, `previousStatus`, `changed`.)

- [ ] **Step 7: Build to verify no regressions**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Run existing ShipLog tests to confirm behavior preserved**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ShipLogTests -only-testing:seahelmTests/ShipLogIngestTests -only-testing:seahelmTests/ShipLogActivityEventTests`
Expected: PASS (no behavior change).

- [ ] **Step 9: Commit**

```bash
xcodegen generate
git add Sources/Core/SailorInfo.swift Sources/Core/SailorReducer.swift Sources/Core/ShipLog.swift Tests/SailorReducerTests.swift seahelm.xcodeproj/project.pbxproj
git commit -m "refactor: extract pure SailorReducer + add scan/hook status components"
```

---

### Task 2: Introduce `NormalizedEvent` and switch decoders to produce it

Create the unified input language and migrate both live decoders to it. `StatusReport` stays alive only as the carrier inside `.screenObserved`'s payload is replaced — we drop `StatusReport` entirely once ingest is migrated (Task 3); in this task the decoders return `NormalizedEvent?`.

**Files:**
- Create: `Sources/Status/NormalizedEvent.swift`
- Modify: `Sources/Status/SignalDecoder.swift:1-8`
- Modify: `Sources/Status/ScanDecoder.swift:12-22`
- Modify: `Sources/Status/HookDecoder.swift` (whole file)
- Test: `Tests/NormalizedEventDecoderTests.swift`

**Interfaces:**
- Consumes: `SailorStatus`, `SailorType`, `ActivityEvent`, `TaskItem`, `WebhookEvent`, `StatusDetector`, `ProcessStatus`, `ShellPhaseInfo`, `SailorDef`, `ActivityEventExtractor`.
- Produces:
  - `enum EventSource { case scan; case hook(String); case mcp; case shell }`
  - `enum NormalizedEventKind { case sessionStarted(label: String); case userPrompt(String); case toolUse(ActivityEvent); case awaitingInput(String); case agentStopped(success: Bool); case notification(level: String, text: String); case taskUpdate([TaskItem]); case suggest(options: [String]); case screenObserved(status: SailorStatus, message: String, activity: [ActivityEvent], commandLine: String?, agentType: SailorType) }`
  - `struct NormalizedEvent { let terminalID: String; let source: EventSource; let kind: NormalizedEventKind }`
  - `SignalDecoder.decode() -> NormalizedEvent?`
  - `HookDecoder.kind(for: WebhookEvent) -> NormalizedEventKind?` (nil = no station event, e.g. `cwd_changed`)

- [ ] **Step 1: Write the failing test for the HookDecoder mapping table**

Create `Tests/NormalizedEventDecoderTests.swift`:

```swift
import XCTest
@testable import seahelm

final class NormalizedEventDecoderTests: XCTestCase {
    private func event(_ type: WebhookEventType, data: [String: Any]? = nil) -> WebhookEvent {
        WebhookEvent(source: "claude-code", sessionId: "s", event: type,
                     cwd: "/wt", timestamp: nil, data: data)
    }

    func testAgentStopMapsToCompletionSuccess() {
        let kind = HookDecoder.kind(for: event(.agentStop))
        guard case .agentStopped(let success)? = kind else { return XCTFail("wrong kind") }
        XCTAssertTrue(success)
    }

    func testStopFailureMapsToCompletionFailure() {
        let kind = HookDecoder.kind(for: event(.stopFailure))
        guard case .agentStopped(let success)? = kind else { return XCTFail("wrong kind") }
        XCTAssertFalse(success)
    }

    func testPromptMapsToAwaitingInput() {
        let kind = HookDecoder.kind(for: event(.prompt, data: ["message": "need input"]))
        guard case .awaitingInput(let text)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(text, "need input")
    }

    func testErrorFoldsIntoNotificationErrorLevel() {
        let kind = HookDecoder.kind(for: event(.error, data: ["message": "boom"]))
        guard case .notification(let level, let text)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(level, "error")
        XCTAssertEqual(text, "boom")
    }

    func testToolUseStartMapsToToolUse() {
        let kind = HookDecoder.kind(for: event(.toolUseStart, data: ["tool_name": "Bash"]))
        guard case .toolUse? = kind else { return XCTFail("wrong kind") }
    }

    func testSessionStartMapsToSessionStartedWithLabel() {
        let kind = HookDecoder.kind(for: event(.sessionStart))
        guard case .sessionStarted(let label)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(label, "Session started")
    }

    func testCwdChangedProducesNoKind() {
        XCTAssertNil(HookDecoder.kind(for: event(.cwdChanged)))
    }

    func testSuggestMapsToSuggestOptions() {
        let kind = HookDecoder.kind(for: event(.suggest, data: ["options": ["a", "b"]]))
        guard case .suggest(let options)? = kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(options, ["a", "b"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/NormalizedEventDecoderTests`
Expected: FAIL — `NormalizedEvent` / `HookDecoder.kind(for:)` undefined.

- [ ] **Step 3: Create `NormalizedEvent.swift`**

Create `Sources/Status/NormalizedEvent.swift`:

```swift
import Foundation

/// Where a normalized event came from.
enum EventSource {
    case scan
    case hook(String)   // raw webhook source string, e.g. "claude-code" / "codex"
    case mcp            // future
    case shell          // future
}

/// The single input language. Event-native cases (hook/mcp/shell) carry no status —
/// reduce derives hookStatus. Screen-native (.screenObserved) carries the observed scan status.
enum NormalizedEventKind {
    case sessionStarted(label: String)        // session_start / worktree_create / subagent_start
    case userPrompt(String)                   // user_prompt — user submitted
    case toolUse(ActivityEvent)               // tool_use_start/end/failed
    case awaitingInput(String)                // prompt — agent waiting for input
    case agentStopped(success: Bool)          // agent_stop(true) / stop_failure(false)
    case notification(level: String, text: String)  // notification / error(level:"error")
    case taskUpdate([TaskItem])               // future (MCP / derived)
    case suggest(options: [String])           // agent-authored candidate orders
    case screenObserved(status: SailorStatus,
                        message: String,
                        activity: [ActivityEvent],
                        commandLine: String?,
                        agentType: SailorType)
}

struct NormalizedEvent {
    let terminalID: String
    let source: EventSource
    let kind: NormalizedEventKind
}
```

- [ ] **Step 4: Change the `SignalDecoder` protocol**

Replace the whole of `Sources/Status/SignalDecoder.swift` with:

```swift
import Foundation

/// 信号员:把某一来源的原始数据翻译成统一的 NormalizedEvent(只翻译,不裁决)。
protocol SignalDecoder {
    func decode() -> NormalizedEvent?   // 返回 nil = 本次无可上报
}
```

- [ ] **Step 5: Rewrite `HookDecoder` with the aligned mapping table**

Replace the whole of `Sources/Status/HookDecoder.swift` with:

```swift
import Foundation

/// 被动通道的信号员:webhook 事件 → NormalizedEvent。
/// 映射表见 spec「14 种 webhook 事件 → Kind 对齐表」。
struct HookDecoder: SignalDecoder {
    let terminalID: String
    let event: WebhookEvent

    func decode() -> NormalizedEvent? {
        guard let kind = Self.kind(for: event) else { return nil }
        return NormalizedEvent(terminalID: terminalID, source: .hook(event.source), kind: kind)
    }

    /// Pure mapping. Returns nil for events that produce no station event (cwd_changed).
    static func kind(for event: WebhookEvent) -> NormalizedEventKind? {
        switch event.event {
        case .sessionStart:
            return .sessionStarted(label: "Session started")
        case .worktreeCreate:
            return .sessionStarted(label: "Creating worktree")
        case .subagentStart:
            return .sessionStarted(label: "Subagent started")
        case .userPrompt:
            return .userPrompt(event.data?["message"] as? String ?? "Processing prompt")
        case .toolUseStart, .toolUseEnd, .toolUseFailed:
            return .toolUse(ActivityEventExtractor.extract(from: event))
        case .prompt:
            return .awaitingInput(event.data?["message"] as? String ?? "Waiting for input")
        case .agentStop:
            return .agentStopped(success: true)
        case .stopFailure:
            return .agentStopped(success: false)
        case .notification:
            let level = event.data?["level"] as? String ?? "info"
            let text = event.data?["message"] as? String ?? event.data?["title"] as? String ?? ""
            return .notification(level: level, text: text)
        case .error:
            return .notification(level: "error", text: event.data?["message"] as? String ?? "Error")
        case .suggest:
            let options = (event.data?["options"] as? [String]) ?? []
            return .suggest(options: options)
        case .cwdChanged:
            return nil
        }
    }
}
```

- [ ] **Step 6: Rewrite `ScanDecoder` to produce `.screenObserved`**

Replace the whole of `Sources/Status/ScanDecoder.swift` with:

```swift
import Foundation

/// 主动通道的信号员:扫屏文本 + 进程状态 → NormalizedEvent(.screenObserved)。
/// 取数(瞭望员)发生在 StatusPublisher;本类型只负责解码。
struct ScanDecoder: SignalDecoder {
    let terminalID: String
    let detector: StatusDetector
    let processStatus: ProcessStatus
    let shellInfo: ShellPhaseInfo?
    let content: String
    let agentDef: SailorDef?
    let commandLine: String?
    let agentType: SailorType

    func decode() -> NormalizedEvent? {
        let status = detector.detect(
            processStatus: processStatus,
            shellInfo: shellInfo,
            content: content,
            agentDef: agentDef
        )
        let events = detector.extractActivityEvents(from: content)
        let kind = NormalizedEventKind.screenObserved(
            status: status, message: "", activity: events,
            commandLine: commandLine, agentType: agentType)
        return NormalizedEvent(terminalID: terminalID, source: .scan, kind: kind)
    }
}
```

- [ ] **Step 7: Delete `StatusReport.swift`**

`StatusReport` is now unused by the decoders. It is still referenced by `ShipLog.ingest(report:)` and `StatusPublisher` until Task 3. To keep this task compiling, do NOT delete yet — defer deletion to Task 3 Step 8. Leave `Sources/Status/StatusReport.swift` as-is for now.

- [ ] **Step 8: Run the decoder tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/NormalizedEventDecoderTests`
Expected: PASS (8 tests).

Note: this task changes `ScanDecoder`/`HookDecoder` construction signatures, so `StatusPublisher` and `ShipLog.handleWebhookEvent` callers will not compile yet — they are migrated in Task 3. Do not run a full build at this step; proceed to Task 3, which restores compilation.

- [ ] **Step 9: Commit**

```bash
git add Sources/Status/NormalizedEvent.swift Sources/Status/SignalDecoder.swift Sources/Status/HookDecoder.swift Sources/Status/ScanDecoder.swift Tests/NormalizedEventDecoderTests.swift seahelm.xcodeproj/project.pbxproj
git commit -m "feat: introduce NormalizedEvent and migrate decoders"
```

---

### Task 3: `ingest(NormalizedEvent)` single entry + reduce + `IngestOutcome`

Replace the four scattered write paths with one `ingest(NormalizedEvent)` that (1) faithfully records, (2) reduces to a station snapshot with `scanStatus`/`hookStatus` components recomputed via `highestPriority`, (3) emits one `IngestOutcome`. Migrate `StatusPublisher` and `handleWebhookEvent` to it; delete the `WebhookStatusProvider.onStatusChanged → scheduleWebhookRefresh` direct path.

**Files:**
- Create: `Sources/Core/IngestOutcome.swift`
- Modify: `Sources/Core/ShipLog.swift` (add `ingest(NormalizedEvent)`, `eventLog`, `reduce`, `notifyObservers`; rewire `handleWebhookEvent`; remove inline `broadcast` + `onStatusTransition` from `updateStatus`)
- Modify: `Sources/Status/StatusPublisher.swift:201-304` (build `ScanDecoder` with new signature → `ingest`; delete webhook refresh direct path)
- Delete: `Sources/Status/StatusReport.swift`
- Test: `Tests/ShipLogIngestOutcomeTests.swift`

**Interfaces:**
- Consumes: `NormalizedEvent`, `NormalizedEventKind`, `SailorReducer`, `SailorStatus.highestPriority`, `SailorInfo.scanStatus`/`hookStatus`.
- Produces:
  - `struct IngestOutcome { let info: SailorInfo; let statusChanged: Bool; let oldStatus: SailorStatus; let newStatus: SailorStatus; let holdSeconds: Double; let isCompletionSignal: Bool; let event: NormalizedEvent }`
  - `ShipLog.ingest(_ event: NormalizedEvent)`
  - `ShipLog.onOutcome: ((IngestOutcome) -> Void)?` (replaces `onStatusTransition`)

- [ ] **Step 1: Create `IngestOutcome.swift`**

Create `Sources/Core/IngestOutcome.swift`:

```swift
import Foundation

/// The single output of ShipLog.ingest — one per recorded event.
/// Subscribers (UI, aggregator, FirstMate, external broadcast) react to this; they do not
/// read ShipLog state directly for the change that just happened.
struct IngestOutcome {
    let info: SailorInfo
    let statusChanged: Bool
    let oldStatus: SailorStatus
    let newStatus: SailorStatus
    let holdSeconds: Double
    let isCompletionSignal: Bool
    let event: NormalizedEvent
}
```

- [ ] **Step 2: Write the failing test for component merge + outcome**

Create `Tests/ShipLogIngestOutcomeTests.swift`:

```swift
import XCTest
@testable import seahelm

final class ShipLogIngestOutcomeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ShipLog.shared.registerForTesting(terminalID: "t1", worktreePath: "/wt",
                                          branch: "main", project: "proj")
    }
    override func tearDown() {
        ShipLog.shared.unregister(terminalID: "t1")
        ShipLog.shared.onOutcome = nil
        super.tearDown()
    }

    func testHookRunningThenScanIdleMergesToRunning() {
        // hookStatus=running (higher priority than idle) must survive a later scan idle.
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .sessionStarted(label: "Session started")))
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        ShipLog.shared.onOutcome = { o in captured = o; exp.fulfill() }
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .scan,
            kind: .screenObserved(status: .idle, message: "", activity: [],
                                  commandLine: nil, agentType: .claudeCode)))
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .running)  // highestPriority(scan=idle, hook=running)
    }

    func testAgentStoppedFailureIsCompletionWithError() {
        var captured: IngestOutcome?
        let exp = expectation(description: "outcome")
        ShipLog.shared.onOutcome = { o in captured = o; exp.fulfill() }
        ShipLog.shared.ingest(NormalizedEvent(terminalID: "t1", source: .hook("claude-code"),
                                              kind: .agentStopped(success: false)))
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(captured?.isCompletionSignal ?? false)
        XCTAssertEqual(captured?.newStatus, .error)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ShipLogIngestOutcomeTests`
Expected: FAIL — `ingest(NormalizedEvent)` / `onOutcome` undefined.

- [ ] **Step 4: Add `eventLog`, `onOutcome`, `ingest`, and `reduce` to `ShipLog`**

In `Sources/Core/ShipLog.swift`:

(a) Replace the `onStatusTransition` property (line 17) with:

```swift
    /// Single output stream: one IngestOutcome per recorded event, delivered on the main thread.
    var onOutcome: ((IngestOutcome) -> Void)?
```

(b) Add a faithful event log field next to `agents` (after line 22):

```swift
    private var eventLog: [String: [NormalizedEvent]] = [:]   // tid → recent N, ring buffer, never persisted
```

(c) Add the new single write entry and the pure reduce. Insert after the existing `ingest(terminalID:report:…)` method (after line 216). Then in Task Step 8 the old report-based `ingest` and `updateStatus`-as-public-entry are retired; for this step add the new method alongside:

```swift
    /// THE single write entry. Faithfully record, then reduce to a station snapshot + outcome.
    func ingest(_ event: NormalizedEvent) {
        lock.lock()
        appendToRingBufferLog(event)
        guard let current = agents[event.terminalID] else { lock.unlock(); return }

        var next = current
        var isCompletion = false
        var message = current.lastMessage

        switch event.kind {
        case .screenObserved(let status, let msg, let activity, let commandLine, let agentType):
            next.scanStatus = status
            if !msg.isEmpty { message = msg }
            if let cl = commandLine { next.commandLine = cl }
            if agentType != .unknown { next.agentType = agentType }
            if !activity.isEmpty { next.activityEvents = activity }
        case .sessionStarted(let label):
            next.hookStatus = .running
            message = label
        case .userPrompt(let text):
            next.hookStatus = .running
            next.lastUserPrompt = text
        case .toolUse(let ev):
            next.hookStatus = .running
            Self.upsertLatest(&next.activityEvents, event: ev, maxSize: 20)
            message = ev.detail.isEmpty ? message : ev.detail
        case .awaitingInput(let text):
            next.hookStatus = .waiting
            message = text
        case .agentStopped(let success):
            next.hookStatus = success ? .idle : .error
            next.activityEvents.removeAll()
            isCompletion = true
        case .notification(let level, let text):
            switch level {
            case "error": next.hookStatus = .error
            case "warning": next.hookStatus = .waiting
            default: break
            }
            if !text.isEmpty { message = text }
        case .taskUpdate(let items):
            next.tasks = items
        case .suggest:
            break   // does not touch status; passed through via outcome.event
        }

        next.lastMessage = message
        let oldStatus = current.status
        let newStatus = SailorStatus.highestPriority([next.scanStatus, next.hookStatus])
        next.status = newStatus
        agents[event.terminalID] = next

        let now = Date()
        let statusChanged = oldStatus != newStatus
        var hold: Double = 0
        if statusChanged {
            let entered = statusEnteredAt[event.terminalID] ?? now
            hold = now.timeIntervalSince(entered)
            statusEnteredAt[event.terminalID] = now
        }
        let hasExternalChannels = !externalChannels.isEmpty
        lock.unlock()

        let outcome = IngestOutcome(info: next, statusChanged: statusChanged,
                                    oldStatus: oldStatus, newStatus: newStatus,
                                    holdSeconds: hold, isCompletionSignal: isCompletion,
                                    event: event)
        notifyObservers(outcome, hasExternalChannels: hasExternalChannels)
    }

    /// All observer delivery hops to main for ordering. Subscribers never run on the scan queue.
    private func notifyObservers(_ outcome: IngestOutcome, hasExternalChannels: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if outcome.statusChanged || outcome.info.status != outcome.oldStatus {
                self.delegate?.agentDidUpdate(outcome.info)
            } else {
                self.delegate?.agentDidUpdate(outcome.info)
            }
            self.onOutcome?(outcome)
            if hasExternalChannels && outcome.statusChanged
                && (outcome.newStatus == .waiting || outcome.newStatus == .error) {
                let i = outcome.info
                self.broadcast("[\(i.project)] \(outcome.newStatus.icon) \(outcome.newStatus.rawValue): \(i.lastMessage)",
                               format: .markdown)
            }
        }
    }

    private func appendToRingBufferLog(_ event: NormalizedEvent) {
        var log = eventLog[event.terminalID] ?? []
        log.insert(event, at: 0)
        if log.count > 50 { log.removeLast() }
        eventLog[event.terminalID] = log
    }

    /// Ring-buffer upsert used by reduce for .toolUse (mirrors upsertLatestActivityEvent).
    static func upsertLatest(_ buffer: inout [ActivityEvent], event: ActivityEvent, maxSize: Int) {
        if let latest = buffer.first, latest.tool == event.tool, latest.detail == event.detail {
            buffer[0] = event
        } else {
            appendToRingBuffer(&buffer, event: event, maxSize: maxSize)
        }
    }
```

(Note: the `notifyObservers` `if/else` both call `agentDidUpdate` — collapse to a single call; kept explicit here to flag that UI refreshes on every outcome, not only status changes. Simplify to one `self.delegate?.agentDidUpdate(outcome.info)`.)

- [ ] **Step 5: Run the new test to verify it passes**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ShipLogIngestOutcomeTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Rewire `handleWebhookEvent` to ingest via `HookDecoder`**

In `Sources/Core/ShipLog.swift`, replace the body of `handleWebhookEvent` (lines 347-390) below the cwd→tid resolution and the source-based `updateDetection` calls (keep lines 348-366 that resolve `tid` and upgrade detection) with:

```swift
        // cwd_changed only updates routing (handled above via worktreeIndex); no station event.
        guard let event2 = HookDecoder(terminalID: tid, event: event).decode() else { return }
        ingest(event2)
        if let hooks = channel(for: tid) as? HooksChannel {
            hooks.handleWebhookEvent(event)
        }
```

Delete the old `switch event.event { case .toolUseStart…/.agentStop… }` block (lines 372-389) — reduce now owns activity upsert and completion.

- [ ] **Step 7: Migrate `StatusPublisher` to the new `ScanDecoder` + `ingest`**

In `Sources/Status/StatusPublisher.swift`, in the poll body, replace the `ScanDecoder(...)` construction (around lines 235-241), the `highestPriority` merge (lines 243-244), and the `ShipLog.shared.ingest(terminalID:report:…)` call (lines 285-293) with a single decode→ingest. The merge now happens inside ShipLog.reduce, so StatusPublisher no longer reads `webhookProvider.status(for:)`:

```swift
        let normalized = ScanDecoder(
            terminalID: terminalID,
            detector: detector,
            processStatus: processStatus,
            shellInfo: nil,
            content: content,
            agentDef: agentDef,
            commandLine: detectedCommandLine,
            agentType: detectedAgentType
        ).decode()
        if let normalized {
            ShipLog.shared.ingest(normalized)
        }
```

(Use the publisher's existing local variables for `detectedCommandLine` / `detectedAgentType`; if the current code computed `lastMessage`/`webhookTasks` only to pass into the old `ingest`, those become dead and should be removed.) Then delete the `scheduleWebhookRefresh`/`onStatusChanged` direct-to-`updateStatus` path (lines 137-199) entirely — webhook now flows only through `handleWebhookEvent → ingest`.

- [ ] **Step 8: Retire `StatusReport` and the old `ingest(report:)`/`onStatusTransition`**

- Delete `Sources/Status/StatusReport.swift`.
- Delete the old `ingest(terminalID:report:…)` method (lines 199-216) from `ShipLog.swift`.
- Remove the inline `onStatusTransition` block and inline `broadcast` from `updateStatus` (lines 169-191) — these are superseded by `notifyObservers`. Keep `updateStatus` itself only if other callers remain (`updateTaskProgress`/`updateDetection` do not call it); if no callers remain, delete `updateStatus` too. Grep first: `grep -rn "updateStatus\|onStatusTransition\|\.ingest(terminalID" Sources Tests`.
- Update any remaining references found by that grep (e.g. `MainWindowController` wiring `onStatusTransition`) to use `onOutcome` (Task 4 covers the coordinator wiring).

- [ ] **Step 9: Build and run the pipeline test suite**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED (fix any remaining `StatusReport`/`onStatusTransition` references the grep surfaced).

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ShipLogIngestOutcomeTests -only-testing:seahelmTests/ShipLogActivityEventTests -only-testing:seahelmTests/NormalizedEventDecoderTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: single ingest(NormalizedEvent) entry + IngestOutcome, retire StatusReport"
```

---

### Task 4: Downstream subscribes to `IngestOutcome`; FirstMate filters high-frequency events

Make FirstMate consume `IngestOutcome` (mapping it to the existing `StatusTransition` rule engine) and gate it so high-frequency events (`.toolUse`, etc.) do not reach adjudication. UI and external broadcast already react via `notifyObservers` (Task 3); this task wires the coordinator.

**Files:**
- Modify: `Sources/Core/FirstMateCoordinator.swift` (add `handle(_ outcome: IngestOutcome)`)
- Modify: `Sources/App/MainWindowController.swift` (set `ShipLog.shared.onOutcome` instead of `onStatusTransition`)
- Test: `Tests/FirstMateCoordinatorOutcomeTests.swift`

**Interfaces:**
- Consumes: `IngestOutcome`, `StatusTransition`, `FirstMate.evaluate`.
- Produces: `FirstMateCoordinator.handle(_ outcome: IngestOutcome)`.

- [ ] **Step 1: Write the failing test for the FirstMate filter**

Create `Tests/FirstMateCoordinatorOutcomeTests.swift`:

```swift
import XCTest
@testable import seahelm

final class FirstMateCoordinatorOutcomeTests: XCTestCase {
    private func outcome(kind: NormalizedEventKind, changed: Bool, completion: Bool,
                         newStatus: SailorStatus) -> IngestOutcome {
        let info = SailorInfo(id: "t1", worktreePath: "/wt", agentType: .claudeCode,
                              project: "p", branch: "b", status: newStatus, lastMessage: "",
                              commandLine: nil, roundDuration: 0, startedAt: nil, station: nil,
                              channel: nil, taskProgress: TaskProgress())
        return IngestOutcome(info: info, statusChanged: changed, oldStatus: .running,
                             newStatus: newStatus, holdSeconds: 0, isCompletionSignal: completion,
                             event: NormalizedEvent(terminalID: "t1", source: .hook("claude-code"), kind: kind))
    }

    func testHighFrequencyToolUseIsNotEvaluated() {
        var evaluated = false
        let coord = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in evaluated = true }, runInspection: { _ in evaluated = true },
            hasOrders: { _ in true })
        let act = ActivityEvent(tool: "Bash", detail: "ls")
        coord.handle(outcome(kind: .toolUse(act), changed: false, completion: false, newStatus: .running))
        XCTAssertFalse(evaluated, "tool_use without status change must not reach FirstMate")
    }

    func testCompletionSignalIsEvaluated() {
        var inspected = false
        let coord = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in }, runInspection: { _ in inspected = true },
            hasOrders: { _ in true })
        coord.handle(outcome(kind: .agentStopped(success: true), changed: true,
                             completion: true, newStatus: .idle))
        XCTAssertTrue(inspected, "completion must trigger inspect (autoInspect default true)")
    }
}
```

(If `ActivityEvent`'s initializer differs from `ActivityEvent(tool:detail:)`, adjust to the real memberwise init in `Sources/Core/ActivityEvent.swift` — check before running.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/FirstMateCoordinatorOutcomeTests`
Expected: FAIL — `handle(_ outcome:)` undefined.

- [ ] **Step 3: Add `handle(_ outcome:)` to `FirstMateCoordinator`**

In `Sources/Core/FirstMateCoordinator.swift`, add:

```swift
    /// Entry from ShipLog.onOutcome. Filters high-frequency events away from adjudication,
    /// then maps the outcome to a StatusTransition for the existing rule engine.
    func handle(_ outcome: IngestOutcome) {
        dispatchPrecondition(condition: .onQueue(.main))
        let isSuggest: Bool = { if case .suggest = outcome.event.kind { return true }; return false }()
        guard outcome.statusChanged || outcome.isCompletionSignal || isSuggest else { return }
        let t = StatusTransition(
            worktreePath: outcome.info.worktreePath, branch: outcome.info.branch,
            project: outcome.info.project, terminalID: outcome.info.id,
            oldStatus: outcome.oldStatus, newStatus: outcome.newStatus,
            holdSeconds: outcome.holdSeconds, isCompletionSignal: outcome.isCompletionSignal)
        handle(t)
    }
```

(The existing `handle(_ t: StatusTransition)` stays; `.suggest` handling — building a red-zone order with options — is part of the separate suggestion plan, so for now suggest outcomes pass through `handle(t)` and produce no action.)

- [ ] **Step 4: Wire `MainWindowController` to `onOutcome`**

In `Sources/App/MainWindowController.swift`, find where `ShipLog.shared.onStatusTransition` was assigned (grep: `grep -n "onStatusTransition" Sources/App/MainWindowController.swift`) and replace the assignment with:

```swift
        ShipLog.shared.onOutcome = { [weak self] outcome in
            self?.firstMateCoordinator?.handle(outcome)
        }
```

(Use the real coordinator property name found in that file.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/FirstMateCoordinatorOutcomeTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Full build + targeted suite**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/FirstMateCoordinatorOutcomeTests -only-testing:seahelmTests/ShipLogIngestOutcomeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: FirstMate subscribes to IngestOutcome with high-frequency filter"
```

---

## Out of scope (separate plan)

- Spec step 5: merge `SuggestionFeed` into `PendingOrder` (`.suggest` → red-zone order with `options`).
- Spec step 6: suggestion reliability via Stop-hook reverse-trigger (`WebhookServer` returns `decision:block`; `suggestOnStop` config; `stop_hook_active` loop guard; Codex `hookCommand` stdout fix).
- Spec step 7: `MCPDecoder` / `ShellDecoder` (no current code; future).

These will be covered in `docs/superpowers/plans/2026-06-25-data-pipeline-suggestion.md`.

## Self-Review Notes

- **Spec coverage (steps 1–4):** Task 1 = step 1 (reduce extraction + components); Task 2 = step 2 (NormalizedEvent + decoders); Task 3 = step 3 (single ingest + IngestOutcome + webhook entry merge + StatusReport retirement); Task 4 = step 4 (downstream subscribe + FirstMate filter + broadcast moved to notifyObservers). The waiting-timeout heartbeat constraint relies on the periodic `.screenObserved` ingest preserved in Task 3 Step 7.
- **Known verification points for the implementer:** real `ActivityEvent` initializer (Task 4 Step 1), real coordinator property name on `MainWindowController` (Task 4 Step 4), and the exact local variable names in `StatusPublisher`'s poll body (Task 3 Step 7). Each step says to grep/check before running.
</content>
</invoke>
