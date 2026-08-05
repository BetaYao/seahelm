# Gmail 邮箱会话通道设计

> 状态：已确认，待实现。产品规则来自 2026-08-05 的方案评审；平台调研及一手资料见
> [`docs/email-communication-research.md`](../../email-communication-research.md)。

## 1. 目标与范围

让 Seahelm 在**应用运行且 Gmail 同步正常**时，把一个受控 Gmail 别名变成所有项目 pane 的邮件入口：

- 用户从自己的 Gmail 向 `you+seahelm@gmail.com` 发邮件，主题以
  `[seahelm:<project>]` 开头；
- Seahelm 将合格的新线程创建为该项目的 pane，将合格的后续回复投递给同一 pane；
- pane 进入 waiting、完成或报错时，Seahelm 在同一邮件线程发出一封纯文本摘要。

这里的“会话”严格等于 Seahelm 的持久 pane（`pane_session_key`），不是另一份聊天记录。邮件通道只
保存路由、审计和附件元数据，状态真源仍是 `ShipLog`。

### 非目标（v1）

- 不支持 Outlook、IMAP、多个 Gmail 账户、共享收件人或每 pane 邮箱地址。
- 不在 Seahelm 退出时运行，不使用公网 webhook，不补处理离线期间的邮件。
- 不读取 HTML 语义、运行附件、发送完整终端屏幕，或绕过 agent 自身的沙箱／审批策略。
- 不将 Gmail 抽象塞进现有 `ExternalChannel`：该接口表达的是通用聊天收发，缺少 RFC 线程、邮件头、
  MIME 附件、provider cursor 与审计语义；把这些复杂度泄漏进去会得到一个浅 module。

## 2. 已确认的产品规则

| 范畴 | v1 规则 |
| --- | --- |
| 账户与别名 | OAuth 连接一个 Gmail 账户。固定入口为该账户的 `+seahelm` 别名。|
| 入站授权 | 只接受 `From` 为绑定 Gmail 主地址、`To` 含入口别名、主题为 `[seahelm:<project>]` 的邮件。显示名、转发邮件、自动回复及未知地址一律拒绝。|
| 项目路由 | `<project>` 只匹配设置中显式配置的项目别名→本地 worktree 路径。邮件不能提供本地路径、Git URL 或 shell 内容。|
| 新线程 | 命中有效项目且无既有映射时，创建该 worktree 的新 pane，以邮件正文作为首条输入。|
| 既有线程 | 以 Gmail `threadId` 与本地 `pane_session_key` 的持久映射定位；主题在首封后不再作为路由依据。|
| 投递门槛 | 已绑定 pane 仅在 `waiting` 时接收；每条线程串行，其他状态保留拒绝审计且不注入。|
| 内容 | 正文转纯文本；允许 PDF、PNG/JPEG/HEIC、txt/md 附件，均只作本地会话资料。忽略其他附件、HTML、内嵌图、引用历史与签名。|
| 出站 | 状态迁移到 waiting、完成或 error 时，发一封最终回复/明确问题摘要。禁止终端屏幕、命令输出、diff、环境变量和 token。|
| 运行与失败 | 只从启用时刻开始轮询，停止或授权失效期间的邮件绝不补处理。发送失败显示状态，用户显式重试；按 provider message ID 去重。|

`+seahelm` 只是同一 Gmail 收件箱的可筛选地址，不是独立身份或安全隔离。因此入站验证必须同时检查
收件人、发件人、线程映射和已处理 Gmail message ID，不能只依赖别名。

## 3. 架构与 seam

新增一个深 module `GmailMailChannel`，其公开 interface 保持为三个生命周期动作：

```swift
protocol GmailMailChannel {
    func start()
    func stop()
    func update(config: GmailMailConfig)
}
```

它由 `AppDelegate` 创建并持有，和 `MqttChannel` 一样在应用生命周期内启动/关闭。调用方不需要了解
OAuth、Gmail history、MIME、线程、去重、轮询或重试；这些全部留在 module 内以获得 depth 和 locality。

