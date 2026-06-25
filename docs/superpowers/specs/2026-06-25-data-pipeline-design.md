# Seahelm 数据管线整体方案:同源采集 → ShipLog 记录/reduce → 同源裁决推送 Bridge

> 状态:设计稿,待评审。
> 关系:本方案**取代** rename 计划(`docs/superpowers/plans/2026-06-25-shiplog-signalman-rename.md`)的 Task 2–5(原 `StatusReport` / `SignalDecoder.decode() -> StatusReport?` 契约)。rename 计划的纯改名部分(Task 1 ShipLog、Task 6 Station、Task 7 Sailor)仍然有效。

## 一句话目标

**ShipLog 是唯一枢纽:所有情报进来走一个 `ingest(NormalizedEvent)`,所有结果出去走一个 `IngestOutcome` 流。任何来源不准旁路,任何消费者不准开后门。**

四处"同源":
1. **采集同源** —— 扫屏 / webhook / MCP / shell 都翻译成 `NormalizedEvent` 投给 ShipLog。
2. **记录同源** —— ShipLog 只有一个写入口 `ingest`,忠实记录 + reduce。
3. **触发同源** —— FirstMate(裁决层)只订阅 ShipLog 的 `IngestOutcome`,触发逻辑只有一份。
4. **Order 同源** —— agent 的 Suggestion 并入 Pending Order,都由 FirstMate 产出、同队列。

## 核心原则:记录与处理分离

ShipLog 是"航海日志",职责是**先如实记录,再由下游解读**,绝不边记边裁决。

- **归一化 = 翻译**(原始 → 结构化事件):无损、无策略、无丢弃。发生在记录前。
- **处理 = 解读/裁决**(这事件意味着什么状态?要不要惊动用户?):全部退到记录之后,作为对"日志新增一条"的反应。

当前代码的反模式:`ShipLog.updateStatus` 里一边写状态、一边判断跃迁、一边决定 broadcast —— 把记录和处理焊死在写路径上。本方案拆开。

---

## 全景图

```
[任意来源]
  扫屏 (StatusPublisher)   ─┐
  webhook hook(claude/codex)─┤
  MCP(工具调用/事件)       ─┼─→ SignalDecoder → NormalizedEvent
  shell(OSC133/命令钩子)   ─┘        (只翻译,不裁决)
                                          │
                                  ShipLog.ingest()        ← 唯一入口
                                          │
                          ┌── eventLog 忠实记录(环形缓冲)
                          └── reduce(station 级)→ IngestOutcome  ← 唯一出口
                                          │
              ┌───────────────┬───────────┴───────────────┐
              ↓               ↓                            ↓
        UIObserver     WorktreeAggregator            FirstMate(唯一裁决)
        刷卡片          聚合 worktree status            只吃 IngestOutcome
                       (共用 WorktreeStatusReducer)         │
                                                      ┌──────┴──────┐
                                                   .green         .red
                                                  WatchFeed   PendingOrdersQueue
                                                  (Watch 区)   (Order 区:规则动作 + agent 建议)
```

WeCom/WeChat 外部通道(`ExternalChannel`)作为**第四个独立订阅者**存在(沿用现状的 `broadcast`),不属于本方案的 Bridge 面板三段,后续可单独演化。

---

## 第一段:统一输入语言 `NormalizedEvent`

所有来源翻译后的统一形态。装下两类情报:**事件原生**(webhook/MCP/shell 的离散事件)与**状态原生**(扫屏的快照观测)。

```swift
struct NormalizedEvent {
    let terminalID: String     // 已解析好的归属(webhook 经 cwd→worktree→tid)
    let source: Source         // .scan / .hook(claudeCode/codex) / .mcp / .shell
    let timestamp: Date
    let kind: Kind
}

enum Kind {
    // —— 事件原生 ——
    case sessionStarted
    case toolUse(ActivityEvent)               // start/end/failed 都落成一条 activity
    case userPrompt(String)
    case taskUpdate([TaskItem])
    case agentStopped(success: Bool)          // 完成信号来源
    case notification(level: String, text: String)
    case suggest(options: [String])           // agent 拟的候选指令(并入 Order,见第三段)

    // —— 状态原生(扫屏)——
    case screenObserved(status: AgentStatus,  // decoder 跑完 AgentDef 规则的观测值
                        message: String,
                        activity: [ActivityEvent],
                        commandLine: String?,
                        agentType: AgentType)
}
```

### SignalDecoder 契约

```swift
protocol SignalDecoder {
    func decode() -> NormalizedEvent?   // 返回 nil = 本次无可上报
}
```

