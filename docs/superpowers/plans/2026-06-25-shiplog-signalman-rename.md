# Seahelm 船员编制重命名 + 信号员统一契约 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按"舰船编制"隐喻重命名核心领域类型(`AgentHead → ShipLog`,`terminal/surface → Station`,`agent → Sailor`),并把主动/被动两条情报通道的"解码"步骤统一抽象成一个 `SignalDecoder`(信号员)契约,产出统一的 `StatusReport` 再写入 ShipLog。

**Architecture:** 重命名分阶段、从最独立(`AgentHead`)到最纠缠(`agent`/`surface`)推进,每阶段以"Xcode 编译通过 + 既有测试绿"为验收门。信号员统一是一次真正的提取重构:定义 `SignalDecoder` 协议,把现有 `StatusDetector`(扫屏)与 `WebhookEvent→status`(钩子)两条解码路径各自实现为 `ScanDecoder` / `HookDecoder`,二者产出同一个 `StatusReport`,由 ShipLog 单点消费。

**Tech Stack:** Swift 5.10, AppKit, XcodeGen(`project.yml`), XCTest(`seahelmTests`),Ghostty C interop。

## Global Constraints

- 每个任务结束必须能编译:`xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
- 每个任务结束既有测试必须绿:`xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test`
- **绝不重命名的对象(雷区):**
  - Ghostty C API 符号:`ghostty_surface_*`、`ghostty_text_s`、`ghostty_selection_s`、`GHOSTTY_POINT_VIEWPORT` 等——这些来自 `ghostty.h`,改了链接失败。
  - 任何序列化键:`AgentStatus` 的 `rawValue` 字符串、config.json 的 `agents`/`agentRules`/CodingKeys、`ExternalChannel` 协议里 `InboundMessage`/`OutboundMessage` 的字段名、WeCom/WeChat 协议字段。**只改 Swift 类型名/局部标识符,不改任何会被 encode/decode 的字符串。**
  - git 概念:`worktree` 一律保留(用户已确认)。
- 改文件名后必须 `xcodegen generate` 重新生成工程(`project.yml` 按目录 glob `Sources`)。
- 重命名用编辑器级"符号全替换",不要无脑 `sed 's/surface/station/'`——`surface` 有 518 处,大量是 C API。

---

## Task 1: AgentHead → ShipLog(独立类,零风险)

**Files:**
- Rename: `Sources/Core/AgentHead.swift` → `Sources/Core/ShipLog.swift`
- Modify(符号 `AgentHead` → `ShipLog`,共 68 处 / 12 文件):
  - `Sources/Core/ShipLog.swift`(原 AgentHead.swift)
  - `Sources/Core/AgentInfo.swift`
  - `Sources/Core/AgentChannel.swift`
  - `Sources/Core/HooksChannel.swift`
  - `Sources/Core/WeComBotChannel.swift`
  - `Sources/Core/TerminalSurfaceManager.swift`
  - `Sources/Status/StatusPublisher.swift`
  - `Sources/UI/Dashboard/DashboardViewController.swift`
  - `Sources/App/MainWindowController.swift`
  - `Sources/App/AppDelegate.swift`
  - `Sources/App/TabCoordinator.swift`
  - `Sources/Terminal/TerminalSurface.swift`

**Interfaces:**
- Produces: `ShipLog.shared`(单例,原 `AgentHead.shared`),公开方法签名不变:`updateStatus(terminalID:status:lastMessage:roundDuration:tasks:lastUserPrompt:)`、`handleWebhookEvent(_:)`、`registerChannel(_:)`、`broadcast(_:format:)`、`handleInbound(_:)`。

- [ ] **Step 1: 确认 `AgentHead` 是唯一 token(无 `AgentHeader` 之类子串冲突)**

Run: `cd Sources && grep -roE "AgentHead[A-Za-z]*" . | sort -u`
Expected: 仅输出 `AgentHead`(无其它后缀),证明可安全整词替换。

- [ ] **Step 2: 全量符号替换 `AgentHead` → `ShipLog`**

在 12 个文件里把标识符 `AgentHead` 全部替换为 `ShipLog`(包含类声明 `class AgentHead` → `class ShipLog`、`AgentHead.shared` → `ShipLog.shared`、注释里的 `AgentHead`)。

- [ ] **Step 3: 重命名文件并重生成工程**

```bash
cd /Volumes/openbeta/workspace/seahelm
git mv Sources/Core/AgentHead.swift Sources/Core/ShipLog.swift
xcodegen generate
```

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: 残留检查 + 测试**

Run: `cd Sources && grep -rn "AgentHead" . ; cd .. && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test`
Expected: grep 无输出;测试 `TEST SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor: rename AgentHead to ShipLog"
```

---

## Task 2: 引入 StatusReport + SignalDecoder 协议(信号员契约,纯新增)

把"原始情报 → 规范化状态报告"抽象成统一类型与协议,此任务**只新增、不接线**(零行为变化),用单测锁定契约。

**Files:**
- Create: `Sources/Status/StatusReport.swift`
- Create: `Sources/Status/SignalDecoder.swift`
- Test: `Tests/SignalDecoderTests.swift`

**Interfaces:**
- Produces:
  - `struct StatusReport { let status: AgentStatus; let lastMessage: String; let activityEvents: [ActivityEvent] }`
  - `protocol SignalDecoder { func decode() -> StatusReport? }`
- Consumes: 既有 `AgentStatus`(`Sources/Core/AgentStatus.swift`)、`ActivityEvent`(`Sources/Core/ActivityEvent.swift`)。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/SignalDecoderTests.swift
import XCTest
@testable import seahelm

final class SignalDecoderTests: XCTestCase {
    func testStubDecoderProducesReport() {
        struct StubDecoder: SignalDecoder {
            func decode() -> StatusReport? {
                StatusReport(status: .waiting, lastMessage: "hi", activityEvents: [])
            }
        }
        let report = StubDecoder().decode()
        XCTAssertEqual(report?.status, .waiting)
        XCTAssertEqual(report?.lastMessage, "hi")
        XCTAssertEqual(report?.activityEvents.count, 0)
    }
}
```