内部使用三个私有 adapter：

```
Gmail REST / OAuth ─┐
                    ▼
              GmailMailChannel ── MailPaneRouter ── MainWindowController
                    │                    │
                    │                    └─ ShipLog / ControlDataSource → Station
                    ▼
       EmailConversationStore + EmailAttachmentStore
                    ▲
                    │
       ShipLog IngestOutcome ── MailPaneObserver ── GmailMailChannel
```

- **`GmailClient` adapter**：唯一知道 Google OAuth、`messages.list/get/send`、`historyId`、MIME 与
  base64url 的实现。测试以 `GmailClientFake` 替换。
- **`MailPaneRouter` adapter**：唯一可以把通过验证的邮件转换为“创建 pane”或
  `ControlDataSource.sendText(..., enter: true)` 的位置。它在主线程执行 UI／Station 操作。
- **`EmailConversationStore`**：带锁、atomic JSON 的本地持久化；是反重放和线程定位的权威来源。
  附件字节单独存储，不塞进 `Config`。
- **`MailPaneObserver`**：订阅 `ShipLog` 的 `IngestOutcome`，只把已映射 pane 的允许状态边沿变为
  `OutboundMailIntent`。它不读屏，也不自行判断 agent 状态。

不修改 `ControlRouter` 的公共 interface：邮件路由使用现有 `SeahelmControlDataSource.sendText`，使本地、
MQTT 和邮件三种文本注入最终走同一条 Station 输入路径。仅新增一个窄的 pane 创建闭包给
`MailPaneRouter`，避免让 Gmail module 知道 AppKit、SplitTree 或 Station 构造细节。

## 4. 数据模型与持久化

`Config` 新增可选 `gmail_mail`，维持 `decodeIfPresent ?? nil` 的兼容模式：

```swift
struct GmailMailConfig: Codable, Equatable {
    var enabled: Bool
    var accountEmail: String                 // you@gmail.com
    var inboundAlias: String                 // you+seahelm@gmail.com；启动时校验
    var projects: [GmailMailProjectRule]     // alias → 已发现的 worktree 路径
    var pollIntervalSeconds: TimeInterval    // 30…60，默认 45
    var allowedAttachmentBytes: Int           // 单封总量上限，默认 20 MiB
}

struct GmailMailProjectRule: Codable, Equatable {
    var alias: String                         // 仅 [a-z0-9-]，规范化后唯一
    var worktreePath: String                  // 必须属于当前已发现 worktree
}
```

OAuth access/refresh token 和 PKCE 临时 verifier 不进 Config 或日志：使用 Keychain，key 按 Gmail account
稳定标识命名。断开账户时删除该 Keychain 项、`GmailMailState`、会话映射和附件目录。

`~/.config/seahelm/gmail-mail-state.json`：

```swift
struct GmailMailState: Codable {
    var syncStartedAt: Date                   // 当前运行窗口起点
    var latestHistoryId: String?
    var conversations: [String: EmailConversation] // key = Gmail threadId
    var processedMessageIds: BoundedIDSet     // 去重，有限容量/TTL
    var outboundByPaneEvent: [String: String] // pane key + ShipLog seq → Gmail message ID
}

struct EmailConversation: Codable {
    var gmailThreadId: String
    var paneSessionKey: String
    var projectAlias: String
    var worktreePath: String
    var lastInboundMessageId: String?
    var lastOutboundMessageId: String?
    var state: ConversationState              // active | closed | rejected
    var createdAt: Date
    var updatedAt: Date
}
```

附件放于 `~/.config/seahelm/mail-attachments/<threadId>/<messageId>/`。文件名由安全的 UUID 生成；原始文件名
只作展示元数据，绝不参与路径。删除 pane 或用户删除会话时，删除其对应映射与附件目录。`pane.closed`
事件把 conversation 标成 `closed`，之后的回复不重新打开 pane。

## 5. 入站流程

### 5.1 启动和同步