实现:
- `ScanDecoder` —— 扫屏文本 + 进程状态 → `.screenObserved`。**复用现有 `StatusDetector`**(text→status 规则匹配依赖 AgentDef/config,留在 decoder 内,属"观测翻译"而非"裁决")。
- `HookDecoder` —— webhook JSON → 其余各 case。**webhook 的 `WebhookEventType.agentStatus()` 映射表从 decoder 移走,搬进 ShipLog reduce。**
- `MCPDecoder` —— MCP 工具调用/事件 → `.toolUse` / `.taskUpdate` / `.suggest` 等。
- `ShellDecoder` —— OSC133 shell phase / 命令钩子 → `.screenObserved`(status 部分)或 `.sessionStarted` 等。

**两条线不对称是事实,不强行抹平:** webhook/MCP/shell 是事件原生(decode 不带 status,reduce 算);扫屏是状态原生(decode 给出"观测状态",reduce 负责跨源合并)。两者都满足"decode 只翻译"——"我观测到此刻屏幕读作 waiting"是陈述观测,不是裁决。

---

## 第二段:ShipLog = 忠实记录 + reduce 到 station 级

ShipLog 对每个 **station(terminal pane)** 维护两个投影,都是同一条事件流的产物:

```swift
class ShipLog {
    private var eventLog: [String: [NormalizedEvent]]  // tid → 最近 N 条,忠实记录(环形缓冲,不持久化)
    private var agents:   [String: AgentInfo]          // tid → reduce 出的当前快照
}
```

### 唯一写入口

替代现有四套散落路径(`updateStatus` / `updateDetection` / `appendActivityEvent` / `handleWebhookEvent`):

```swift
func ingest(_ event: NormalizedEvent) {
    lock.lock()
    appendToEventLog(event)                                  // 1. 忠实记录,无条件无丢弃
    let outcome = reduce(event, into: &agents[event.terminalID])  // 2. reduce 出快照 + delta
    lock.unlock()
    notifyObservers(outcome)                                 // 3. 只广播"已记录",不做业务裁决
}
```

### reduce(纯函数:旧快照 + 一条事件 → 新快照 + delta)

把现散落各处的逻辑收口进来:

| 事件 kind | reduce 做的事(原出处) |
|---|---|
| `.screenObserved` | 记下扫屏观测状态;**station 内**合并 status = `highestPriority(扫屏观测, webhook 推断)`(原 StatusPublisher:243);更新 message/commandLine/agentType/activity |
| `.toolUse` | upsert 进 activityEvents 环形缓冲(原 ShipLog:392) |
| `.agentStopped` | webhook 推断状态 → idle;置 `isCompletionSignal` delta;清 activity(原 ShipLog:354) |
| `.userPrompt` | 更新 lastUserPrompt |
| `.taskUpdate` | 更新 tasks/taskProgress |
| `.notification` | level → status 参与优先级合并 |
| `.suggest` | **不动 status**,delta 标记带 options 透传给下游 |

### IngestOutcome(唯一出口)

```swift
struct IngestOutcome {
    let info: AgentInfo            // 新快照(给 UI)
    let statusChanged: Bool
    let oldStatus, newStatus: AgentStatus
    let holdSeconds: Double
    let isCompletionSignal: Bool   // agentStopped 来的
    let event: NormalizedEvent     // 原事件透传(suggest 的 options 走这里)
}
```

### 粒度边界

- **reduce 只到 station 级。** 产出 station 级 `AgentInfo` + `IngestOutcome`。
- **worktree 级聚合是下游的事**,不上移进 ShipLog。`worktreeIndex`(1:N)不变。
- 两种 `highestPriority` 分属不同层,别混:
  1. **station 内**(reduce):同一 pane 的"扫屏观测状态" vs "webhook 推断状态"。
  2. **station 间**(aggregator):同一 worktree 下多 pane 状态。
- ShipLog **不再**在写路径调 `broadcast`(删掉 `updateStatus` 里 `if status == .waiting || .error { broadcast }`)。
- StatusPublisher 退化成纯瞭望员:取文本 → 造 `ScanDecoder` → `decode()` → `ShipLog.ingest`。

---

## 第三段:下游处理 —— 三个互不相干的订阅者

ShipLog 发出 `IngestOutcome` 后,订阅者各自反应,彼此不知道对方存在。

### ① UIObserver
刷新 Dashboard 卡片(station 级 `AgentInfo`)。

### ② WorktreeStatusAggregator
聚合同 worktree 下多 station → worktree status。**聚合算法抽成纯函数共用,不复制:**

```swift
enum WorktreeStatusReducer {
    static func aggregate(_ stations: [AgentInfo]) -> AgentStatus  // = highestPriority
}
```

### ③ FirstMate —— Bridge 面板的唯一产地

裁决层。**只订阅 `IngestOutcome`**,触发逻辑只有一份、只有一个入口。输入从"只有 StatusTransition"扩成"统一吃 IngestOutcome",内部分流:

