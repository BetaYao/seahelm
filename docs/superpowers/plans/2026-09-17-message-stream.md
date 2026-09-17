# MessageStream Text Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project a typed per-pane MessageStream from `AgentRegistry` ingest, expose it on the control socket and Host Gateway, and make seahelm-web’s phone path render that timeline by default instead of opening VT.

**Architecture:** Keep `AgentRegistry` as snapshot SSOT. After each `IngestOutcome`, a pure `PaneMessageProjector` emits typed `MessageEvent`s into `MessageStreamHub` (per-pane ring + seq). Gateway/control clients subscribe to `pane.message`; seahelm-web draws the ring on narrow viewports and keeps VT opt-in.

**Tech Stack:** Swift 5.10 / AppKit host / Network.framework Host Gateway, XCTest, static `clients/seahelm-web` (no new npm app).

**Spec:** `docs/superpowers/specs/2026-09-17-message-stream-design.md`

## Global Constraints

- MessageStream must not write back into `PaneInfo` / `AgentRegistry`.
- Island / First Mate / status bar keep reading Registry; do not route them through MessageStream in this plan.
- Do not add viewport-regex chat extraction; `screen_fallback` defaults to **false**.
- VT (`pane.vt_open`) remains available; phone/narrow default must not call it on pane open.
- Tunnel / pairing / Gateway auth unchanged (`2026-08-10-web-host-gateway-design.md`).
- macOS 14+, Swift 5.10, `@testable import seahelm`, XCTest only.
- Prefer small types under `Sources/Core/`; extend existing Manifest decode with an optional `message` block.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Core/MessageEvent.swift` | Wire-stable `MessageEvent` + `MessageKind` + `dict` |
| `Sources/Core/MessageConfig.swift` | Per-agent display/fallback config (Codable) |
| `Sources/Core/PaneMessageProjector.swift` | Pure `(IngestOutcome, MessageConfig, coalesceState) → [MessageEvent]` |
| `Sources/Core/MessageStreamHub.swift` | Per-pane ring, seq, subscribe, snapshot |
| `Sources/Status/AgentManifest.swift` | Optional `message: MessageConfig?` |
| `Sources/Core/AgentRegistry.swift` | After notify, project + publish to hub; clear pane ring on unregister |
| `Sources/Core/ControlProtocol.swift` | `message.snapshot` (+ optional subscribe reuse) |
| `Sources/Core/SeahelmControlDataSource.swift` | Implement snapshot against hub |
| `Sources/Core/HostGatewayServer.swift` | Subscribe hub → fan-out sessions |
| `Sources/Core/HostGatewaySession.swift` | `pushMessage`, handle `message.snapshot` |
| `clients/seahelm-web/index.html` | Text-mode detail view; VT on demand |
| `clients/seahelm-web/README.md` | Document text-mode default |
| `Tests/PaneMessageProjectorTests.swift` | Projector behavior |
| `Tests/MessageStreamHubTests.swift` | Ring / replay / clear |
| `Tests/MessageConfigManifestTests.swift` | Manifest decode of `message` |
| `Tests/ControlMessageSnapshotTests.swift` | Router → hub snapshot |

---

### Task 1: `MessageEvent` + `MessageConfig` + Manifest decode

**Files:**
- Create: `Sources/Core/MessageEvent.swift`
- Create: `Sources/Core/MessageConfig.swift`
- Modify: `Sources/Status/AgentManifest.swift`
- Test: `Tests/MessageConfigManifestTests.swift`

**Interfaces:**
- Produces:
  - `enum MessageKind: String` — `user`, `assistant`, `tool`, `status`, `decision`, `notice`
  - `struct MessageEvent` with `seq: UInt64`, `paneId: String`, `paneSessionKey: String`, `kind: MessageKind`, `ts: Date`, optional `text`, `tool`, `detail`, `isError`, `status`, `oldStatus`, `count`, and `var dict: [String: Any]`
  - `struct MessageConfig: Equatable` with defaults; `static let `default``
  - `AgentManifest.message: MessageConfig?` decoded from key `"message"`
- Consumes: existing `AgentManifest` `decodeIfPresent` pattern

- [ ] **Step 1: Write the failing test**

Create `Tests/MessageConfigManifestTests.swift`:

```swift
import XCTest
@testable import seahelm