- [ ] **Step 2: 运行,确认编译失败(类型未定义)**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/SignalDecoderTests`
Expected: FAIL —`cannot find 'StatusReport'`/`SignalDecoder' in scope`

- [ ] **Step 3: 新增类型与协议**

```swift
// Sources/Status/StatusReport.swift
import Foundation

/// 信号员解码后的规范化状态报告,所有情报通道的统一产出。
struct StatusReport {
    let status: AgentStatus
    let lastMessage: String
    let activityEvents: [ActivityEvent]
}
```

```swift
// Sources/Status/SignalDecoder.swift
import Foundation

/// 信号员:把某条情报通道的原始输入解码成规范化的 StatusReport。
/// 主动通道(扫屏)与被动通道(钩子)各自实现本协议。
protocol SignalDecoder {
    /// 返回 nil 表示本次无可上报的变化。
    func decode() -> StatusReport?
}
```

- [ ] **Step 4: xcodegen + 测试通过**

```bash
xcodegen generate
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/SignalDecoderTests
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add StatusReport and SignalDecoder contract"
```

---

## Task 3: ScanDecoder —— 主动通道(瞭望员+信号员)实现 SignalDecoder

把 `StatusDetector.detect()` + `extractActivityEvents()` 包成一个实现 `SignalDecoder` 的 `ScanDecoder`。`StatusDetector` 本身**保持不变**(底层解码逻辑复用),`ScanDecoder` 只是把"读到的屏幕文本 + 进程状态"包成 `StatusReport`。

**Files:**
- Create: `Sources/Status/ScanDecoder.swift`
- Test: `Tests/ScanDecoderTests.swift`

**Interfaces:**
- Consumes: `SignalDecoder`、`StatusReport`(Task 2);`StatusDetector.detect(processStatus:shellInfo:content:agentDef:lowercasedContent:) -> AgentStatus`、`StatusDetector.extractActivityEvents(from:) -> [ActivityEvent]`(既有,`Sources/Status/StatusDetector.swift:15,57`);`ProcessStatus`、`AgentDef`、`ShellPhaseInfo`(既有)。
- Produces: `struct ScanDecoder: SignalDecoder { init(detector:processStatus:shellInfo:content:agentDef:) }`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ScanDecoderTests.swift
import XCTest
@testable import seahelm

