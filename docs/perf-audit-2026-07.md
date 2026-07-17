# 性能审查与修复记录（2026-07-17）

对 Seahelm 的全面性能审查（重点 UI 交互路径），分三个方向并行审查：主线程阻塞、
布局/渲染、状态轮询管道。本文记录全部发现、修复方式与对应提交，以及有意搁置的
条目和理由，供后续回归排查参考。

## 修复总览（按提交）

### `109aa17` perf: fix main-thread stalls and UI interaction hot paths

| 问题 | 修复 |
|---|---|
| 拖分割条时每个 mouse 事件都同步 resize 所有 Metal 终端面（`SplitContainerView` 设 frame → `GhosttyNSView.syncSurfaceSize` → `ghostty_surface_set_size`+`refresh`，无节流） | `syncSurfaceSize` 合并到 ~30Hz：节流窗口内的调用延迟一次性应用最新 bounds；reparent/重置后的首次同步（`lastSyncedSize == .zero`）绕过节流立即执行 |
| 聚焦终端的层阴影无 `shadowPath`，Core Animation 从持续重绘的 Metal 内容推导阴影（离屏渲染） | `applyFocusVisualState` 与 `setFrameSize` 显式设置 bounds 矩形 `shadowPath` |
| 删除 worktree 确认框前主线程同步跑 `hasUncommittedChanges` + `findRepoRoot`（git 子进程，最坏 5s） | `TerminalCoordinator.confirmAndDeleteWorktree` 改为后台执行 git、回主线程弹 sheet |
| 新分支对话框切 repo 下拉时主线程同步 `git branch -a` | `NewBranchDialog.loadBranches` 后台加载 + 代数守卫丢弃过期结果 |
| 聊天 `/remove` 的脏检查在主线程同步跑 git | 后台执行，回主线程回复/删除 |
| `handlePaneStatusChange` repo-root 缓存未命中时主线程同步 `git rev-parse` | 冷路径异步解析后回填缓存再投递通知；命中路径不变 |
| `ShipLog.sendCommand` fallback（pane 无存活 surface）在调用线程同步跑 zmx/tmux 子进程 | channel 发送移到后台队列 |
| island `refreshIsland` 每 2s 对 `@Observable` model 无门控赋值 → SwiftUI 每 tick 重算 body | `primaryEntry`/`unreadCount`/`recentNotifications` 全部相等性门控；`recentNotifications` 从视图计算属性改为 model 存储快照（不再每次 body 求值 filter 全量历史） |
| `ClosedPillView` 每个 waiting tile 各自一个 `repeatForever` 脉冲动画（最多 6 个并发） | 合并为 pill 级单个共享动画，相位传给各 tile |

### `4329b4e` perf: cut status-pipeline amplification into the UI

| 问题 | 修复 |
|---|---|
| `buildSailorDisplayInfos` 每个 worktree 对全表 `agents.filter` + `allWorktrees.first(where:)`（O(N²)），单 worktree 状态变化也全量跑 | 循环前一次性建 `agentsByWorktree` / `worktreeInfoByPath` 索引（O(N)） |
| 同一路径对每个 worktree kick 一次 `WorktreeGitStatsCache.refresh`（fan-out） | 新增 `changedWorktreePath` 参数：单 worktree 状态变化只刷新该 worktree，其余读 8s 缓存；全量重建（nil）行为不变 |
| `ShipLog.ingest` 无条件 `notifyObservers`——活跃 pane 因 OSC spinner 每 2s bust viewport 哈希，即使无可渲染变化也强制 main hop + delegate fan-out + EventHub publish | 仅对 `.screenObserved` 事件门控：状态未变且全部可渲染字段（message/prompt/commandLine/roundDuration/tasks/activity/agentType/scan/hook）相等时丢弃；hook/生命周期事件为边沿信号始终通知（`ActivityEvent`、`TaskItem` 补 `Equatable`；EventHub 环形缓冲按值存 seq，跳号安全） |
| island 独立 2s 定时器全量重算，与 StatusPublisher 并行轮询同一 ShipLog | 改推送驱动：worktree 状态变化挂 `tabCoordinatorRequestUpdateTitleBar`，通知变化订阅 `.notificationHistoryDidChange`，pendingOrders 观察者保留；定时器放宽为 10s 兜底 |
| `pollAll` 每个变化帧跑两轮检测：`ScanDecoder.decode()` 全套 manifest 评估 + 额外一次全屏 `lowercased()`，其 status 结果最终被丢弃（入库用 debounce 后的 `committedStatus`），唯一被消费的是 activity 列表 | 移除冗余 decode，直接 `detector.extractActivityEvents(from:)`，事件在 tracker 更新后一次构建；检测语义不变，`ScanDecoder` 类型保留（测试在用） |