final class MessageConfigManifestTests: XCTestCase {
    func testManifestDecodesOptionalMessageBlock() throws {
        let json = """
        {
          "id": "cursor",
          "message": {
            "assistant_from": "stop_last_assistant_message",
            "user_fields": ["prompt", "message"],
            "tool_aliases": {"run_terminal_cmd": "Shell"},
            "coalesce_tools": true,
            "screen_fallback": false
          }
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(AgentManifest.self, from: json)
        XCTAssertEqual(m.id, "cursor")
        let msg = try XCTUnwrap(m.message)
        XCTAssertEqual(msg.assistantFrom, "stop_last_assistant_message")
        XCTAssertEqual(msg.userFields, ["prompt", "message"])
        XCTAssertEqual(msg.toolAliases["run_terminal_cmd"], "Shell")
        XCTAssertTrue(msg.coalesceTools)
        XCTAssertFalse(msg.screenFallback)
    }

    func testManifestWithoutMessageUsesNil() throws {
        let json = #"{"id":"claude"}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(AgentManifest.self, from: json)
        XCTAssertNil(m.message)
    }

    func testMessageEventDictShape() {
        let ev = MessageEvent(
            seq: 7,
            paneId: "p1",
            paneSessionKey: "seahelm-x",
            kind: .tool,
            ts: Date(timeIntervalSince1970: 100),
            tool: "Read",
            detail: "a.swift",
            isError: false,
            count: 1
        )
        let d = ev.dict
        XCTAssertEqual(d["seq"] as? UInt64, 7)
        XCTAssertEqual(d["kind"] as? String, "tool")
        XCTAssertEqual(d["tool"] as? String, "Read")
        XCTAssertEqual(d["detail"] as? String, "a.swift")
        XCTAssertEqual(d["pane_id"] as? String, "p1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/MessageConfigManifestTests test
```

Expected: FAIL — `MessageConfig` / `MessageEvent` / `message` property missing.

- [ ] **Step 3: Minimal types + manifest field**

`Sources/Core/MessageEvent.swift`:

```swift
import Foundation

enum MessageKind: String, Equatable {
    case user, assistant, tool, status, decision, notice
}

struct MessageEvent: Equatable {
    var seq: UInt64
    var paneId: String
    var paneSessionKey: String
    var kind: MessageKind
    var ts: Date
    var text: String? = nil
    var tool: String? = nil
    var detail: String? = nil
    var isError: Bool? = nil
    var status: String? = nil
    var oldStatus: String? = nil
    var count: Int = 1

    var dict: [String: Any] {
        var d: [String: Any] = [
            "seq": seq,
            "pane_id": paneId,
            "pane_session_key": paneSessionKey,
            "kind": kind.rawValue,
            "ts": ts.timeIntervalSince1970,
        ]
        if let text { d["text"] = text }
        if let tool { d["tool"] = tool }
        if let detail { d["detail"] = detail }
        if let isError { d["is_error"] = isError }
        if let status { d["status"] = status }
        if let oldStatus { d["old_status"] = oldStatus }
        if count > 1 { d["count"] = count }
        return d
    }
}
```

`Sources/Core/MessageConfig.swift`:

```swift
import Foundation

struct MessageConfig: Equatable {
    var assistantFrom: String = "stop_last_assistant_message"
    var userFields: [String] = ["prompt", "message"]
    var toolDetailKeys: [String: [String]] = [:]
    var toolAliases: [String: String] = [:]
    var coalesceTools: Bool = true
    var screenFallback: Bool = false

    static let `default` = MessageConfig()

    enum CodingKeys: String, CodingKey {
        case assistantFrom = "assistant_from"
        case userFields = "user_fields"
        case toolDetailKeys = "tool_detail_keys"
        case toolAliases = "tool_aliases"
        case coalesceTools = "coalesce_tools"
        case screenFallback = "screen_fallback"
    }
}

extension MessageConfig: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assistantFrom = try c.decodeIfPresent(String.self, forKey: .assistantFrom)
            ?? Self.default.assistantFrom
        userFields = try c.decodeIfPresent([String].self, forKey: .userFields)
            ?? Self.default.userFields
        toolDetailKeys = try c.decodeIfPresent([String: [String]].self, forKey: .toolDetailKeys)
            ?? [:]
        toolAliases = try c.decodeIfPresent([String: String].self, forKey: .toolAliases) ?? [:]
        coalesceTools = try c.decodeIfPresent(Bool.self, forKey: .coalesceTools) ?? true
        screenFallback = try c.decodeIfPresent(Bool.self, forKey: .screenFallback) ?? false
    }
}
```

In `AgentManifest.swift`: add `var message: MessageConfig? = nil`, CodingKey `message`, and `message = try c.decodeIfPresent(MessageConfig.self, forKey: .message)`.

If `AgentManifest` lacks a memberwise/init used by tests elsewhere, only extend `init(from:)`.

- [ ] **Step 4: Run tests — expect PASS**

Same `xcodebuild … MessageConfigManifestTests` command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/MessageEvent.swift Sources/Core/MessageConfig.swift \
  Sources/Status/AgentManifest.swift Tests/MessageConfigManifestTests.swift
git commit -m "$(cat <<'EOF'
feat: add MessageEvent and optional agent message config

EOF
)"
```

---

### Task 2: `PaneMessageProjector` (pure)

**Files:**
- Create: `Sources/Core/PaneMessageProjector.swift`
- Test: `Tests/PaneMessageProjectorTests.swift`

**Interfaces:**
- Consumes: `IngestOutcome`, `MessageConfig`, `MessageEvent`, `NormalizedEventKind`, `ActivityEvent`
- Produces:
  - `struct PaneMessageProjector`
  - `struct CoalesceState` — last tool fingerprint for the pane (`tool`, `detail`, `isError`)
  - `static func project(outcome:config:coalesce:now:) -> (events: [MessageEvent], coalesce: CoalesceState)`  
    (`seq` left `0` here; hub stamps seq on append)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import seahelm

final class PaneMessageProjectorTests: XCTestCase {
    private func outcome(
        kind: NormalizedEventKind,
        statusChanged: Bool = false,
        old: AgentStatus = .idle,
        new: AgentStatus = .running,
        isCompletion: Bool = false,
        assistant: String = "",
        paneId: String = "t1"
    ) -> IngestOutcome {
        var info = PaneInfo(
            id: paneId, worktreePath: "/wt", agentType: .cursor,
            project: "p", branch: "main", status: new,
            lastMessage: "", commandLine: nil, roundDuration: 0,
            startedAt: nil, station: nil, channel: nil,
            taskProgress: TaskProgress())
        info.lastAssistantMessage = assistant
        let event = NormalizedEvent(terminalID: paneId, source: .hook("cursor"), kind: kind)
        return IngestOutcome(
            info: info, statusChanged: statusChanged,
            oldStatus: old, newStatus: new, holdSeconds: 0,
            isCompletionSignal: isCompletion, event: event, seq: 1)
    }

    func testUserPromptEmitsUser() {
        let o = outcome(kind: .userPrompt("ship it"))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(evs.map(\.kind), [.user])
        XCTAssertEqual(evs.first?.text, "ship it")
    }

    func testToolUseEmitsTool() {
        let tool = ActivityEvent(tool: "Read", detail: "a.swift", isError: false, timestamp: Date())
        let o = outcome(kind: .toolUse(tool))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(evs.first?.kind, .tool)
        XCTAssertEqual(evs.first?.tool, "Read")
        XCTAssertEqual(evs.first?.detail, "a.swift")
    }

    func testCoalesceIdenticalTools() {
        let tool = ActivityEvent(tool: "Shell", detail: "ls", isError: false, timestamp: Date())
        let o = outcome(kind: .toolUse(tool))
        let (first, c1) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertEqual(first.count, 1)
        let (second, c2) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: c1, now: Date())
        XCTAssertTrue(second.isEmpty, "duplicate tool should coalesce into state only")
        XCTAssertEqual(c2.lastCount, 2)
    }

    func testAssistantOnlyOnCompletion() {
        let idle = outcome(kind: .agentStopped(success: true),
                           statusChanged: true, old: .running, new: .idle,
                           isCompletion: true, assistant: "done")
        let (evs, _) = PaneMessageProjector.project(
            outcome: idle, config: .default, coalesce: .empty, now: Date())
        XCTAssertTrue(evs.contains(where: { $0.kind == .assistant && $0.text == "done" }))
        XCTAssertTrue(evs.contains(where: { $0.kind == .status }))
    }

    func testNoAssistantWithoutCompletionSignal() {
        let o = outcome(kind: .toolUse(ActivityEvent(
            tool: "Read", detail: "x", isError: false, timestamp: Date())),
                        assistant: "stale prose")
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: .default, coalesce: .empty, now: Date())
        XCTAssertFalse(evs.contains(where: { $0.kind == .assistant }))
    }

    func testScreenFallbackOffIgnoresScanSoup() {
        var cfg = MessageConfig.default
        cfg.screenFallback = false
        let o = outcome(kind: .screenObserved(
            status: .running, message: "Shell", activity: [],
            commandLine: nil, agentType: .cursor, roundDuration: 1, tasks: []))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: cfg, coalesce: .empty, now: Date())
        XCTAssertTrue(evs.filter { $0.kind == .notice || $0.kind == .assistant }.isEmpty)
    }

    func testToolAliasApplied() {
        var cfg = MessageConfig.default
        cfg.toolAliases = ["run_terminal_cmd": "Shell"]
        let tool = ActivityEvent(tool: "run_terminal_cmd", detail: "ls",
                                 isError: false, timestamp: Date())
        let o = outcome(kind: .toolUse(tool))
        let (evs, _) = PaneMessageProjector.project(
            outcome: o, config: cfg, coalesce: .empty, now: Date())
        XCTAssertEqual(evs.first?.tool, "Shell")
    }
}
```

Adjust `PaneInfo` / `screenObserved` / `IngestOutcome` initializers to match the repo’s actual signatures if they differ — do not invent fields; open `PaneInfo.swift` and `NormalizedEvent.swift` and mirror them.

- [ ] **Step 2: Run tests — expect FAIL**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:seahelmTests/PaneMessageProjectorTests test
```

- [ ] **Step 3: Implement projector**

`Sources/Core/PaneMessageProjector.swift` (sketch — match tests exactly):

```swift
import Foundation

struct PaneMessageProjector {
    struct CoalesceState: Equatable {
        var lastTool: String? = nil
        var lastDetail: String? = nil
        var lastIsError: Bool? = nil
        var lastCount: Int = 0
        static let empty = CoalesceState()
    }

    static func project(
        outcome: IngestOutcome,
        config: MessageConfig,
        coalesce: CoalesceState,
        now: Date = Date()
    ) -> (events: [MessageEvent], coalesce: CoalesceState) {
        var out: [MessageEvent] = []
        var coal = coalesce
        let paneId = outcome.info.id
        let key = outcome.info.station?.paneSessionKey ?? ""

        func base(_ kind: MessageKind) -> MessageEvent {
            MessageEvent(seq: 0, paneId: paneId, paneSessionKey: key,
                         kind: kind, ts: now)
        }

        if outcome.statusChanged {
            var e = base(.status)
            e.status = outcome.newStatus.rawValue
            e.oldStatus = outcome.oldStatus.rawValue
            out.append(e)
            // New turn edge: reset tool coalesce when leaving running→idle etc. optional;
            // v1: reset coalesce on any status change to avoid cross-turn merge.
            coal = .empty
        }

        switch outcome.event.kind {
        case .userPrompt(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var e = base(.user); e.text = trimmed; out.append(e)
            }
        case .toolUse(let act):
            let name = config.toolAliases[act.tool] ?? act.tool
            if config.coalesceTools,
               coal.lastTool == name, coal.lastDetail == act.detail,
               coal.lastIsError == act.isError {
                coal.lastCount += 1
            } else {
                var e = base(.tool)
                e.tool = name
                e.detail = act.detail
                e.isError = act.isError
                out.append(e)
                coal.lastTool = name
                coal.lastDetail = act.detail
                coal.lastIsError = act.isError
                coal.lastCount = 1
            }
        case .question(let prompt, let options, _):
            var e = base(.decision)
            e.text = prompt
            // options stay on existing decision channel; text is enough for timeline crumb
            _ = options
            out.append(e)
        case .suggest(let options):
            var e = base(.decision)
            e.text = options.joined(separator: " · ")
            out.append(e)
        case .notification(_, let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { var e = base(.notice); e.text = t; out.append(e) }
        case .agentStopped:
            break
        case .screenObserved(_, let message, _, _, _, _, _, _):
            if config.screenFallback {
                let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { var e = base(.notice); e.text = t; out.append(e) }
            }
        default:
            break
        }

        if outcome.isCompletionSignal {
            let prose = outcome.info.lastAssistantMessage
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty {
                var e = base(.assistant); e.text = prose; out.append(e)
            }
        }

        return (out, coal)
    }
}
```

If coalesce-on-duplicate should emit an updated event with `count` instead of silence, change the test and implementation together so Gateway clients can bump the last tool row — pick **silence + state** for v1 as in the test above (simpler hub).

- [ ] **Step 4: Run tests — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/PaneMessageProjector.swift Tests/PaneMessageProjectorTests.swift
git commit -m "$(cat <<'EOF'
feat: project ingest outcomes into typed message events

EOF
)"
```

---

### Task 3: `MessageStreamHub` + Registry wiring

**Files:**
- Create: `Sources/Core/MessageStreamHub.swift`
- Modify: `Sources/Core/AgentRegistry.swift` (unregister + `notifyObservers`)
- Test: `Tests/MessageStreamHubTests.swift`

**Interfaces:**
- Produces:
  - `MessageStreamHub.shared`
  - `func append(_ events: [MessageEvent])` — stamps increasing `seq`, stores per `paneId`
  - `func snapshot(paneId: String?) -> [MessageEvent]`
  - `func eventsAfter(_ seq: UInt64) -> [MessageEvent]`
  - `func clear(paneId: String)`
  - `func subscribe(_ handler: @escaping (MessageEvent) -> Void) -> Int` / `unsubscribe`
  - `func config(forAgentType: AgentType) -> MessageConfig` helper can live on hub or a tiny `MessageConfigStore` that reads `ManifestStore.shared.manifest(for:)`’s `.message ?? .default`
- Consumes: projector; `AgentRegistry.notifyObservers`

- [ ] **Step 1: Write hub tests**

```swift
import XCTest
@testable import seahelm

final class MessageStreamHubTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MessageStreamHub.shared.resetForTesting()
    }

    func testAppendSnapshotAndClear() {
        let hub = MessageStreamHub.shared
        hub.append([
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "k",
                         kind: .user, ts: Date(), text: "hi")
        ])
        XCTAssertEqual(hub.snapshot(paneId: "a").count, 1)
        XCTAssertEqual(hub.snapshot(paneId: "a").first?.seq, 1)
        hub.clear(paneId: "a")
        XCTAssertTrue(hub.snapshot(paneId: "a").isEmpty)
    }

    func testSubscribeReceivesAppend() {
        let hub = MessageStreamHub.shared
        var got: [MessageEvent] = []
        let token = hub.subscribe { got.append($0) }
        hub.append([
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "",
                         kind: .notice, ts: Date(), text: "n")
        ])
        hub.unsubscribe(token)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.text, "n")
    }

    func testEventsAfterReplay() {
        let hub = MessageStreamHub.shared
        hub.append([
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "", kind: .user, ts: Date(), text: "1"),
            MessageEvent(seq: 0, paneId: "a", paneSessionKey: "", kind: .user, ts: Date(), text: "2"),
        ])
        let after = hub.eventsAfter(1)
        XCTAssertEqual(after.map(\.text), ["2"])
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement hub**

Mirror `EventHub` locking/ring style. Cap per pane at **80** events; global subscribe fan-out like EventHub. `#if DEBUG resetForTesting()`.

Keep `coalesce` state in the hub keyed by `paneId` (or inside Registry). On each outcome in `notifyObservers`, after existing delegate/`EventHub` publish:

```swift
let agentId = outcome.info.agentType.rawValue // or manifest id
let config = ManifestStore.shared.manifest(for: agentId)?.manifest.message ?? .default
let coal = coalesceByPane[outcome.info.id] ?? .empty
let (events, next) = PaneMessageProjector.project(
    outcome: outcome, config: config, coalesce: coal)
coalesceByPane[outcome.info.id] = next
MessageStreamHub.shared.append(events)
```

On `unregister(terminalID:)`: `MessageStreamHub.shared.clear(paneId:)` and drop coalesce entry.

Resolve exact `AgentType.rawValue` ↔ manifest id the same way status code already does (`ManifestStore.shared.manifest(for:)`).

- [ ] **Step 4: Integration smoke (optional small test)**

Ingest a `userPrompt` via `AgentRegistry.shared.ingest` on main (follow `AgentRegistryIngestOutcomeTests` setUp), then assert hub snapshot non-empty. Drain main queue like existing tests.

- [ ] **Step 5: Run hub tests — PASS; commit**

```bash
git add Sources/Core/MessageStreamHub.swift Sources/Core/AgentRegistry.swift \
  Tests/MessageStreamHubTests.swift
git commit -m "$(cat <<'EOF'
feat: MessageStreamHub fed from AgentRegistry ingest

EOF
)"
```

---

### Task 4: Control protocol `message.snapshot`

**Files:**
- Modify: `Sources/Core/ControlProtocol.swift`
- Modify: `Sources/Core/SeahelmControlDataSource.swift` (and any fake `ControlDataSource` in tests)
- Modify: `Sources/Core/SeahelmCliInstaller.swift` — optional `seahelm messages` / document later
- Test: `Tests/ControlMessageSnapshotTests.swift`

**Interfaces:**
- Extends `ControlDataSource` with  
  `func messageSnapshot(paneId: String?) -> [[String: Any]]`  
  default empty for fakes.
- Router case `"message.snapshot"` → `{ "messages": [ ... dicts ] }`

- [ ] **Step 1: Failing router test** with a tiny fake data source returning one message dict; assert `ControlRouter().handle(method: "message.snapshot", params: [:])` ok.

- [ ] **Step 2: Implement protocol + SeahelmControlDataSource** reading `MessageStreamHub.shared.snapshot`.

- [ ] **Step 3: PASS + commit**

```bash
git commit -m "$(cat <<'EOF'
feat: expose message.snapshot on the control socket

EOF
)"
```

---

### Task 5: Host Gateway push `pane.message`

**Files:**
- Modify: `Sources/Core/HostGatewayServer.swift`
- Modify: `Sources/Core/HostGatewaySession.swift`

**Interfaces:**
- `HostGatewaySession.pushMessage(_ event: MessageEvent)` → notify  
  `{"type":"notify","method":"pane.message","params": <event.dict>}`
- On auth success (alongside decision replay): send `message.snapshot` contents as a burst of notifies **or** include `messages` in the auth/session reply — prefer **replay notifies** after auth to match decision replay style.
- Server: second subscription beside EventHub decisions:

```swift
messageToken = MessageStreamHub.shared.subscribe { [weak self] event in
    self?.queue.async {
        for state in self?.connections.values ?? [:] {
            state.session.pushMessage(event)
        }
    }
}
```

Only fan out to **authenticated** sessions (same gate as business traffic).

Handle inbound `"message.snapshot"` in session switch by calling router / hub.

- [ ] **Step 1:** Add a focused unit test if there is an existing Gateway session test harness; otherwise a pure test that `MessageEvent.dict` is what `pushMessage` encodes, and manually verify with Gateway + browser in Task 6.

- [ ] **Step 2: Implement push + auth replay + unsubscribe in `stop()`**

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
feat: push pane.message frames on Host Gateway

EOF
)"
```

---

### Task 6: seahelm-web text-mode pane view

**Files:**
- Modify: `clients/seahelm-web/index.html`
- Modify: `clients/seahelm-web/README.md`

**Interfaces (client):**
- On auth / snapshot: also `message.snapshot` (or consume replayed `pane.message`).
- Store `S.messages[pane_session_key] = []` capped at 100.
- When `layoutFitsMirror` is false (≤760px) **or** new `localStorage seahelm_surface_mode` defaulting to `text` on narrow: opening a pane renders `#messageTimeline` instead of calling `pane.vt_open`.
- Toolbar button **终端** calls existing VT open path; **时间线** returns to text mode and `pane.vt_close` if open.
- Render kinds: `user` / `assistant` / `tool` / `status` / `decision` / `notice` (CSS can follow the prototype in `.playwright-mcp/agent-registry-text-mode.html` but live off wire events — no `last_message` heuristics).
- Composer already exists for keys; ensure send uses `pane.send_text` / `pane.send_keys` without requiring VT attach.

- [ ] **Step 1: Implement client handlers**

```javascript
function onPaneMessage(params) {
  const key = params.pane_session_key || params.pane_id;
  if (!key) return;
  const list = (S.messages[key] = S.messages[key] || []);
  list.push(params);
  while (list.length > 100) list.shift();
  if (S.focusKey === key && S.surfaceMode === 'text') renderMessageTimeline(key);
}

function renderMessageTimeline(key) {
  const host = $('messageTimeline'); // add to DOM
  const rows = S.messages[key] || [];
  host.innerHTML = rows.map(renderMessageRow).join('');
  host.scrollTop = host.scrollHeight;
}

function renderMessageRow(m) {
  switch (m.kind) {
    case 'tool':
      return `<div class="row-tool"><span class="k">${esc(m.tool||'')}</span> ${esc(m.detail||'')}</div>`;
    case 'user':
      return `<div class="row-user">${esc(m.text||'')}</div>`;
    case 'assistant':
      return `<div class="row-asst">${esc(m.text||'')}</div>`;
    case 'status':
      return `<div class="row-status">${esc((m.old_status? m.old_status+' → ':'')+(m.status||''))}</div>`;
    case 'decision':
    case 'notice':
      return `<div class="row-meta">${esc(m.text||'')}</div>`;
    default:
      return '';
  }
}
```

Wire `notify` method `pane.message` next to existing `pane.event` handling. On pane select in text mode: **do not** call `pane.vt_open`.

- [ ] **Step 2: Manual check**

1. Enable Host Gateway; open `http://127.0.0.1:2783/` (or Tailscale IP).
2. Pair; shrink window ≤760px.
3. Select a running Cursor/Claude pane with hooks — timeline should show tools without VT.
4. Click **终端** — VT still works.
5. Send a short order from composer — agent receives text.

- [ ] **Step 3: README** — one section “Text mode (phone default)” describing MessageStream vs VT toggle.

- [ ] **Step 4: Commit**

```bash
git add clients/seahelm-web/index.html clients/seahelm-web/README.md
git commit -m "$(cat <<'EOF'
feat: seahelm-web text mode timeline from pane.message

EOF
)"
```

---

### Task 7: Bundled defaults (optional polish)

**Files:**
- Modify: `Resources/Manifests/cursor.json` (and `claude.json` / `codex.json` only if needed)
- Test: extend `MessageConfigManifestTests` to decode bundled file from disk or assert `ManifestStore` returns non-nil message for cursor after load

Add a minimal `message` block for cursor aliases if live tool names need them; otherwise skip JSON changes and rely on `MessageConfig.default`.

- [ ] **Step 1:** Only add JSON when a real hook tool name requires an alias (verify with one live `ActivityEvent` dump). YAGNI otherwise.

- [ ] **Step 2: Commit only if files change**

---

## Spec coverage checklist

| Spec section | Task |
|---|---|
| Architecture / no write-back | Task 3 |
| Event kinds | Task 1–2 |
| Coalescing | Task 2 |
| `message` JSON on manifests | Task 1, 7 |
| `message.snapshot` / subscribe | Task 4–5 |
| Gateway `pane.message` | Task 5 |
| seahelm-web text default + VT on demand | Task 6 |
| Non-goals (no disk history, no First Mate routing) | respected |

## Placeholder / consistency self-review

- Types use `MessageEvent` / `MessageKind` / `MessageConfig` / `PaneMessageProjector` / `MessageStreamHub` consistently.
- Hub stamps `seq`; projector leaves `seq: 0`.
- No TBD steps; commands use `seahelmTests` scheme and `-skipPackagePluginValidation`.

---