final class ScanDecoderTests: XCTestCase {
    func testProcessExitedMapsToExited() {
        let decoder = ScanDecoder(
            detector: StatusDetector(),
            processStatus: .exited,
            shellInfo: nil,
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(decoder.decode()?.status, .exited)
    }

    func testEmptyContentRunningIsUnknown() {
        let decoder = ScanDecoder(
            detector: StatusDetector(),
            processStatus: .running,
            shellInfo: nil,
            content: "",
            agentDef: nil
        )
        XCTAssertEqual(decoder.decode()?.status, .unknown)
    }
}
```

- [ ] **Step 2: 运行,确认失败**

Run: `xcodebuild ... test -only-testing:seahelmTests/ScanDecoderTests`
Expected: FAIL —`cannot find 'ScanDecoder' in scope`

- [ ] **Step 3: 实现 ScanDecoder**

```swift
// Sources/Status/ScanDecoder.swift
import Foundation

/// 主动通道的信号员:扫屏文本 + 进程状态 → StatusReport。
/// 取数(瞭望员)发生在 StatusPublisher;本类型只负责解码。
struct ScanDecoder: SignalDecoder {
    let detector: StatusDetector
    let processStatus: ProcessStatus
    let shellInfo: ShellPhaseInfo?
    let content: String
    let agentDef: AgentDef?

