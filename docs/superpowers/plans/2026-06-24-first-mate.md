# First Mate + 舰桥 + worktree Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `AgentHead` 之上加一层薄规则引擎 First Mate(大副),把 agent 状态边沿翻译成绿区(自动)/红区(待批)动作,左栏舰桥呈现待批航令与值更,主区改为每 worktree 一个 tab。

**Architecture:** First Mate 的核心是一个**纯函数引擎** `FirstMate.evaluate(transition,config) -> [FirstMateAction]`,不依赖 AppKit、可单测。`AgentHead` 在状态变化的边沿(`updateStatus` 里 `previousStatus != status`,以及 webhook `.agentStop` 完工信号)调用一个观察者闭包,由 `FirstMateCoordinator` 接住:绿区动作立即执行(通知 / 验船 / 拉 review 水手),红区动作进 `PendingOrdersQueue` 等舰长在舰桥确认。UI 复用现有左栏面板(加 tab)与 `TabCoordinator`(粒度细化到 worktree)。

**Tech Stack:** Swift 5.10, AppKit, XCTest, `ProcessRunner`, `NotificationManager`, 现有 Ghostty/状态管线。

## Global Constraints

- macOS 14.0+,Swift 5.10,AppKit(非 SwiftUI),delegate 模式(非 Combine)。
- 构建/测试命令带 `-skipPackagePluginValidation -skipMacroValidation`。
- 工程名假设已是 `seamux`(本计划在 Seamux 改名计划之后执行);测试 `@testable import seamux`。若改名尚未做,把 `seamux` 读作当前模块名。
- `Config` 一律用 `decodeIfPresent` 向后兼容。
- First Mate **不做判断型决策**:只按确定性规则产出动作;不可逆动作(返港删除)永远经舰长确认。
- 引擎核心 `FirstMate.evaluate` 必须是纯函数(无单例、无 IO、无 AppKit),IO/副作用全部在 `FirstMateCoordinator`。
- `AgentStatus` 取值固定为:`running / idle / waiting / error / exited / unknown`(不新增枚举值)。

---

### Task 1: FirstMateConfig + 接入 Config(TDD)

**Files:**
- Create: `Sources/Core/FirstMateConfig.swift`
- Modify: `Sources/Core/Config.swift`(新增 `firstMate` 属性 + `CodingKeys` + `decodeIfPresent`)
- Test: `Tests/FirstMateConfigTests.swift`

**Interfaces:**
- Produces: `struct FirstMateConfig: Codable, Equatable`,字段:`enabled: Bool`、`waitingTimeoutSec: Double`、`autoInspect: Bool`、`inspectionCommands: [String]`、`autoReview: Bool`、`autoCommit: Bool`、`autoSuggestNextOrder: Bool`、`channels: [String]`;静态默认 `FirstMateConfig.default`。`Config.firstMate: FirstMateConfig`。

- [ ] **Step 1: 写失败测试**

`Tests/FirstMateConfigTests.swift`:

```swift
import XCTest
@testable import seamux

final class FirstMateConfigTests: XCTestCase {
    func testDefaults() {
        let c = FirstMateConfig.default
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.waitingTimeoutSec, 30)
        XCTAssertTrue(c.autoInspect)
        XCTAssertTrue(c.autoReview)
        XCTAssertFalse(c.autoCommit)
        XCTAssertTrue(c.autoSuggestNextOrder)
    }

    func testConfigDecodesMissingFirstMateAsDefault() throws {
        let json = "{}".data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(cfg.firstMate, FirstMateConfig.default)
    }

    func testConfigDecodesProvidedFirstMate() throws {
        let json = """
        {"firstMate":{"enabled":false,"waitingTimeoutSec":10,"autoInspect":false,
        "inspectionCommands":["make test"],"autoReview":false,"autoCommit":true,
        "autoSuggestNextOrder":false,"channels":["local"]}}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertFalse(cfg.firstMate.enabled)
        XCTAssertEqual(cfg.firstMate.waitingTimeoutSec, 10)
        XCTAssertEqual(cfg.firstMate.inspectionCommands, ["make test"])
        XCTAssertTrue(cfg.firstMate.autoCommit)
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/FirstMateConfigTests
```
Expected: 编译失败("cannot find 'FirstMateConfig'")。

- [ ] **Step 3: 实现 FirstMateConfig**

`Sources/Core/FirstMateConfig.swift`:

```swift
import Foundation

struct FirstMateConfig: Codable, Equatable {
    var enabled: Bool
    var waitingTimeoutSec: Double
    var autoInspect: Bool
    var inspectionCommands: [String]
    var autoReview: Bool
    var autoCommit: Bool
    var autoSuggestNextOrder: Bool
    var channels: [String]

    static let `default` = FirstMateConfig(
        enabled: true,
        waitingTimeoutSec: 30,
        autoInspect: true,
        inspectionCommands: [],
        autoReview: true,
        autoCommit: false,
        autoSuggestNextOrder: true,
        channels: ["local"]
    )

    init(enabled: Bool, waitingTimeoutSec: Double, autoInspect: Bool,
         inspectionCommands: [String], autoReview: Bool, autoCommit: Bool,
         autoSuggestNextOrder: Bool, channels: [String]) {
        self.enabled = enabled
        self.waitingTimeoutSec = waitingTimeoutSec
        self.autoInspect = autoInspect
        self.inspectionCommands = inspectionCommands
        self.autoReview = autoReview
        self.autoCommit = autoCommit
        self.autoSuggestNextOrder = autoSuggestNextOrder
        self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FirstMateConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        waitingTimeoutSec = try c.decodeIfPresent(Double.self, forKey: .waitingTimeoutSec) ?? d.waitingTimeoutSec
        autoInspect = try c.decodeIfPresent(Bool.self, forKey: .autoInspect) ?? d.autoInspect
        inspectionCommands = try c.decodeIfPresent([String].self, forKey: .inspectionCommands) ?? d.inspectionCommands
        autoReview = try c.decodeIfPresent(Bool.self, forKey: .autoReview) ?? d.autoReview
        autoCommit = try c.decodeIfPresent(Bool.self, forKey: .autoCommit) ?? d.autoCommit
        autoSuggestNextOrder = try c.decodeIfPresent(Bool.self, forKey: .autoSuggestNextOrder) ?? d.autoSuggestNextOrder
        channels = try c.decodeIfPresent([String].self, forKey: .channels) ?? d.channels
    }
}
```