### `0ec10df` perf: reuse notification history cells and share the time formatter

通知历史列表滚动时每个可见行重建整棵 cell 视图树并新建一个 `DateFormatter`
（构造极贵）。改为 `NotificationCellView` 一次构建子视图 + `makeView(withIdentifier:)`
复用 + `configure` 重配置；`DateFormatter` 共享静态实例。

### `b011fe4` fix: deterministic island row order

island 行排序只按 branch 字典序，多个 `main` worktree 之间无次级键，加上字典遍历
顺序随机 + Swift sort 不稳定，每次刷新重排（用户可见的"排序跳变"）。改为
branch → project → worktreePath 三级排序。

### `76b3c1b` fix: surface the agent's final message in notifications

通知 body 取值顺序原为 lastUserPrompt → lastMessage；prompt 为空的 pane 显示 hook
占位标签 "Processing prompt"。改为 agent 最终回复（Stop hook 的
`lastAssistantMessage`，从 ShipLog 按 pane 取）→ prompt → 扫描消息，与 island
agent 行逻辑一致。

### `67046a5` feat: dismiss button on island suggestion cards

（非性能项）suggestion 卡片右上角加关闭按钮，`pendingOrders.resolve(id:)` 直接消掉。

### `e4f40ca` perf: low-priority cleanups

- `SailorDef` 规则/skip-pattern 小写结果按 def 名缓存（与源规则比对校验，config
  热重载改规则自动重算；`SailorRule` 补 `Equatable`）。仅影响 legacy（无 manifest）pane。
- `FileContentView` 后台读文件、主线程装配（慢速/网络卷不再卡 UI；1MB 上限不变）。
- `Station.reparent` 过期注释修正（声称两次 deferred pass、实际一次）。

## 审查中确认健康、无需修改的

- `StatusPublisher` 轮询在后台 `pollQueue`；`readViewportText` 锁内只做 C 调用 +
  原始字节拷贝，String 解码在锁外。
- 分割条拖动只在 `dividerDidEndDrag` 保存布局；`Config.save` 有 300ms 去抖 +
  utility 队列原子写。
- `resizeSubviews` 走轻量 `applyFramesOnly`，不重建视图树。
- `WorktreeStatusAggregator`/`ShipLog` 各状态更新入口均有 changed 门控。
- `WorktreeDiscovery.discoverAsync` 后台 + 5s 超时；branch 刷新对后台 tab 抽稀。
- orphan 清理（`AppDelegate`/`MainWindowController`）均已在后台队列。

## 有意搁置的条目（及理由）

| 条目 | 理由 |
|---|---|
| `Config.save` 用 `.prettyPrinted` 全量编码整份 config；last-activity 高频字段与整份 config 同写 | 文件是用户可手编 JSON，去 pretty 损害可读性；写盘已去抖且在 utility 队列，主线程零成本。高频字段拆分参见 `WeChatSessionStore` 注释的已知问题，属结构性改造 |
| 文件树展开的同步 `contentsOfDirectory`（`FileTreeOutlineController`） | `NSOutlineView` 数据源是同步 API，异步化重构量大、收益小（单目录非递归，仅网络卷慢） |
| tab/预览切换全量重建 `surfaceViews` + `DashboardViewController` 预览路径 | 该文件正被并行开发大幅重构（view-mode 改造），现在动必然冲突；且已有去抖缓解 |
| `OpenedSurfaceView` 三个整体 `.animation(value:)` | model 赋值已全部相等性门控，无变化时 body 不再重算，动画 diff 不再被轮询触发 |
| `ghosttyLock` 内整屏 `ghostty_surface_read_text` | 已是锁内唯一重活，String 构建已移锁外；进一步优化需 Ghostty API 支持增量读取 |

## 已知的既有测试失败（与本次修复无关，验证过 HEAD 版同样失败）

- `StationReparentTests.testPerformKeyEquivalent_CommandVInvokesPasteAction`
- `TabCoordinatorTests.testEphemeralRepoPathsAreNotAutoAdded`

## 版本

- v2.0.8：包含 `109aa17`、`4329b4e`、`0ec10df`（性能主体）。
- `b011fe4` 及之后的修复截至本文撰写尚未发布（待 v2.0.9）。