1. 用户在设置中完成 Desktop OAuth + PKCE；授权成功后才能启用通道。
2. `start()` 记录 `syncStartedAt = now`，从此刻建立 Gmail cursor/historyId；不扫描历史收件箱。
3. app 存活期间在专用 utility queue 每 45 秒轮询。`stop()` 取消定时器；下一次 `start()` 重置起点，
   故离线邮件不会追赶处理。
4. 轮询先使用 label/收件人查询缩小范围，再对候选调用 `messages.get(format: full)` 获取 headers、
   MIME parts 与 `threadId`。每个 message 先写入 `processedMessageIds`，再产生任何 pane 副作用。

`historyId` 只用于当前运行窗口的增量、高效去重；失效（例如 Gmail `404`）时从“现在”重建 cursor，而
不是 full resync。这是“不补处理”的直接实现，而非仅靠 UI 约定。

### 5.2 解析和授权次序

每封候选邮件按如下顺序判定，任一步失败只写审计记录：

1. Gmail message ID 不在 `processedMessageIds`；不是 Seahelm 已发送 message ID。
2. `From` 规范化后等于 `accountEmail`，`To`/`Delivered-To` 含 `inboundAlias`；拒绝
   `Auto-Submitted`、mailer-daemon 和 bulk/auto-reply 标记。
3. 如果 `threadId` 已有 active `EmailConversation`：确认 pane session 仍存在，直接进入第 5 步。
4. 否则只解析首封 subject 的精确前缀 `^\[seahelm:([a-z0-9-]+)\]\s*`；从项目规则取已验证 worktree。
   不匹配、路径未发现或 project 已禁用，均拒绝且不创建 pane。
5. 提取第一段 `text/plain`；没有纯文本时从 HTML 做保守文本化。剥离签名和 quoted reply；超长正文
   截断并标注。解析在白名单内、总量未超限的附件，写入安全目录。
6. 既有 conversation 要求目标 pane 的 `ShipLog` status 为 `waiting`；否则记录
   `pane_not_waiting` 并不注入。新线程通过 `MailPaneRouter.createPane` 创建默认 agent pane，然后投递首条文本。
7. 成功后保存 conversation、审计、附件元数据；通过现有 `sendText(paneId:text:enter:true)` 输入。

同一 `threadId` 维护一个串行队列。队列只有在输入 submit 调度完成后才处理下一条，防止
`Station.enterSubmitDelay` 使两封邮件交叉。

### 5.3 创建 pane

`MailPaneRouter` 的内部 interface：

```swift
func createPane(forWorktreePath path: String, initialText: String,
                completion: @escaping (Result<MailPaneRef, MailRouteError>) -> Void)
```

实现由 `MainWindowController`/`TabCoordinator` 提供：在已发现的 worktree 中创建一个新的持久 split leaf，
用 `Config.defaultAgent` 启动 agent，注册到 `ShipLog`，并返回稳定的 `pane_session_key` 与当前 `pane_id`。
不得复用“当前焦点 pane”或通过邮件隐式创建 Git worktree。启动成功后立即注入首条文本；启动/注册失败时不
写 conversation，邮件仅保留 rejected 审计。

这要求将现有 `TerminalCoordinator` 的“新 pane + 注册 ShipLog + 保存 split layout”组合为一个可由主窗口
调用的原子操作，而不是在 Gmail module 中复制 SplitTree 细节。

## 6. 出站流程

`MailPaneObserver` 订阅 `ShipLog` 的 outcome 流，而非订阅 viewport 刷新：

| outcome 条件 | 出站意图 |
| --- | --- |
| `newStatus == .waiting` 且状态发生迁移 | 回发 agent 的明确问题／等待输入提示。|
| `isCompletionSignal == true` | 回发 `final_message`；为空则使用安全的完成摘要。|
| `newStatus == .error` 且状态发生迁移 | 回发经截断的错误摘要。|

只有 `EmailConversation.state == active` 的 pane 可产生意图。意图键为
`pane_session_key + ShipLog.seq + kind`；在调用 Gmail send 前写入 pending 记录，收到 provider message ID
后原子地标记 sent。这样手动重试不会因 UI 重建或 EventHub 重复事件而重复发信。