- [ ] **Step 4: 接入 Config**

在 `Sources/Core/Config.swift` 的属性区加:
```swift
var firstMate: FirstMateConfig = .default
```
在 `CodingKeys` 枚举加 `case firstMate`;在 `init(from:)` 体内(与其他 decodeIfPresent 并列)加:
```swift
firstMate = try container.decodeIfPresent(FirstMateConfig.self, forKey: .firstMate) ?? .default
```

- [ ] **Step 5: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/FirstMateConfigTests
```
Expected: 3 测试 PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/FirstMateConfig.swift Sources/Core/Config.swift Tests/FirstMateConfigTests.swift
git commit -m "feat: add FirstMateConfig with Config integration"
```

---

### Task 2: First Mate 引擎核心 evaluate(TDD)

**Files:**
- Create: `Sources/Core/FirstMate.swift`(纯类型 + 纯函数引擎)
- Test: `Tests/FirstMateTests.swift`

**Interfaces:**
- Consumes: `FirstMateConfig`(Task 1)、`AgentStatus`。
- Produces:
  - `enum FirstMateZone { case green, red }`
  - `enum FirstMateActionKind: Equatable { case watchWaiting, watchError, inspect, autoCommit, suggestNextOrder }`(`returnToPort` 见 Task 6,走独立入口)
  - `struct FirstMateAction: Equatable`,字段:`kind: FirstMateActionKind`、`zone: FirstMateZone`、`worktreePath: String`、`branch: String`、`project: String`、`terminalID: String`、`message: String`
  - `struct StatusTransition`,字段:`worktreePath: String`、`branch: String`、`project: String`、`terminalID: String`、`oldStatus: AgentStatus`、`newStatus: AgentStatus`、`holdSeconds: Double`、`isCompletionSignal: Bool`
  - `enum FirstMate { static func evaluate(_ t: StatusTransition, config: FirstMateConfig) -> [FirstMateAction] }`

- [ ] **Step 1: 写失败测试**

`Tests/FirstMateTests.swift`:

```swift
import XCTest
@testable import seamux

final class FirstMateTests: XCTestCase {
    private func tx(_ old: AgentStatus, _ new: AgentStatus,
                    hold: Double = 0, completion: Bool = false) -> StatusTransition {
        StatusTransition(worktreePath: "/wt/x", branch: "feat-x", project: "repo",
                         terminalID: "t1", oldStatus: old, newStatus: new,
                         holdSeconds: hold, isCompletionSignal: completion)
    }

    func testWaitingBeyondTimeoutEmitsGreenWatch() {
        let acts = FirstMate.evaluate(tx(.running, .waiting, hold: 31), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchWaiting])
        XCTAssertEqual(acts.first?.zone, .green)
    }

    func testWaitingUnderTimeoutEmitsNothing() {
        let acts = FirstMate.evaluate(tx(.running, .waiting, hold: 5), config: .default)
        XCTAssertTrue(acts.isEmpty)
    }

    func testErrorEmitsGreenWatchError() {
        let acts = FirstMate.evaluate(tx(.running, .error), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchError])
        XCTAssertEqual(acts.first?.zone, .green)
    }

    func testExitedTreatedAsError() {
        let acts = FirstMate.evaluate(tx(.running, .exited), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.watchError])
    }

    func testCompletionEmitsInspectGreen() {
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: .default)
        XCTAssertTrue(acts.contains { $0.kind == .inspect && $0.zone == .green })
    }

    func testCompletionWithAutoCommitOnEmitsCommit() {
        var cfg = FirstMateConfig.default; cfg.autoCommit = true
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: cfg)
        XCTAssertTrue(acts.contains { $0.kind == .autoCommit })
    }

    func testCompletionWithAutoCommitOffOmitsCommit() {
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: .default)
        XCTAssertFalse(acts.contains { $0.kind == .autoCommit })
    }

    func testIdleWithoutCompletionEmitsSuggestNextOrderRed() {
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: false), config: .default)
        XCTAssertEqual(acts.map(\.kind), [.suggestNextOrder])
        XCTAssertEqual(acts.first?.zone, .red)
    }

    func testDisabledEmitsNothing() {
        var cfg = FirstMateConfig.default; cfg.enabled = false
        XCTAssertTrue(FirstMate.evaluate(tx(.running, .error), config: cfg).isEmpty)
    }

    func testAutoInspectOffOmitsInspect() {
        var cfg = FirstMateConfig.default; cfg.autoInspect = false
        let acts = FirstMate.evaluate(tx(.running, .idle, completion: true), config: cfg)
        XCTAssertFalse(acts.contains { $0.kind == .inspect })
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/FirstMateTests
```
Expected: 编译失败("cannot find 'FirstMate'")。

- [ ] **Step 3: 实现引擎**

`Sources/Core/FirstMate.swift`:

```swift
import Foundation

enum FirstMateZone { case green, red }

enum FirstMateActionKind: Equatable {
    case watchWaiting       // A 等待
    case watchError         // C 异常
    case inspect            // B 验船(含拉 review 水手)
    case autoCommit         // B'
    case suggestNextOrder   // D 派令
}

struct FirstMateAction: Equatable {
    let kind: FirstMateActionKind
    let zone: FirstMateZone
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let message: String
}

struct StatusTransition {
    let worktreePath: String
    let branch: String
    let project: String
    let terminalID: String
    let oldStatus: AgentStatus
    let newStatus: AgentStatus
    let holdSeconds: Double
    let isCompletionSignal: Bool
}

/// 纯函数规则引擎:状态边沿 + 配置 → 动作列表。无 IO、无单例。
enum FirstMate {
    static func evaluate(_ t: StatusTransition, config: FirstMateConfig) -> [FirstMateAction] {
        guard config.enabled else { return [] }

        func make(_ kind: FirstMateActionKind, _ zone: FirstMateZone, _ msg: String) -> FirstMateAction {
            FirstMateAction(kind: kind, zone: zone, worktreePath: t.worktreePath,
                            branch: t.branch, project: t.project,
                            terminalID: t.terminalID, message: msg)
        }

        var actions: [FirstMateAction] = []

        // A 等待:进入 waiting 且持续超时
        if t.newStatus == .waiting && t.holdSeconds >= config.waitingTimeoutSec {
            actions.append(make(.watchWaiting, .green, "\(t.branch) 等你回话"))
        }

        // C 异常:error / 非正常退出
        if t.newStatus == .error || t.newStatus == .exited {
            actions.append(make(.watchError, .green, "\(t.branch) 异常(\(t.newStatus.rawValue))"))
        }

        // B 验船 + B' commit:收到完工信号
        if t.isCompletionSignal {
            if config.autoInspect {
                actions.append(make(.inspect, .green, "\(t.branch) 完工,验船中"))
            }
            if config.autoCommit {
                actions.append(make(.autoCommit, .green, "\(t.branch) 自动提交"))
            }
        } else if t.newStatus == .idle && config.autoSuggestNextOrder {
            // D 待命:空闲(非完工边沿)→ 红区派令(由 Coordinator 校验是否真有航令)
            actions.append(make(.suggestNextOrder, .red, "\(t.branch) 已待命,派发下一条?"))
        }

        return actions
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/FirstMateTests
```
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/FirstMate.swift Tests/FirstMateTests.swift
git commit -m "feat: add First Mate pure rule engine (5 watch rules, green/red zones)"
```

---

### Task 3: PendingOrdersQueue(红区待批队列,TDD)

**Files:**
- Create: `Sources/Core/PendingOrdersQueue.swift`
- Test: `Tests/PendingOrdersQueueTests.swift`

**Interfaces:**
- Consumes: `FirstMateAction`(Task 2)。
- Produces:
  - `struct PendingOrder: Equatable, Identifiable { let id: String; let action: FirstMateAction }`(`id == "\(action.worktreePath)#\(action.kind)"`,用于去重)
  - `final class PendingOrdersQueue`:`func enqueue(_ action: FirstMateAction)`、`func all() -> [PendingOrder]`、`func resolve(id: String)`(批准/否决后移除)、`var onChange: (() -> Void)?`。同一 `(worktreePath, kind)` 至多一条。

- [ ] **Step 1: 写失败测试**

`Tests/PendingOrdersQueueTests.swift`:

```swift
import XCTest
@testable import seamux

final class PendingOrdersQueueTests: XCTestCase {
    private func action(_ kind: FirstMateActionKind, wt: String = "/wt/x") -> FirstMateAction {
        FirstMateAction(kind: kind, zone: .red, worktreePath: wt, branch: "b",
                        project: "p", terminalID: "t", message: "m")
    }