    func decode() -> StatusReport? {
        let status = detector.detect(
            processStatus: processStatus,
            shellInfo: shellInfo,
            content: content,
            agentDef: agentDef
        )
        let events = detector.extractActivityEvents(from: content)
        // lastMessage 由调用方(StatusPublisher)用既有逻辑补,先留空串占位
        return StatusReport(status: status, lastMessage: "", activityEvents: events)
    }
}
```

- [ ] **Step 4: xcodegen + 测试通过**

```bash
xcodegen generate
xcodebuild ... test -only-testing:seahelmTests/ScanDecoderTests
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add ScanDecoder (active-channel SignalDecoder)"
```

---

## Task 4: HookDecoder —— 被动通道(信号员,无瞭望员)实现 SignalDecoder

把现有 `WebhookEvent → status/message/events` 的解码逻辑(目前散落在 `ShipLog.handleWebhookEvent` / `HooksChannel.extractMessage` / `ActivityEventExtractor`)收口到 `HookDecoder`。

**Files:**
- Create: `Sources/Status/HookDecoder.swift`
- Test: `Tests/HookDecoderTests.swift`
- Read(理解既有映射,不改):`Sources/Status/WebhookEvent.swift`、`Sources/Core/ActivityEventExtractor.swift`、`Sources/Core/HooksChannel.swift:80`(`extractMessage(from:)`)

**Interfaces:**
- Consumes: `SignalDecoder`、`StatusReport`;`WebhookEvent`(`Sources/Status/WebhookEvent.swift`);`ActivityEventExtractor.extract(...)`(既有)。
- Produces: `struct HookDecoder: SignalDecoder { init(event: WebhookEvent) }`

- [ ] **Step 1: 写失败测试**(用一个 agentStop 事件应映射到完成/waiting 语义——以 `WebhookEvent` 既有枚举为准)

```swift
// Tests/HookDecoderTests.swift
import XCTest
@testable import seahelm

final class HookDecoderTests: XCTestCase {
    func testAgentStopMapsToWaiting() {
        // 用 WebhookEvent 的实际构造方式构造一个 agentStop 事件
        let event = WebhookEvent.makeForTest(type: .agentStop, message: "done")
        let report = HookDecoder(event: event).decode()
        XCTAssertEqual(report?.status, .waiting)
        XCTAssertEqual(report?.lastMessage, "done")
    }
}
```

> 注:`WebhookEvent.makeForTest` 若不存在,本步骤先在 `WebhookEvent.swift` 加一个 `#if DEBUG` 测试构造器,或改用既有 JSON 解析入口构造;具体以 `WebhookEvent.swift:62-159` 的真实初始化路径为准(实现者先读该文件确定构造方式,再落测试)。

- [ ] **Step 2: 运行,确认失败**

Run: `xcodebuild ... test -only-testing:seahelmTests/HookDecoderTests`
Expected: FAIL —`cannot find 'HookDecoder' in scope`

- [ ] **Step 3: 实现 HookDecoder(复用既有映射,不重写规则)**

```swift
// Sources/Status/HookDecoder.swift
import Foundation

/// 被动通道的信号员:Claude Code 钩子事件 → StatusReport。
/// 无瞭望员——水手主动喊报告(webhook 推送),本类型只负责解码。
struct HookDecoder: SignalDecoder {
    let event: WebhookEvent

    func decode() -> StatusReport? {
        // 复用既有 WebhookEvent → AgentStatus 的映射(从 ShipLog.handleWebhookEvent 抽出)
        guard let status = event.mappedStatus else { return nil }
        let message = event.mappedMessage ?? ""
        let events = ActivityEventExtractor.extract(from: event)
        return StatusReport(status: status, lastMessage: message, activityEvents: events)
    }
}
```

> `event.mappedStatus` / `event.mappedMessage`:把目前写在 `ShipLog.handleWebhookEvent`(`Sources/Core/ShipLog.swift:324`)里的"事件类型 → 状态/消息"分支,平移成 `WebhookEvent` 的计算属性。实现者读 `handleWebhookEvent` 现状后,原样搬运分支逻辑,不改语义。

- [ ] **Step 4: 把 ShipLog.handleWebhookEvent 改为复用 HookDecoder(去重)**

将 `ShipLog.handleWebhookEvent` 内部的解码分支替换为 `HookDecoder(event:).decode()`,用返回的 `StatusReport` 走与主动通道相同的写入路径(见 Task 5)。保持外部行为不变。

- [ ] **Step 5: xcodegen + 全量测试**

```bash
xcodegen generate
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test
```
Expected: PASS(含既有 webhook 相关测试)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add HookDecoder and route webhook through SignalDecoder"
```

---

## Task 5: ShipLog 单点消费 StatusReport(收口)

让 ShipLog 暴露一个统一入口 `ingest(terminalID:report:)`,主动通道(StatusPublisher)与被动通道(handleWebhookEvent)都改为构造 `StatusReport` 后调用它。`updateStatus` 退化为内部细节。

**Files:**
- Modify: `Sources/Core/ShipLog.swift:142`(`updateStatus`)、`:324`(`handleWebhookEvent`)
- Modify: `Sources/Status/StatusPublisher.swift:256-272`(改为构造 `ScanDecoder` → `ingest`)
- Test: `Tests/ShipLogIngestTests.swift`

**Interfaces:**
- Produces: `ShipLog.ingest(terminalID: String, report: StatusReport, lastUserPrompt: String)` —— 统一写入口;内部仍调用既有状态合并 + `broadcast` 跃迁判定逻辑(`ShipLog.swift:187-191`,仅 `.waiting`/`.error` 跃迁才推 bridge)。
- Consumes: `StatusReport`、`ScanDecoder`、`HookDecoder`。

- [ ] **Step 1: 写失败测试**(ingest 一个 waiting 报告后,`info.status` 变为 waiting)

```swift
// Tests/ShipLogIngestTests.swift
import XCTest
@testable import seahelm

final class ShipLogIngestTests: XCTestCase {
    func testIngestUpdatesStatus() {
        let log = ShipLog.shared
        let report = StatusReport(status: .waiting, lastMessage: "need input", activityEvents: [])
        log.ingest(terminalID: "t-ingest-1", report: report, lastUserPrompt: "")
        XCTAssertEqual(log.info(forTerminal: "t-ingest-1")?.status, .waiting)
    }
}
```

> `info(forTerminal:)`:若无此读取接口,用既有等价 getter(实现者读 `ShipLog.swift` 确认现有查询 API 名)。

- [ ] **Step 2: 运行,确认失败**

Run: `xcodebuild ... test -only-testing:seahelmTests/ShipLogIngestTests`
Expected: FAIL —`value of type 'ShipLog' has no member 'ingest'`

- [ ] **Step 3: 实现 `ingest`,把 `updateStatus` 内部化**

在 `ShipLog` 新增 `ingest(terminalID:report:lastUserPrompt:)`:解出 `report.status/lastMessage/activityEvents`,调用既有状态合并 + 跃迁广播逻辑(把 `updateStatus` 主体迁入或由 `ingest` 调用 `updateStatus`)。保持 `broadcast` 触发条件不变。

- [ ] **Step 4: StatusPublisher 改为走 ScanDecoder → ingest**

在 `StatusPublisher.pollAll`(`:256-272`)把当前"`detect` 后直接 `updateStatus`"替换为:构造 `ScanDecoder(detector:processStatus:shellInfo:content:agentDef:)` → `decode()` → 补 `lastMessage`/`lastUserPrompt` → `ShipLog.shared.ingest(...)`。

- [ ] **Step 5: 全量编译 + 测试**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test
```
Expected: BUILD/TEST SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor: unify status ingestion through SignalDecoder/StatusReport"
```

---

## Task 6: terminal/surface(领域层)→ Station

**仅**重命名领域层类型,**保留** Ghostty 引擎绑定与 C API。先列符号映射,逐个确认后再改。

**Files(领域层重命名目标,逐文件确认):**
- Rename: `Sources/Terminal/TerminalSurface.swift` → `Sources/Terminal/Station.swift`
- Rename: `Sources/Core/TerminalSurfaceManager.swift` → `Sources/Core/StationManager.swift`
- Modify: `Sources/Core/SurfaceRegistry.swift`(`SurfaceRegistry` → `StationRegistry`)及所有引用方。

**符号映射(仅这些;其余含 `surface` 的一律保留):**
- `TerminalSurface`(类)→ `Station`
- `TerminalSurfaceManager` → `StationManager`
- `SurfaceRegistry` → `StationRegistry`,`SurfaceRegistry.shared` → `StationRegistry.shared`
- 领域层属性/参数 `surface:`/`activeSurface`/`surfaceId`(指代我们的封装对象,**非** `ghostty_surface_t`)→ `station`/`activeStation`/`stationId`

**保留(雷区,绝不改):**
- 所有 `ghostty_surface_*(...)` C 调用、`GhosttyNSView`(它是 NSView+Metal 渲染器,属引擎层)、`var surface` 当其类型为 Ghostty 不透明指针时。

- [ ] **Step 1: 区分领域 surface 与引擎 surface**

Run: `cd Sources && grep -rn "surface" . | grep -v "ghostty_surface" | grep -iE "TerminalSurface|SurfaceRegistry|surfaceManager"`
Expected: 输出即为可安全重命名的领域层引用清单;逐条核对其类型不是 Ghostty 指针。

- [ ] **Step 2: 重命名类型 `TerminalSurface` → `Station`**(整词替换,40 处),`TerminalSurfaceManager` → `StationManager`,`SurfaceRegistry` → `StationRegistry`。

- [ ] **Step 3: 重命名文件 + 重生成工程**

```bash
cd /Volumes/openbeta/workspace/seahelm
git mv Sources/Terminal/TerminalSurface.swift Sources/Terminal/Station.swift
git mv Sources/Core/TerminalSurfaceManager.swift Sources/Core/StationManager.swift
xcodegen generate
```

- [ ] **Step 4: 编译验证(尤其确认 Ghostty 链接未断)**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`
Expected: BUILD SUCCEEDED(若报 `ghostty_surface_*` 未定义,说明误改了 C 符号,回退该处)

- [ ] **Step 5: 测试 + 残留检查**

Run: `xcodebuild ... test ; cd Sources && grep -rn "TerminalSurface\|SurfaceRegistry" .`
Expected: TEST SUCCEEDED;grep 无输出

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor: rename TerminalSurface domain types to Station"
```

---

## Task 7: agent(领域层)→ Sailor

**仅**重命名领域层标识符,**保留**所有序列化键与 AI 概念边界。这是最纠缠的一步,逐类型确认。

**符号映射(类型名安全,因 Swift Codable 不序列化类型名):**
- `AgentStatus`(`Sources/Core/AgentStatus.swift`)→ `SailorStatus`(**case rawValue 字符串不动**)
- `AgentInfo` → `SailorInfo`,`AgentDisplayInfo` → `SailorDisplayInfo`
- `AgentType` → `SailorType`,`AgentDef` → `SailorDef`,`AgentRule` → `SailorRule`,`AgentDetectConfig` → `SailorDetectConfig`
- `AgentChannel`/`AgentChannelType` → `SailorChannel`/`SailorChannelType`
- `AgentCardView`/`AgentCardDelegate` → `SailorCardView`/`SailorCardDelegate`
- 局部标识符 `selectedAgentId`/`focusedAgent`/`allAgents`/`activeAgentCount` 等 → `...Sailor...`

**保留(雷区,绝不改):**
- config.json 序列化键:property 名与 CodingKeys(若属性名恰为 `agents`/`agentRules` 且被 encode,**保留属性名**,只改类型名)。改前 `grep -rn "CodingKeys\|case agents\|\"agents\"" .` 核对。
- `AgentStatus` 各 case 的 rawValue(它们是持久化/展示字符串)。
- `isAIAgent`:属"是不是 AI"语义而非编制,**保留**(或单列讨论,默认不改)。
- `ExternalChannel`/`InboundMessage`/`OutboundMessage`(bridge,不属 agent)。

- [ ] **Step 1: 核对序列化边界**

Run: `cd Sources && grep -rn "CodingKeys\|decodeIfPresent\|\"agent" . | grep -i agent`
Expected: 列出所有受 Codable 约束的 `agent*` 键;这些**属性名/字符串保持不变**,只改其外层类型名。

- [ ] **Step 2: 逐类型整词替换**(按上方映射;`AgentStatus → SailorStatus` 等),跳过雷区清单。

- [ ] **Step 3: 重命名相关文件**

```bash
cd /Volumes/openbeta/workspace/seahelm
git mv Sources/Core/AgentStatus.swift Sources/Core/SailorStatus.swift
git mv Sources/Core/AgentInfo.swift Sources/Core/SailorInfo.swift
git mv Sources/Core/AgentChannel.swift Sources/Core/SailorChannel.swift
# ...其余 Agent* 文件同理
xcodegen generate
```

- [ ] **Step 4: 编译 + 测试**

Run: `xcodebuild ... build && xcodebuild ... test`
Expected: BUILD/TEST SUCCEEDED

- [ ] **Step 5: 配置兼容性回归**(关键:确认旧 config.json 仍能加载)

手动:用一份既有 `~/.config/seahelm/config.json` 启动,确认 agent 规则/状态正常解析(序列化键未变)。
Run: `xcodebuild ... test -only-testing:seahelmTests/ConfigTests`
Expected: TEST SUCCEEDED

- [ ] **Step 6: 残留检查 + Commit**

Run: `cd Sources && grep -rn "Agent" . | grep -v "isAIAgent\|ghostty"`(预期仅剩有意保留项)

```bash
git add -A && git commit -m "refactor: rename agent domain types to Sailor"
```

---

## Self-Review

- **Spec coverage:** ShipLog(T1)、SignalDecoder 契约(T2)、主动 ScanDecoder(T3)、被动 HookDecoder(T4)、ShipLog 收口(T5)、Station(T6)、Sailor(T7)——四项命名诉求 + 信号员统一全部覆盖;worktree 按要求未改。
- **Type consistency:** `StatusReport{status,lastMessage,activityEvents}` 在 T2 定义,T3/T4/T5 一致引用;`SignalDecoder.decode() -> StatusReport?` 全程一致;`ScanDecoder`/`HookDecoder` 构造器签名在各自任务的 Interfaces 块固定。
- **雷区一致性:** Ghostty C API、序列化键、worktree 在 Global Constraints 与 T6/T7 双重标注。
- **已知留待实现者确认的真实接口名**(读源后落定,非占位):`WebhookEvent` 的构造/映射入口(T4)、`ShipLog` 既有查询 getter 名(T5)、config 的 CodingKeys(T7)。这些在对应步骤已显式标注"读 X 文件确定"。