发送使用 conversation 的 `threadId`、相同 subject、`In-Reply-To`/`References`，收件人为 `accountEmail`，
`Reply-To` 为 `inboundAlias`。`From` 使用已 OAuth 授权的账户。发件正文只来自 `ShipLog` 的最终消息字段，经
`MailContentRedactor` 统一截断与脱敏；绝不调用 `pane.read` 来拼装邮件。

状态进入 `waiting` 后，每个 conversation 有一个未解决的“等待回信”标记。其间重复的 waiting scan 不发信；
成功注入新邮件后清除该标记。发送失败保留 pending intent，UI 显示“发送失败／重试”，不自动重放。

## 7. 安全、不变量与可观察性

**不变量**：

1. 一个 Gmail `threadId` 最多映射一个 active `pane_session_key`；关闭 pane 后永不自动重开。
2. 只有通过所有邮件授权检查、且（既有 pane）处于 waiting 的邮件能调用 `sendText`。
3. 任一 Gmail message ID 最多影响一次本地状态；任一出站意图最多对应一封已确认的 provider message。
4. 路径、agent 命令、收件人和 pane key 只来自本地配置/注册表，绝不从邮件正文或附件取得。
5. Gmail token、MIME 原文、附件内容和可能含敏感信息的 agent 输出不写普通日志。

每次接受、拒绝、创建、投递、出站、失败都追加精简审计项：时间、hash 后的 Gmail message ID、thread ID、
project alias、pane key、判定码。设置页展示最近审计与连接状态，但不显示 token 或完整邮件。

## 8. UI 与错误状态

设置页提供：Connect Gmail、显示不可编辑的 `+seahelm` 入口、项目规则表、启用开关、连接状态、最近审计、
“断开并删除本地邮件数据”。启用前校验 Gmail 主地址、别名格式、至少一条可发现的 worktree 规则、附件上限。

状态包括 `disconnected`、`authorizing`、`connected`、`syncing`、`authorizationExpired`、`error(message)`。
授权失效立即停止轮询和出站；不尝试用过期 token 重放。Gmail 接受发送请求与实际投递需在 UI 中分别呈现；
本地只承诺“provider 已接受”。

## 9. 测试策略与验收

以 `GmailClientFake`、临时 `EmailConversationStore` 和 fake `MailPaneRouter` 做确定性单测：

- Config 向后兼容、项目别名/路径验证、入口别名规范化。
- 所有拒绝路径：错误 From/To、未知项目、无前缀、自动回复、重复 ID、关闭线程、非 waiting pane、过大或非白名单附件。
- 新线程仅创建一次 pane；相同 thread 的多封邮件严格按序；重启／cursor 失效不会处理启用前邮件。
- `waiting`、completion、error 各产生一条安全的 `OutboundMailIntent`；重复 outcome 和重试不重复发送。
- OAuth token 仅经 Keychain adapter；断开删除 token、state 与附件。

集成测试以 Gmail sandbox/测试账户覆盖 OAuth 回调、RFC 2822 thread 回复、真实 Gmail `threadId` 与 pagination；
不在常规单测中访问真实用户邮箱。UI 测试覆盖连接失败、项目规则校验、审计与手动重试。

## 10. 分阶段实现顺序

1. `GmailMailConfig`、Keychain token adapter、state/attachment store 与设置 UI 骨架。
2. `GmailClient` OAuth + 应用存活时 polling；先实现只读验证/审计，不创建或注入 pane。
3. `MailPaneRouter` 原子 pane 创建及 waiting-only 输入；完成入站 fake 与集成测试。
4. `MailPaneObserver`、MIME threading、脱敏、发送状态及手动重试。
5. 附件导入、删除联动、端到端 UI 测试与 OAuth 发布/验证准备。

每阶段保持通道默认关闭。任何阶段的失败均不扩大到“离线补处理”或“自动执行附件”。