    func testEnqueueAddsOrder() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testDuplicateSameWorktreeAndKindKeepsOne() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testDifferentWorktreesCoexist() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder, wt: "/wt/a"))
        q.enqueue(action(.suggestNextOrder, wt: "/wt/b"))
        XCTAssertEqual(q.all().count, 2)
    }

    func testResolveRemovesAndAllowsReenqueue() {
        let q = PendingOrdersQueue()
        q.enqueue(action(.suggestNextOrder))
        let id = q.all()[0].id
        q.resolve(id: id)
        XCTAssertTrue(q.all().isEmpty)
        q.enqueue(action(.suggestNextOrder))
        XCTAssertEqual(q.all().count, 1)
    }

    func testOnChangeFiresOnEnqueueAndResolve() {
        let q = PendingOrdersQueue()
        var count = 0
        q.onChange = { count += 1 }
        q.enqueue(action(.suggestNextOrder))
        let id = q.all()[0].id
        q.resolve(id: id)
        XCTAssertEqual(count, 2)
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/PendingOrdersQueueTests
```
Expected: 编译失败("cannot find 'PendingOrdersQueue'")。

- [ ] **Step 3: 实现**

`Sources/Core/PendingOrdersQueue.swift`:

```swift
import Foundation

struct PendingOrder: Equatable, Identifiable {
    let id: String
    let action: FirstMateAction
}

/// 红区待批航令队列。同一 (worktreePath, kind) 至多一条(幂等)。
/// 必须在主线程使用。
final class PendingOrdersQueue {
    private(set) var orders: [PendingOrder] = []
    var onChange: (() -> Void)?

    static func key(_ a: FirstMateAction) -> String {
        "\(a.worktreePath)#\(a.kind)"
    }

    func enqueue(_ action: FirstMateAction) {
        let id = Self.key(action)
        guard !orders.contains(where: { $0.id == id }) else { return }
        orders.append(PendingOrder(id: id, action: action))
        onChange?()
    }

    func all() -> [PendingOrder] { orders }

    func resolve(id: String) {
        let before = orders.count
        orders.removeAll { $0.id == id }
        if orders.count != before { onChange?() }
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/PendingOrdersQueueTests
```
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/PendingOrdersQueue.swift Tests/PendingOrdersQueueTests.swift
git commit -m "feat: add PendingOrdersQueue with idempotent enqueue"
```

---

### Task 4: AgentHead 状态边沿观察者钩子(TDD)

把 First Mate 接到状态管线:在 `AgentHead` 加一个观察者闭包,在状态变化边沿与完工信号处触发,并携带在该状态停留的时长(供 A 的超时判定)。

**Files:**
- Modify: `Sources/Core/AgentHead.swift`
- Test: `Tests/AgentHeadTransitionTests.swift`

**Interfaces:**
- Consumes: `StatusTransition`(Task 2)、现有 `updateStatus` / `handleWebhookEvent`。
- Produces: `AgentHead.onStatusTransition: ((StatusTransition) -> Void)?`(主线程回调)。在 `updateStatus` 内 `previousStatus != status` 时构造并触发(`isCompletionSignal=false`,`holdSeconds` 由内部记录的"进入该状态时间"算出);在 `handleWebhookEvent` 的 `.agentStop` 分支触发一次 `isCompletionSignal=true` 的 transition(`newStatus` 取当前 info.status)。

- [ ] **Step 1: 写失败测试**

`Tests/AgentHeadTransitionTests.swift`(用真实 `AgentHead.shared`,注册一个 surface 后驱动状态变化;若无法构造 `TerminalSurface`,测试改为验证闭包在状态变化时被调用的最小路径):

```swift
import XCTest
@testable import seamux

final class AgentHeadTransitionTests: XCTestCase {
    func testStatusChangeFiresTransitionObserver() {
        let head = AgentHead.shared
        let exp = expectation(description: "transition fired")
        var captured: StatusTransition?
        head.onStatusTransition = { t in
            if captured == nil { captured = t; exp.fulfill() }
        }
        // 注:registerForTesting 见 Step 3,绕开真实 TerminalSurface
        head.registerForTesting(terminalID: "tt", worktreePath: "/wt/z",
                                branch: "feat-z", project: "repoz")
        head.updateStatus(terminalID: "tt", status: .waiting,
                          lastMessage: "?", roundDuration: 0)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(captured?.newStatus, .waiting)
        XCTAssertEqual(captured?.worktreePath, "/wt/z")
        XCTAssertFalse(captured?.isCompletionSignal ?? true)
        head.onStatusTransition = nil
        head.unregister(terminalID: "tt")
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/AgentHeadTransitionTests
```
Expected: 编译失败("no member 'onStatusTransition'" / "registerForTesting")。

- [ ] **Step 3: 实现**

在 `Sources/Core/AgentHead.swift`:

加属性(靠近 `delegate`):
```swift
/// First Mate 观察者:状态边沿与完工信号,主线程回调。
var onStatusTransition: ((StatusTransition) -> Void)?

/// 记录每个 terminal 进入当前状态的时刻(算 holdSeconds)
private var statusEnteredAt: [String: Date] = [:]
```

加测试辅助(无 TerminalSurface 的最小注册):
```swift
#if DEBUG
/// 测试用:注册一个无 surface 的 agent 条目。
func registerForTesting(terminalID: String, worktreePath: String, branch: String, project: String) {
    lock.lock(); defer { lock.unlock() }
    agents[terminalID] = AgentInfo(
        id: terminalID, worktreePath: worktreePath, agentType: .unknown,
        project: project, branch: branch, status: .unknown, lastMessage: "",
        commandLine: nil, roundDuration: 0, startedAt: nil, surface: nil,
        channel: nil, taskProgress: TaskProgress())
    worktreeIndex[worktreePath, default: []].append(terminalID)
    if !orderedIDs.contains(terminalID) { orderedIDs.append(terminalID) }
}
#endif
```

在 `updateStatus` 内,`lock.unlock()` 之后、`if changed {` 块里(状态确实变化时),追加边沿触发。把现有 `if changed {` 块改为:
```swift
if changed {
    DispatchQueue.main.async { [weak self] in
        self?.delegate?.agentDidUpdate(info)
    }
    if previousStatus != status {
        let now = Date()
        lock.lock()
        let entered = statusEnteredAt[terminalID] ?? now
        statusEnteredAt[terminalID] = now
        lock.unlock()
        let hold = now.timeIntervalSince(entered)
        let transition = StatusTransition(
            worktreePath: info.worktreePath, branch: info.branch,
            project: info.project, terminalID: terminalID,
            oldStatus: previousStatus, newStatus: status,
            holdSeconds: hold, isCompletionSignal: false)
        DispatchQueue.main.async { [weak self] in
            self?.onStatusTransition?(transition)
        }
    }
    // ...保留原有 external channel broadcast 代码...
}
```

> 说明:A 的"持续超时"在 Coordinator 侧用定时复查兜底(见 Task 5),因为单次边沿时 holdSeconds≈0。边沿触发负责"进入 waiting"这件事,超时判定在 Coordinator 用 `waitingTimeoutSec` 延时复查当前是否仍 waiting。

在 `handleWebhookEvent` 的 `case .agentStop:` 分支末尾追加完工 transition:
```swift
case .agentStop:
    clearActivityEvents(forTerminalID: tid)
    if let info = agent(for: tid) {
        let t = StatusTransition(
            worktreePath: info.worktreePath, branch: info.branch,
            project: info.project, terminalID: tid,
            oldStatus: info.status, newStatus: info.status,
            holdSeconds: 0, isCompletionSignal: true)
        DispatchQueue.main.async { [weak self] in self?.onStatusTransition?(t) }
    }
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/AgentHeadTransitionTests
```
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AgentHead.swift Tests/AgentHeadTransitionTests.swift
git commit -m "feat: add status-transition observer hook to AgentHead"
```

---

### Task 5: FirstMateCoordinator(连接引擎与副作用)

接住 `onStatusTransition`,跑引擎,绿区立即执行、红区入队;并处理 A 的超时复查与 D 的"是否真有航令"校验。

**Files:**
- Create: `Sources/Core/FirstMateCoordinator.swift`
- Modify: `Sources/App/TabCoordinator.swift`(创建并持有 `FirstMateCoordinator`,接 `AgentHead.shared.onStatusTransition`)
- Test: `Tests/FirstMateCoordinatorTests.swift`

**Interfaces:**
- Consumes: `FirstMate.evaluate`、`PendingOrdersQueue`、`FirstMateConfig`、`NotificationManager`、`ProcessRunner`、`TodoStore`/`WorktreeTaskStore`(查航令)。
- Produces:
  - `final class FirstMateCoordinator`:`init(config: FirstMateConfig, queue: PendingOrdersQueue, notify: @escaping (FirstMateAction) -> Void, runInspection: @escaping (FirstMateAction) -> Void, hasOrders: @escaping (String) -> Bool)`(依赖注入便于测试),`func handle(_ t: StatusTransition)`。
  - 绿区:`watchWaiting`/`watchError` → `notify`;`inspect` → `runInspection`;`autoCommit` → `runInspection`(同一执行通道,命令不同)。
  - 红区:`suggestNextOrder` → 仅当 `hasOrders(worktreePath)` 为真才 `queue.enqueue`。

- [ ] **Step 1: 写失败测试**

`Tests/FirstMateCoordinatorTests.swift`:

```swift
import XCTest
@testable import seamux

final class FirstMateCoordinatorTests: XCTestCase {
    private func tx(_ new: AgentStatus, hold: Double = 0, completion: Bool = false) -> StatusTransition {
        StatusTransition(worktreePath: "/wt/x", branch: "b", project: "p", terminalID: "t",
                         oldStatus: .running, newStatus: new, holdSeconds: hold,
                         isCompletionSignal: completion)
    }

    func testGreenWatchErrorCallsNotify() {
        var notified: [FirstMateActionKind] = []
        let q = PendingOrdersQueue()
        let c = FirstMateCoordinator(config: .default, queue: q,
            notify: { notified.append($0.kind) }, runInspection: { _ in },
            hasOrders: { _ in true })
        c.handle(tx(.error))
        XCTAssertEqual(notified, [.watchError])
        XCTAssertTrue(q.all().isEmpty)
    }

    func testCompletionRunsInspection() {
        var inspected = 0
        let c = FirstMateCoordinator(config: .default, queue: PendingOrdersQueue(),
            notify: { _ in }, runInspection: { if $0.kind == .inspect { inspected += 1 } },
            hasOrders: { _ in false })
        c.handle(tx(.idle, completion: true))
        XCTAssertEqual(inspected, 1)
    }

    func testSuggestNextOrderEnqueuedOnlyWhenOrdersExist() {
        let q1 = PendingOrdersQueue()
        let c1 = FirstMateCoordinator(config: .default, queue: q1,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in false })
        c1.handle(tx(.idle, completion: false))
        XCTAssertTrue(q1.all().isEmpty, "no orders → no enqueue")

        let q2 = PendingOrdersQueue()
        let c2 = FirstMateCoordinator(config: .default, queue: q2,
            notify: { _ in }, runInspection: { _ in }, hasOrders: { _ in true })
        c2.handle(tx(.idle, completion: false))
        XCTAssertEqual(q2.all().map(\.action.kind), [.suggestNextOrder])
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/FirstMateCoordinatorTests
```
Expected: 编译失败("cannot find 'FirstMateCoordinator'")。

- [ ] **Step 3: 实现 Coordinator**

`Sources/Core/FirstMateCoordinator.swift`:

```swift
import Foundation

/// 接住状态边沿,跑 First Mate 引擎,分发绿/红区动作。主线程使用。
final class FirstMateCoordinator {
    private let config: FirstMateConfig
    private let queue: PendingOrdersQueue
    private let notify: (FirstMateAction) -> Void
    private let runInspection: (FirstMateAction) -> Void
    private let hasOrders: (String) -> Bool

    init(config: FirstMateConfig,
         queue: PendingOrdersQueue,
         notify: @escaping (FirstMateAction) -> Void,
         runInspection: @escaping (FirstMateAction) -> Void,
         hasOrders: @escaping (String) -> Bool) {
        self.config = config
        self.queue = queue
        self.notify = notify
        self.runInspection = runInspection
        self.hasOrders = hasOrders
    }

    func handle(_ t: StatusTransition) {
        for action in FirstMate.evaluate(t, config: config) {
            switch action.zone {
            case .green:
                switch action.kind {
                case .watchWaiting, .watchError:
                    notify(action)
                case .inspect, .autoCommit:
                    runInspection(action)
                case .suggestNextOrder:
                    break // 不会是绿区
                }
            case .red:
                switch action.kind {
                case .suggestNextOrder:
                    if hasOrders(action.worktreePath) { queue.enqueue(action) }
                default:
                    queue.enqueue(action)
                }
            }
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/FirstMateCoordinatorTests
```
Expected: 全部 PASS。

- [ ] **Step 5: 接线到 TabCoordinator**

在 `Sources/App/TabCoordinator.swift` 加属性并在初始化路径(`loadWorkspaces` 或现有 setup 处,与 `statusAggregator` 一同)装配:

```swift
let pendingOrders = PendingOrdersQueue()
var firstMate: FirstMateCoordinator!

// 在 statusPublisher/aggregator 装配处:
firstMate = FirstMateCoordinator(
    config: config.firstMate,
    queue: pendingOrders,
    notify: { action in
        NotificationManager.shared.notify(
            terminalID: action.terminalID, worktreePath: action.worktreePath,
            workspaceName: action.project, branch: action.branch,
            status: .waiting, lastMessage: action.message, lastUserPrompt: "",
            paneIndex: 1, paneCount: 1)
    },
    runInspection: { [weak self] action in
        self?.runFirstMateInspection(action)   // 见下
    },
    hasOrders: { worktreePath in
        !WorktreeTaskStore.shared.tasks(forWorktree: worktreePath).isEmpty
    })
AgentHead.shared.onStatusTransition = { [weak firstMate] t in
    firstMate?.handle(t)
}
```

> 注:`NotificationManager.shared.notify(...)` 与 `WorktreeTaskStore.shared.tasks(forWorktree:)` 的精确签名以源码为准;若签名不符,适配参数顺序即可(此 closure 只做转发)。`runFirstMateInspection` 用 `ProcessRunner` 在 `action.worktreePath` 下依次跑 `config.firstMate.inspectionCommands`,完成后若 `autoReview` 为真则按现有 `feat/new-task-auto-launch-agent` 的拉起机制起一个只读 review 水手;实现放在 TabCoordinator 的扩展里,跑在后台队列,结果回报走 `notify`。

- [ ] **Step 6: 构建通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 7: Commit**

```bash
git add Sources/Core/FirstMateCoordinator.swift Sources/App/TabCoordinator.swift Tests/FirstMateCoordinatorTests.swift
git commit -m "feat: wire First Mate engine to status pipeline via coordinator"
```

---

### Task 6: 返港(E)入口 + 预检(TDD)

返港不是状态边沿触发,而是"任务完成 / 分支已 merge"时由舰桥发起;它永远是红区两步确认,且入坞前做 git 预检。

**Files:**
- Create: `Sources/Core/ReturnToPort.swift`
- Test: `Tests/ReturnToPortTests.swift`

**Interfaces:**
- Produces:
  - `struct PortPrecheck: Equatable { let hasUnmergedCommits: Bool; let hasUnpushedCommits: Bool; let hasUncommittedChanges: Bool; var hasWarnings: Bool { hasUnmergedCommits || hasUnpushedCommits || hasUncommittedChanges }; var summary: String }`
  - `enum ReturnToPort { static func warningSummary(_ p: PortPrecheck) -> String }`(把预检结果转成给舰长看的中文摘要)
- 实际 git 检查走现有 `WorktreeDiscovery`/`ProcessRunner`(在 Coordinator 调用,不在纯函数里)。

- [ ] **Step 1: 写失败测试**

`Tests/ReturnToPortTests.swift`:

```swift
import XCTest
@testable import seamux

final class ReturnToPortTests: XCTestCase {
    func testNoWarnings() {
        let p = PortPrecheck(hasUnmergedCommits: false, hasUnpushedCommits: false, hasUncommittedChanges: false)
        XCTAssertFalse(p.hasWarnings)
        XCTAssertEqual(ReturnToPort.warningSummary(p), "无风险,可安全入坞")
    }

    func testUnpushedWarning() {
        let p = PortPrecheck(hasUnmergedCommits: false, hasUnpushedCommits: true, hasUncommittedChanges: false)
        XCTAssertTrue(p.hasWarnings)
        XCTAssertTrue(ReturnToPort.warningSummary(p).contains("未 push"))
    }

    func testMultipleWarnings() {
        let p = PortPrecheck(hasUnmergedCommits: true, hasUnpushedCommits: true, hasUncommittedChanges: true)
        let s = ReturnToPort.warningSummary(p)
        XCTAssertTrue(s.contains("未 merge"))
        XCTAssertTrue(s.contains("未 push"))
        XCTAssertTrue(s.contains("未提交"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/ReturnToPortTests
```
Expected: 编译失败。

- [ ] **Step 3: 实现**

`Sources/Core/ReturnToPort.swift`:

```swift
import Foundation

struct PortPrecheck: Equatable {
    let hasUnmergedCommits: Bool
    let hasUnpushedCommits: Bool
    let hasUncommittedChanges: Bool
    var hasWarnings: Bool { hasUnmergedCommits || hasUnpushedCommits || hasUncommittedChanges }
}

enum ReturnToPort {
    static func warningSummary(_ p: PortPrecheck) -> String {
        guard p.hasWarnings else { return "无风险,可安全入坞" }
        var parts: [String] = []
        if p.hasUnmergedCommits { parts.append("有未 merge 的提交") }
        if p.hasUnpushedCommits { parts.append("有未 push 的提交") }
        if p.hasUncommittedChanges { parts.append("有未提交的改动") }
        return "⚠ " + parts.joined(separator: ";")
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/ReturnToPortTests
```
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/ReturnToPort.swift Tests/ReturnToPortTests.swift
git commit -m "feat: add return-to-port precheck summary"
```

---

### Task 7: 左栏舰桥面板(First Mate tab)

把左栏面板做成 tab,默认 First Mate,呈现红区待批(确认/否决)+ 绿区值更,支持 vim 键位。AppKit UI 按仓库现有模式(无单元测试,验收靠构建 + 现有 UI 测试模式),逻辑性部分(分级确认流的状态机)抽成可测小函数。

**Files:**
- Create: `Sources/UI/SidePanel/BridgePanelViewController.swift`(First Mate tab 内容)
- Create: `Sources/UI/SidePanel/BridgeConfirmFlow.swift`(分级确认状态机,纯逻辑,可测)
- Modify: `Sources/UI/SidePanel/WorktreeSidePanelViewController.swift`(顶部 tab 切换 icon:First Mate/文件树/changes,默认 First Mate)
- Test: `Tests/BridgeConfirmFlowTests.swift`

**Interfaces:**
- Consumes: `PendingOrdersQueue`、`PendingOrder`、`FirstMateActionKind`。
- Produces:
  - `enum BridgeConfirmFlow { static func onEnter(kind: FirstMateActionKind, expanded: Bool) -> ConfirmDecision }`,`enum ConfirmDecision: Equatable { case expand, execute }`(派令一键 execute;返港首次 expand、再次 execute)。
  - `BridgePanelViewController`:`var queue: PendingOrdersQueue?`,`onNavigateToWorktree: ((String) -> Void)?`,`onApprove: ((PendingOrder) -> Void)?`,渲染 + 键位(j/k 移动、Enter 执行/展开、n 否决、x 清除值更、→ 看 diff)。

- [ ] **Step 1: 写失败测试(确认流状态机)**

`Tests/BridgeConfirmFlowTests.swift`:

```swift
import XCTest
@testable import seamux

final class BridgeConfirmFlowTests: XCTestCase {
    func testSuggestNextOrderExecutesImmediately() {
        XCTAssertEqual(BridgeConfirmFlow.onEnter(kind: .suggestNextOrder, expanded: false), .execute)
    }
    func testReturnToPortFirstEnterExpands() {
        XCTAssertEqual(BridgeConfirmFlow.onEnter(kind: .returnToPort, expanded: false), .expand)
    }
    func testReturnToPortSecondEnterExecutes() {
        XCTAssertEqual(BridgeConfirmFlow.onEnter(kind: .returnToPort, expanded: true), .execute)
    }
}
```

> 注:此处引用 `FirstMateActionKind.returnToPort`。在 Task 2 的枚举里**补上 `case returnToPort`**(当时标注"见 Task 6/UI"),并在 `FirstMate.evaluate` 中不产出它(返港由舰桥发起,不走 evaluate),所以引擎测试不受影响。补枚举后重跑 Task 2 测试确认仍 PASS。

- [ ] **Step 2: 补枚举并运行确认失败**

先在 `Sources/Core/FirstMate.swift` 的 `FirstMateActionKind` 末尾加 `case returnToPort`。然后:

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/BridgeConfirmFlowTests \
  -only-testing:seamuxTests/FirstMateTests
```
Expected: BridgeConfirmFlowTests 编译失败("cannot find 'BridgeConfirmFlow'");FirstMateTests 仍 PASS。

- [ ] **Step 3: 实现确认流状态机**

`Sources/UI/SidePanel/BridgeConfirmFlow.swift`:

```swift
import Foundation

enum ConfirmDecision: Equatable { case expand, execute }

/// 分级确认流:可重来的动作一键执行;不可逆的(返港删除)先展开看清,再执行。
enum BridgeConfirmFlow {
    static func onEnter(kind: FirstMateActionKind, expanded: Bool) -> ConfirmDecision {
        switch kind {
        case .returnToPort:
            return expanded ? .execute : .expand
        default:
            return .execute
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/BridgeConfirmFlowTests
```
Expected: 3 测试 PASS。

- [ ] **Step 5: 实现 BridgePanelViewController + tab 切换**

按现有 `WorktreeSidePanelViewController` 与 `FileTreeOutlineController` 的 AppKit 模式:
- `BridgePanelViewController`:一个 `NSStackView`/`NSTableView`,上半"待批航令 · N"(每行带[执行]/[否决]按钮 + 红色样式),下半"值更"(只读行,带[x]清除)。订阅 `queue.onChange` 刷新。
- 键位:覆写 `keyDown`,`j/k` 移动选中行;`Enter` 调 `BridgeConfirmFlow.onEnter(kind:expanded:)` 决定展开还是执行(执行时调 `onApprove?(order)`);`n` 否决(`queue.resolve(id:)`);`x` 清除值更;`→` 触发 `onNavigateToWorktree` 看 diff。
- 在 `WorktreeSidePanelViewController` 顶部(折叠按钮旁)加 3 个 icon 按钮切换 First Mate / 文件树 / changes,默认选 First Mate;切换时 `addChild`/`removeFromParent` 对应子 VC。

- [ ] **Step 6: 构建通过 + 跑全测**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation test
```
Expected: BUILD SUCCEEDED;TEST SUCCEEDED。

- [ ] **Step 7: Commit**

```bash
git add Sources/UI/SidePanel/BridgePanelViewController.swift Sources/UI/SidePanel/BridgeConfirmFlow.swift \
  Sources/UI/SidePanel/WorktreeSidePanelViewController.swift Sources/Core/FirstMate.swift Tests/BridgeConfirmFlowTests.swift
git commit -m "feat: left Bridge panel (First Mate tab) with graded confirm flow + vim keys"
```

---

### Task 8: 主内容区每 worktree 一个 tab + 舰桥联动

主区从单一 Dashboard 改为每 worktree 一个 tab,tab 标题带状态色点;舰桥点项跳到对应 tab;返港删除关闭对应 tab。

**Files:**
- Modify: `Sources/App/TabCoordinator.swift`(tab 粒度从 repo 细化到 worktree;新增 `func selectTab(forWorktree path: String)`)
- Modify: `Sources/UI/TitleBar/TitleBarView.swift`(tab 条按 worktree 渲染,带状态色点)
- Modify: `Sources/App/MainWindowController.swift`(把 `BridgePanelViewController.onNavigateToWorktree` 接到 `selectTab(forWorktree:)`)
- Test: `Tests/TabSelectionTests.swift`(若 `selectTab(forWorktree:)` 含可独立测试的索引解析逻辑,抽成纯函数测试)

**Interfaces:**
- Consumes: `allWorktrees`、`buildAgentDisplayInfos()`、`AgentStatus.color`、`PendingOrder.action.worktreePath`。
- Produces: `TabCoordinator.tabIndex(forWorktree path: String) -> Int?`(纯查找,可测)、`func selectTab(forWorktree path: String)`。

- [ ] **Step 1: 写失败测试(索引解析)**

`Tests/TabSelectionTests.swift`:

```swift
import XCTest
@testable import seamux

final class TabSelectionTests: XCTestCase {
    func testTabIndexForWorktreeMatchesPath() {
        let paths = ["/wt/a", "/wt/b", "/wt/c"]
        XCTAssertEqual(TabCoordinator.tabIndex(forWorktree: "/wt/b", in: paths), 1)
        XCTAssertNil(TabCoordinator.tabIndex(forWorktree: "/wt/z", in: paths))
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/TabSelectionTests
```
Expected: 编译失败("no member 'tabIndex(forWorktree:in:)'")。

- [ ] **Step 3: 实现纯查找 + selectTab**

在 `Sources/App/TabCoordinator.swift` 加:
```swift
static func tabIndex(forWorktree path: String, in paths: [String]) -> Int? {
    paths.firstIndex(of: path)
}

func selectTab(forWorktree path: String) {
    let paths = allWorktrees.map { $0.info.path }   // 字段名以 WorktreeInfo 源码为准
    if let idx = Self.tabIndex(forWorktree: path, in: paths) {
        switchToTab(idx)
    }
}
```

- [ ] **Step 4: 运行确认通过**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamuxTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seamuxTests/TabSelectionTests
```
Expected: PASS。

- [ ] **Step 5: tab 条按 worktree 渲染 + 状态色点 + 联动 + 删除关闭**

- `TitleBarView`:把 tab 项数据源从 repo 改为 worktree(每个 `allWorktrees` 项一个 tab),tab 标题前加一个状态色点(`AgentHead.shared.agent(forWorktree:)?.status.color`,无则灰)。
- `MainWindowController`:把左栏 `BridgePanelViewController.onNavigateToWorktree = { [weak tabCoordinator] path in tabCoordinator?.selectTab(forWorktree: path) }`。`onApprove` 中 `returnToPort` 执行删除后,`TabCoordinator.worktreeDidDelete(_:)` 已有的关闭逻辑负责移除该 tab。

- [ ] **Step 6: 构建 + 跑 run.sh 人工验收**

```bash
xcodebuild -project seamux.xcodeproj -scheme seamux -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
./run.sh
```
Expected: BUILD SUCCEEDED;启动后主区每 worktree 一个 tab,tab 带状态色点;点左栏舰桥的值更项跳到对应 tab。

- [ ] **Step 7: Commit**

```bash
git add Sources/App/TabCoordinator.swift Sources/UI/TitleBar/TitleBarView.swift Sources/App/MainWindowController.swift Tests/TabSelectionTests.swift
git commit -m "feat: per-worktree main tabs with status dots + Bridge navigation"
```

---

## Self-Review

**Spec coverage:**
- First Mate 定位 / 分级自治 → Task 2(引擎绿/红)、Task 5(分发)。
- 架构(AgentHead 之上薄层、边沿驱动、优先 hook 完工) → Task 4(`onStatusTransition` + `.agentStop` 完工信号)。
- 五类规则 A/C/B/B'/D → Task 2 evaluate + Task 5 分发;E 返港 → Task 6 + Task 7 确认流 + Task 8 删除关 tab。
- review 水手自动拉起(绿区) → Task 5 `runInspection` 内 autoReview 分支。
- 配置 `firstMate` → Task 1。
- UI 左栏 tab(默认 First Mate)、红上绿下、确认流、vim 键位 → Task 7。
- 主区每 worktree 一个 tab + 联动 + 返港关 tab → Task 8。
- 边界:完成判定优先 hook(Task 4);空闲 vs 等待靠 `AgentStatus` 区分(Task 2 按 newStatus 分支);红区幂等(Task 3 `PendingOrdersQueue` 去重)。
- A 的"持续超时":边沿触发时 holdSeconds≈0,Task 4 注明由 Coordinator 延时复查兜底 —— **补充**:Task 5 实现时应在 `watchWaiting` 路径加 `waitingTimeoutSec` 延时复查"是否仍 waiting"再 `notify`(执行细节,留给实现者,已在 Task 4 Step 3 说明)。

**Placeholder scan:** 纯逻辑任务(1/2/3/4/5/6/7 状态机、8 索引)均给出完整代码与测试。UI 渲染步骤(Task 7 Step 5、Task 8 Step 5)按仓库 AppKit 既有模式描述结构而非逐像素代码 —— 这是 UI 层惯例(仓库 UI 无单测),非占位符;其可测逻辑已抽成纯函数(BridgeConfirmFlow / tabIndex)并 TDD 覆盖。

**Type consistency:** `FirstMateActionKind` 在 Task 2 定义、Task 7 Step 2 补 `returnToPort`(并要求重跑 Task 2 测试);`StatusTransition` 字段在 Task 2/4/5 一致;`PendingOrder.id == "\(worktreePath)#\(kind)"` 在 Task 3 定义、Task 7 消费;`FirstMateCoordinator.init` 签名在 Task 5 测试与实现一致。

> 实现期注意:几处跨现有 API 的调用(`NotificationManager.shared.notify` 参数、`WorktreeTaskStore.shared.tasks(forWorktree:)`、`WorktreeInfo.path` 字段名)以源码实际签名为准,closure 仅做转发,不影响纯函数核心的正确性。