```swift
enum FirstMate {
    static func evaluate(_ outcome: IngestOutcome, config: FirstMateConfig) -> [FirstMateAction] {
        switch outcome.event.kind {
        case .suggest(let options):
            // agent 主动给的候选 → 一条带 options 的 red-zone order
            return [FirstMateAction(kind: .suggestNextOrder, zone: .red, …, options: options)]
        default:
            // 状态跃迁/完成信号 → 原有规则
            return evaluateTransition(outcome /* old/new/hold/completion */, config)
        }
    }
}
```

产出按 zone 分流到 Bridge 面板**两个区**(原三区合并):

| Bridge 区 | 语义 | 来源 |
|---|---|---|
| **Watch(绿区)** | "我**告诉**你发生了 X"(只通知) | `.green` action:watchWaiting / watchError / inspect |
| **Pending Order(红区)** | "我**想做** X / 建议你做 X,你拍板"(待审批) | `.red` action:autoCommit / returnToPort / broadcastOrder + **agent suggestion(带 options)** |

### Order 同源(Suggestion 并入 Pending Order)

合并的依据:Suggestion 和 Pending Order 本质都是"等用户拍板的下一步指令"。`suggestNextOrder` 本就是个 red-zone order;`.suggest` 的 options 不过是"agent 替你拟好的几条候选"。

- **删掉独立的 `SuggestionFeed`**,`.suggest` 不再单独成区。
- `PendingOrder` 扩字段承载候选:

```swift
struct PendingOrder {
    let kind: FirstMateActionKind
    let worktreePath, branch, project, terminalID: String
    let message: String
    let options: [String]?     // 新增:nil = 单动作(批/否);非 nil = agent 候选,UI 渲染成可点 chips
}
```

- 同一队列,按 kind 区分渲染:options 类 → 多选 chips(点一个 = 选定该 order);单动作类 → 批/否按钮。
- 去重沿用 `PendingOrdersQueue` 的 `worktreePath + kind` 幂等。

> 红区共存/去重的细节(options 类是否覆盖同 worktree 其他 order、是否视觉分组)留待实现期定;默认"同队列、按 kind 渲染、worktreePath+kind 去重"。

### ④ ExternalChannel broadcast(WeCom/WeChat,独立订阅者)
沿用现状的 `broadcast(text, format:)`,作为第四个订阅者,不分三类。是否按 watch/order 分模板推外部,留作后续单独议题。

---

## 隔离与可测性

每个单元单一职责、接口清晰、可独立测试:

- `SignalDecoder` 各实现:输入原始数据 → 输出 `NormalizedEvent`,纯翻译,易单测。
- `ShipLog.reduce`:纯函数(旧快照 + 事件 → 新快照 + delta),无 IO,易单测。
- `WorktreeStatusReducer.aggregate`:纯函数,易单测。
- `FirstMate.evaluate`:纯规则引擎(已是),输入 `IngestOutcome` → 输出 actions,易单测。
- 订阅者通过 `IngestOutcome` 解耦,可独立开关/替换。

## 雷区(不改)

- Ghostty C API 符号、所有序列化键(`AgentStatus` rawValue、config.json CodingKeys、`InboundMessage`/`OutboundMessage` 字段、WeCom/WeChat 协议字段)、git `worktree` 概念 —— 同 rename 计划 Global Constraints。
- `eventLog` 不持久化到磁盘(YAGNI),仅内存环形缓冲供调试/审计/未来回放。

## 与 rename 计划的衔接

- 本方案的 `NormalizedEvent` **取代** rename Task 2 的 `StatusReport`。
- `SignalDecoder.decode()` 返回 `NormalizedEvent?`(非 `StatusReport?`)。
- rename Task 3/4/5(ScanDecoder/HookDecoder/ShipLog 收口)按本方案的 `ingest`/`reduce`/`IngestOutcome` 重新表述。
- rename Task 1(AgentHead→ShipLog,已部分完成)、Task 6(Station)、Task 7(Sailor)不受影响。
- 命名:本方案沿用现有类型名(AgentInfo/AgentStatus 等),与 Sailor 改名互不冲突,可在 Task 7 一并改。

## 待实现期确认的真实接口(读源定,非占位)

- `WebhookEvent` → `NormalizedEvent.Kind` 各 case 的精确映射(读 `WebhookEvent.swift`、`WebhookStatusProvider.swift`)。
- MCP / shell 来源的具体事件载荷与对应 case(读现有 MCP/shell 接入点,若尚无则本段为新增设计)。
- `PendingOrdersQueue` / `FirstMateCoordinator` 现有接线,改为订阅 `IngestOutcome` 的具体改法。
- `FirstMate.evaluateTransition` 从现 `evaluate(StatusTransition)` 主体平移。
</content>
</invoke>
