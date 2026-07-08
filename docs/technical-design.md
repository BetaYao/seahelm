# Seahelm 技术设计文档

> 面向新加入的工程师，帮助快速建立整体架构心智模型。
> 基于 `feat/agent-resume` 分支代码梳理，最后更新：2026-07-08。
> 旧文档（`feature-design.md` / `ui-spec.md` / `cockpit-redesign-plan.md` / `keyboard-redesign.md`）均已过时，仅供历史参考。

---

## 1. 这是什么

**Seahelm**（sea + helm，舵手）是一个原生 macOS 应用，用于**并行编排多个 AI coding agent**。它把「多仓库 / 多 worktree / 多 agent 同时推进」这件事，收进一个界面：仓库、worktree、终端 pane、agent 运行状态、git diff、通知，全部集中管理。

- **技术栈**：Swift 5.10 + AppKit（非 SwiftUI），macOS 14.0+（Sonoma），Metal 渲染。
- **终端引擎**：集成 [Ghostty](https://ghostty.org)，通过 C 绑定（`ghostty.h` + `GhosttyKit.xcframework`）渲染真实终端。
- **会话持久化**：后端使用 **zmx**（自研/打包，默认）或 **tmux**（回退），保证 pane 在 app 重启后可恢复。
- **代码编辑器**：内嵌 `CodeEditSourceEditor`（唯一的第三方 SPM 依赖，其余全是系统框架 + Ghostty）。
- **工程生成**：用 XcodeGen 从 `project.yml` 生成 `.xcodeproj`。当前版本 `MARKETING_VERSION 2.0.0`。

构建/测试命令见 `CLAUDE.md`。zmx 二进制在构建期由 `scripts/fetch-zmx.sh` 拉取并签名嵌入 `Contents/Resources/bin/zmx`。

---

## 2. 航海隐喻术语表（**先读这个**）

代码库大量使用航海隐喻。不熟悉这套词汇几乎无法读懂类名。核心映射：

| 隐喻词 | 实际含义 | 关键类型 |
|---|---|---|
| **Sailor**（水手） | 一个正在某终端里运行的 agent 或进程（Claude / Codex / npm / cargo…）。一个 pane 对应一个 Sailor。 | `SailorInfo`, `SailorType`, `SailorStatus` |
| **Station**（工位） | 单个终端会话实体 = 一个 Ghostty surface + PTY + Metal NSView。每个分屏叶子一个。 | `Station`, `StationManager`, `StationRegistry` |
| **ShipLog**（航海日志） | 所有 agent 状态的**唯一真源**（single source of truth），主键是 terminal ID。 | `ShipLog`（单例） |
| **Helm**（舵/驾驶舱） | 叠在 dashboard 上的命令输入 + AI 指挥界面（cockpit）。 | `HelmCockpitController`, `HelmOrbView` |
| **First Mate**（大副） | AI 副手引擎：观察 agent 状态迁移，产出「值守/待批」动作辅助用户。 | `FirstMate`, `FirstMateCoordinator` |
| **Order**（航令） | 一条待用户批准的下一步指令（红区）。 | `PendingOrdersQueue`, `BridgeCommand` |
| **Watch**（值守） | 需要注意的 agent 事件（等待输入 / 出错，绿区）。 | `WatchFeed` |
| **Port / ReturnToPort**（入坞） | 把一个 worktree 合并回主干并回收（"返航靠岸"）。 | `ReturnToPort`, `WorktreeDeleter` |
| **Bridge**（舰桥） | First Mate 面板 / 命令路由层。 | `BridgePanelViewController`, `BridgeCommandRouter` |

> 历史遗留：早期项目名为 **amux**（后 seamux）。会话名前缀 `amux-`、配置目录迁移逻辑、部分注释仍带此名。见 §7 兼容性。

---

## 3. 分层架构总览

四层设计，依赖自上而下：

```
┌─────────────────────────────────────────────────────────────┐
│  App 协调层  Sources/App/                                     │
│  MainWindowController(中枢) · TabCoordinator · TerminalCoord  │
│  · PanelCoordinator · UpdateCoordinator · 键盘系统            │
├─────────────────────────────────────────────────────────────┤
│  UI 层  Sources/UI/                                           │
│  Dashboard · Helm cockpit · SidePanel(编辑器/文件树/diff)     │
│  · Split · TitleBar · StatusBar · Dialog                     │
├─────────────────────────────────────────────────────────────┤
│  Core 服务  Sources/Core/ · Sources/Status/ · Sources/Usage/ │
│  ShipLog(真源) · 状态检测流水线 · First Mate · Config/Stores  │
│  · 外部渠道(WeChat/WeCom) · Usage 用量                        │
├─────────────────────────────────────────────────────────────┤
│  终端 & 系统  Sources/Terminal/ · Sources/Git/               │
│  GhosttyBridge · Station · SplitTree · WorktreeDiscovery     │
└─────────────────────────────────────────────────────────────┘
```

**贯穿全局的单例**：`GhosttyBridge.shared`（终端引擎入口）、`ShipLog.shared`（agent 状态真源）、`StationRegistry.shared`（stationId → Station 查表）、`NotificationManager.shared`、`NotificationHistory.shared`。

**协调风格**：全程 delegate 模式（不用 Combine / async-await 做 UI 更新）。`MainWindowController` 是所有协调器的 delegate 汇聚点，各协调器彼此不直接引用，一律经它中介。

---

## 4. App 协调层（`Sources/App/`）

`MainWindowController`（`MainWindowController.swift:44`）是中枢 `NSWindowController`，持有窗口、TitleBar、StatusBar、Dashboard，并 lazy 构造并连线所有协调器。

| 协调器 | 职责 |
|---|---|
| **AppDelegate** (`AppDelegate.swift:11`) | 进程级生命周期。注册字体/通知/主题、配置 CLI hooks、加载 store、自动连接 IM、`GhosttyBridge.initialize()`、创建 MWC；并定时清理孤儿 zmx 会话。 |
| **TabCoordinator** (`TabCoordinator.swift:11`) | 最大的协调器，「管状态不管视图」。workspace 加载、repo 增删、worktree 发现与集成、tab 切换、分支刷新定时器、session 状态持久化、hook 驱动的新 worktree 自动接入与 pane 转移、First Mate 巡检。 |
| **TerminalCoordinator** (`TerminalCoordinator.swift:8`) | 终端/分屏后端。持有 `StationManager`，负责 SplitTree 解析与布局持久化、split/close/move/resize/reset pane、worktree 删除与 surface teardown。 |
| **PanelCoordinator** (`PanelCoordinator.swift:7`) | 轻量壳，把通知历史面板的选择转成 `.navigateToWorktree` 通知。 |
| **UpdateCoordinator** (`UpdateCoordinator.swift:7`) | 自更新。封装 `UpdateChecker/Manager/Banner`，轮询新版本、驱动 skip/install/restart（`Sources/Update/`）。 |

### 4.1 键盘系统（vim 模态 + leader key）

键盘导航是「纯逻辑模块（App/ 内，可单测）+ UI 消费层」分离设计：

- **KeyboardMode** — 值类型：`.normal` / `.insert` 两态、substate（deletePending/createForm）、方向、动作、chord 定义。
- **KeyboardModeController** (`KeyboardModeController.swift:8`) — 模态状态机，MWC 持有。管理 mode / substate / leader 下钻路径（which-key），经 `KeyboardModeDelegate` 把 mode+hint 推给 StatusBar。
- **Keymap** — NORMAL 模式裸键 → 动作的纯查表（hjkl 移焦、i/Enter 进终端、d/c/f/n、1-9 跳卡）；INSERT 时返回 nil，键落进终端。
- **LeaderMenu** (`LeaderMenu.swift:61`) — Space 引导键的 which-key 树（split/go/window 子菜单）。
- **GlobalKeymap** — 与模态无关的窗口级 Cmd/Ctrl 快捷键（split、moveFocus、resize、切 worktree、toggleSidebar），在 `SeahelmWindow.performKeyEquivalent` 消费。
- **DialogKeymap** — 模态弹窗内统一导航（up/down/confirm/cancel），`allowVimKeys` 控制 j/k 是否当方向键。
- **Region / RegionFocusController** (`Region.swift:9`) — 定义可导航区域（panes/dashboard/sidebar/titlebar/helm）及 Tab 循环焦点。

**关键流**：`SeahelmWindow.sendEvent` 先截 Esc/Cmd+Esc → Controller 切 NORMAL 并进入 dashboard 导航；其余键查 GlobalKeymap → Keymap → LeaderMenu，命中后回调协调器执行。

**辅助器**：`BackendResolver`（异步探测 zmx/tmux，回退 zmx→tmux→local）、`DialogPresenter`（集中 present 各种 sheet）、`MenuBuilder`（纯函数构建 NSMainMenu）。

---

## 5. 终端 · 分屏 · 会话持久化（`Sources/Terminal/`）

### 5.1 Ghostty 封装
`GhosttyBridge`（`GhosttyBridge.swift:5`，单例）封装整个 Ghostty 运行时：`initialize()` 做 `ghostty_init` → 加载 `~/.config/seahelm/ghostty.conf` → `ghostty_app_new`；`wakeup_cb` 派回主线程 `tick()` 驱动事件循环；`action_cb` 把标题/通知/搜索等 action 转成 NotificationCenter 通知供 UI 订阅。

### 5.2 Station = 单终端会话
`Station`（`Station.swift:11`）= 一个 Ghostty surface + PTY + Metal 渲染 NSView，每个分屏叶子一个。持有 `sessionName`、`backend`、`agentSessionRef`。
- `StationRegistry`（单例）：`stationId → Station` 全局查表。SplitNode 只存 id，实体在此查。
- `StationManager`：按 worktree path 管理 `SplitTree` 生命周期（get-or-create、restore、销毁、`transferTree` 跟随路径迁移）。
- **reparent 机制**：`reparent(to:)` 把 view 在容器间搬移，`CATransaction` 禁动画，需 2~3 次 deferred 主线程 pass（先让约束出 frame，再让 Ghostty 重算网格，最后读网格尺寸）。
- **GhosttyNSView** 是 `NSTextInputClient`，处理 IME/组合输入；`performKeyEquivalent` 仅 focused view 响应（避免多 pane 粘贴串台）；`setFrameSize` 带 debounce 尺寸同步。

### 5.3 分屏数据结构
- `SplitNode`（indirect enum）：`.leaf(id, stationId, sessionName)` 或 `.split(id, axis, ratio, first, second)`。纯函数式操作（replacing/removing/updatingRatio）。`CodableSplitNode` 是可序列化镜像（仅 sessionName + axis/ratio），用于持久化。
- `SplitTree`：按 worktree 持一棵树 + `focusedId`。`restore(from:)` 重建时为每叶新建 Station 并注册。
- `SplitContainerView`（`SplitContainerView.swift:20`）：递归按 axis/ratio 切矩形做 frame 定位，插 `DividerView` 拖拽把手，非 focused pane 加 `DimOverlayView` 暗化（hitTest 穿透）。**关键**：`layoutTree()` 把 `station.delegate` 重新指向当前容器，保证恢复的 surface 不成孤儿 pane。

### 5.4 会话后端（zmx / tmux）
- **命名**：`amux-<parent>-<name>`（点/冒号转下划线，超 40 字符截断 + 6 位哈希）；附加 pane 加 `-<index>` 后缀。
- **选择**：`BackendResolver` 优先 zmx（要求版本 ≥ 0.4.2），回退 tmux，再回退 local（纯 shell 无持久化）。
- **健康检查/恢复（zmx 专属）**：attach 后 3s 检查，**仅看 attach 进程是否退出**（刻意不看 viewport 是否空，避免误杀刚起的正常 shell）；需恢复时后台强杀会话（graceful kill → 确认 → lsof 找 daemon SIGKILL → 删 socket），必要时用 agent resume 命令 reseed，再主线程重建 surface。
- **孤儿清理**：只 reap `clients=0` 且可达的 `amux-` 会话（防误杀在用会话）。
- `ZmxLocator` 是 zmx 路径唯一来源（bundle 优先，dev 回退 PATH）；`TmuxChannel`/`ZmxChannel` 实现 `SailorChannel`，作为对任意 agent 的**通用回退通道**（send-keys 注入 / capture-pane 读屏）。

### 5.5 线程安全模型
`Station.ghosttyLock`（NSLock）串行化对同一 surface 的跨线程 C 调用——冲突方是**后台状态轮询**与**主线程输入**。要点：`readViewportText` 只在锁内做 C 调用+原始字节拷贝，String 构建移到锁外；**键盘输入刻意不持锁**（`ghostty_surface_key` 可能同步回调导致重入死锁，且 Ghostty 键输入本身线程安全）。

---

## 6. Agent 状态检测流水线（`Sources/Status/` + `Sources/Core/`）

这是 Seahelm 的心脏：把「屏幕上在跑什么」变成结构化、可导航的状态。

### 6.1 五路状态来源

| 来源 | 负责文件 | 说明 |
|---|---|---|
| Viewport 文本扫描 | `StatusPublisher` + `ScanDecoder` + `StatusDetector` | 2s 轮询读屏，正则匹配 agent 规则 → `scanStatus` |
| OSC 133 shell phase | `OSC133Parser` | 解析 A/B/C/D 转义得 prompt/input/running/output 相位（优先级 2，权威于文本） |
| 进程退出 | `Station.processStatus` → `ProcessStatus` | exited/error 覆盖一切（优先级 1） |
| Webhook（通用 HTTP） | `WebhookServer` → `WebhookEvent` → `WebhookStatusProvider` | 外部 agent POST 事件 |
| Hooks（Claude/Codex 原生） | `WebhookServer` + `HookDecoder` + `HooksChannel` | 原生 hook payload 解析成同一 `WebhookEvent` |

`StatusDetector.detect` 明确降级顺序：**ProcessStatus > OSC133 > 文本规则 > unknown**；状态优先级 `error > exited > waiting > running > idle > unknown`。

### 6.2 轮询 / 聚合
- `StatusPublisher`（`StatusPublisher.swift`）：`Timer` 每 2s 后台 `pollAll`。优化：viewport djb2 哈希缓存跳过未变更 pane；**preferred worktree（当前 tab）每轮扫，其余每 3 轮抽样**。每 terminal 一个 `DebouncedStatusTracker`（unknown 不改现状）。
- `WorktreeStatusAggregator`（主线程）：把多个 pane 的 `PaneStatus` 聚合成一个 `WorktreeStatus`，维护 terminal↔worktree 映射与 `lastActivityAt`，变更回调 `WorktreeStatusDelegate`。

### 6.3 Webhook / Hooks 接收链
`WebhookServer`（`Network.framework`，只监听 loopback，`POST /webhook`）→ `WebhookEvent.parse`（区分通用 payload 与原生 hook payload；15 种事件类型）→ `WebhookStatusProvider`（按 `sessionId` 维护会话态，把 cwd 映射到已知 worktree，解析 TaskCreate/Update 成任务列表，触发新 worktree 发现）。`StopHookResponder` 为 Claude Stop hook 返回 `{"decision":"block"}` 反向触发 agent 调用 `seahelm-suggest` 生成候选下一步。

### 6.4 状态合成中枢：ShipLog.ingest
所有来源最终汇入 `ShipLog.ingest(NormalizedEvent)`（`ShipLog.swift:167`，唯一写入口）：`.screenObserved` 写 `scanStatus`，hook 事件写 `hookStatus`，最终 `status = 取高优先级([scanStatus, hookStatus])`。产出 `IngestOutcome` 到主线程分发。`SailorReducer` 是被调用的纯函数（旧快照 + 输入 → 新快照 + 是否变更，无 IO 可单测）。

### 6.5 通知流
- `NotificationManager`：门控——只在 `running → waiting/error/idle` 转换且 30s 冷却内不重复；聚焦 pane 或 app frontmost 时抑制系统横幅但仍入历史；点击导航到对应 worktree/pane。
- `NotificationHistory`：应用内历史（最多 100 条，unread 计数）。
- `WatchFeed`：主线程「绿区」观察 store（最近 20 条 watchWaiting/watchError），供侧栏 First Mate 与 Helm cockpit 订阅。

### 6.6 端到端数据流
```
读屏(2s轮询) ──ScanDecoder──┐
OSC133 / ProcessStatus ─────┴─ StatusDetector → NormalizedEvent(.screenObserved) ─┐
外部 agent ─HTTP→ WebhookServer → WebhookEvent ─┬─ WebhookStatusProvider          │
                                               └─ HookDecoder → NormalizedEvent(.hook) ┤
                                                                                       ▼
                     ShipLog.ingest  →  合成 status(scan ⊕ hook 取高优先级)  →  SailorInfo
                                                                                       │ IngestOutcome (主线程)
   ┌───────────────────────────────────┬───────────────────────────────────────────┘
   ▼                                   ▼
WorktreeStatusAggregator(pane→worktree)   NotificationManager(门控/冷却)
   │ delegate                              │
   ▼                                       ▼
UI 卡片 / 侧栏                    NotificationHistory · macOS 通知 · WatchFeed → First Mate
```

---

## 7. Worktree · Git · 配置持久化（`Sources/Git/` + `Sources/Core/`）

### 7.1 Worktree 生命周期
- `WorktreeDiscovery`：跑 `git worktree list --porcelain` 解析（**第一条永远是 main worktree**，全程用这条判定主 worktree，而非 `--show-toplevel`）。所有 git 调用经 `runWithTimeout`（5s）包裹——防止失效的可移动卷让 git 卡在内核 I/O 导致启动挂死。`findRepoRoot` 用 `rev-parse --git-common-dir`。
- `WorktreeCreator`：worktree 建在 `<repo>-worktrees/<branch>/`；`git worktree add -b`（分支已存在则回退无 `-b`）；`branchName(fromTaskDescription:)` 生成 `task/<slug>`；best-effort 复制 `.env*`；写 `SuggestGuidanceWriter`（CLAUDE.md/AGENTS.md 托管块）。
- `WorktreeDeleter`：拒删 main worktree；`git worktree remove`；`mergeCheckForOnlineMainOrMaster` 用 `merge-base --is-ancestor` 或 `log --cherry-pick` 判断是否已并入远端主干；`cleanMergedWorktrees` 批量回收。
- `GitDiff`：纯 diff 引擎，汇总 staged + unstaged + untracked（合成 diff，跳过二进制/>128KB），手写 parser 产 `DiffFile/DiffHunk/DiffLine`；`parsePorcelainStatus` 产变更文件列表。

### 7.2 Agent resume（`feat/agent-resume` 分支重点）
当 backend 会话被重建（zmx 恢复 / app 重启 / restore 进缺失会话）时，希望带 agent 自身的 resume 标志重启，而非退回裸 shell。
- `AgentSessionRef`（`AgentSessionRef.swift`）：持久化的 agent 原生 session 引用。**session id 当数据、绝不当 shell 文本**，类型边界即校验（非空、≤128、仅 `[A-Za-z0-9_-]`）；decode 时也重校验防手改 config 注入。表驱动 `resumeArgv`：claude → `claude --resume <id>`，codex → `codex resume <id>`。由 hook 事件填充进 `Config.agentSessions`。
- `SessionTitleLookup` 读 Claude `~/.claude/projects/.../<id>.jsonl` 的 summary；`CodexSessionPromptLookup` 遍历 `~/.codex/sessions` 取最后 user_message。
- `ReturnToPort`：入坞预检（未 merge/未 push/未提交），输出中文风险提示。
- `PendingWorktreeTransfer`：记录 WorktreeCreate hook 到后续 discovery 之间的「转移意图」（TTL 30s，按路径末段匹配消费）。

### 7.3 配置与 Store
- `Config`（`Sources/Core/Config.swift`）：`~/.config/seahelm/config.json`，snake_case。**向后兼容**：全字段 `decodeIfPresent ?? 默认`；`backend=="tmux"` 迁移为 `"zmx"`；`agentDetect` 合并新增默认 sailor 规则。**目录迁移**：首次启动把 `~/.config/seamux`（否则 `~/.config/amux`）整目录 copy 进 `seahelm`，保留旧目录供回滚。`save()` 防抖 0.3s、atomic、sortedKeys。含 `agentSessions`、`splitLayouts`、`worktreeStartedAt/LastActivityAt` 等。
- 其余 Store 均为 `~/.config/seahelm/` 下 JSON + NSLock + 后台 atomic 写：`WorktreeTaskStore`（worktree → 任务描述）、`WorktreeSailorTypeStore`（worktree → agent 类型）、`WorktreeTitleCache/Resolver`（标题优先级：Claude summary → task 描述 → 最后 user prompt → branch）、`IdeaStore`、`TodoStore`、`NotificationHistory`。
- `WorkspaceManager`：纯内存管理打开的 repo 标签页（去重、同名 repo 加父目录前缀消歧）。
- `PathProbe`：超时保护的 `fileExists`（**超时一律视为"存在"**，避免因盘临时不可达误删用户 workspace）。`ProcessRunner` 经登录 shell（`bash -lc`）解析 PATH；`ShellEscape` 单引号转义构造发给 tmux/zmx 的命令。

---

## 8. UI 层 · Helm 指挥 · 外部集成（`Sources/UI/` + `Sources/Core/` + `Sources/Usage/`）

### 8.1 Dashboard
`DashboardViewController`（`DashboardViewController.swift:1`）中心模型 `SailorDisplayInfo`。当前主布局为 **left-right**：左侧可折叠 mini card 栈 + 右侧大 focus panel；键盘导航时进入 D-state 焦点环。
- `FocusPanelView` — 承载终端的大面板，聚焦时画 accent 描边+阴影。
- `MiniCardView` — sidebar 紧凑卡（标题/状态点/时长/repo badge/branch/tasks/activity）。
- `StackedMiniCardContainerView` — 包裹 mini card，支持点击与拖拽重排，多 pane 显示 ghost 堆叠。
- `SailorCardView` — 完整卡片（gallery/grid 用），含任务列表渲染。
- `DashboardFocusController` — 纯值逻辑焦点环（bigPanel / card(id)，next/prev/move/jump），与 AppKit 解耦。

### 8.2 Helm cockpit（命令输入 + AI 指挥）
`HelmCockpitController`（`HelmCockpitController.swift:20`）是叠在 dashboard 上的全屏 click-through overlay，底部中央浮动：
- `HelmOrbView` — 雷达球，单一入口，点击开合命令中心；右上角脉冲 badge 显示待批航令数。
- `CommandInputView` — 命令行 `› __ / 命令 · @ 仓库 · # agent`，autocomplete 下拉。
- `HelmFloatingCard` — cockpit 关闭时新 order/watch 到达的瞬时通知卡（倒计时自动消失）。
cockpit 复用 `BridgePanelViewController` 渲染 Orders(红区待批) + Watch(绿区值守)。

### 8.3 First Mate（AI 大副）与命令系统
- `FirstMate`（`FirstMate.swift:15`）：纯引擎，输入状态迁移，输出 `FirstMateAction`（watchWaiting/watchError/inspect/autoCommit/suggestNextOrder/returnToPort/broadcastOrder；zone: green/red）。`FirstMateConfig` 配开关。`FirstMateCoordinator` 接收迁移边——绿区→副作用闭包，红区→ `PendingOrdersQueue`。
- 命令两条链：`BridgeCommand`（内部指令枚举 + `BridgeCommandParser` 纯解析 + `BridgeCommandRouter` 路由到闭包）；`CommandParser`（解析外部渠道来的 slash 命令，如 `/idea ...`）。

### 8.4 SidePanel
`WorktreeSidePanelViewController` 四 tab：firstMate / files / changes / worktrees。
- `CodeEditorView` — 基于 `CodeEditSourceEditor`（SwiftUI）；`CodeEditorModel` 管 dirty/save/预览切换。
- `FileTreeOutlineController` — outline 文件树 + FSEvents 实时同步外部改动。
- `DiffReviewView` — diff 审查 + `DiffSyntaxHighlighter`。
- `MarkdownPreviewView` — WKWebView 预览（无依赖 `MarkdownHTMLRenderer`）。
- `BridgePanelViewController` — First Mate tab（红区 orders + 绿区 watch，键盘 j/k/1-9/n/x）。

### 8.5 外部集成
`ExternalChannel` 协议（channelId/type/onMessage/send/connect/disconnect）+ `InboundMessage`/`OutboundMessage`。
- `WeChatChannel` — 个人微信，iLink HTTP 长轮询，per-user context_token。
- `WeComBotChannel` — 企业微信智能机器人，WebSocket 长连接，req_id 映射被动回复，自动重连。
两者用 `GatewayStateMachine` 管连接态，消息汇入 `ShipLog`。

### 8.6 Usage 用量统计（`Sources/Usage/`）
`UsageSummaryStore` 定时（默认 60s）刷新两 provider（带 10min 缓存回退），`onUpdate([PrimaryCapsuleFrame])` 驱动 UI 胶囊。`ClaudeUsageSummaryProvider` 读 Claude statusline 缓存拿 rate limit + 聚合当日 token；`CodexUsageSummaryProvider` 经 app-server 读 rate limit。

### 8.7 关键数据概念
- `ShipLog`（单例）：agent 信息唯一真源（主键 terminal ID），`onOutcome` 输出 `IngestOutcome` 事件流。
- `PendingOrdersQueue`：红区待批航令队列，(worktreePath,kind) 幂等去重，token 化 observer（sidebar 与 cockpit 共享观察）。
- `ActivityEvent` / `ActivityEventExtractor`：从 `WebhookEvent` 提取 agent 工具调用（tool/detail/isError/timestamp），供卡片显示活动流。
- `IdeaStore` / `TodoStore`：JSON 持久化的想法/待办，源自外部渠道 slash 命令。

---

## 9. 跨层关键设计约束（一定要知道）

1. **ShipLog 是 agent 状态的唯一写入口**——不要在别处直接改 SailorInfo，一切经 `ShipLog.ingest(NormalizedEvent)`。
2. **ghosttyLock 保护 surface C 调用，但键盘输入不持锁**——改动输入路径要理解 §5.5 的死锁约束。
3. **git 与 fileExists 都有超时保护，且超时倾向"保守假设存在"**——目的是绝不因失效挂载误删用户数据（§7.1、§7.3）。
4. **main worktree 判定一律用 `git worktree list` 首行**，不用 `--show-toplevel`（后者在 linked worktree 返回自身路径，会污染 workspace）。
5. **zmx 恢复只看 attach 进程退出，不看 viewport 是否空**——避免误杀刚起的正常 shell。
6. **Config 全字段 decodeIfPresent**——加新字段务必给默认值，保持向后兼容。
7. **纯逻辑与 AppKit 分离**——键盘系统、FirstMate、SailorReducer、DashboardFocusController 都是可单测的纯值逻辑；副作用留在协调器/UI。测试见 `Tests/`（跳过较慢的 `seahelmUITests`）。

---

## 10. 从这里继续

- 想改**终端/分屏**：从 `TerminalCoordinator` + `Station` + `SplitContainerView` 入手。
- 想改**agent 状态/通知**：从 `StatusPublisher` → `ShipLog` → `NotificationManager` 这条链入手。
- 想改**worktree 创建/回收**：`WorktreeCreator` / `WorktreeDeleter` / `ReturnToPort`。
- 想改**AI 指挥 / 命令**：`Helm cockpit` + `FirstMate` + `BridgeCommandRouter`。
- 想加**新 agent 类型的 resume**：扩展 `AgentSessionRef.resumeArgv` 与 `SailorType.detect`。
- 详细构建/测试命令与四层职责速览：见仓库根 `CLAUDE.md`。
