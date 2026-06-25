# First Mate(大副)— 舰长的参谋长设计

**日期:** 2026-06-24
**状态:** 设计已确认,待写实现计划

## 背景与定位

amux 的真正差异化不在于"又一个终端/编辑器",而在于**多 agent 的指挥能力** —— 跨 worktree 的状态聚合与监督。这正是 ghostty / wezterm / tmux 不提供的层。

围绕公司 "sea / sailor" 文化,把整个系统想象成一艘舰船:

| 比喻 | 对应 | 职责 |
|---|---|---|
| **Captain(舰长)** | 用户本人 | 决策、定方向、判断质量 |
| **Bridge(舰桥)** | 左栏总览面板 | 一眼看清全员状态、下指令的地方 |
| **First Mate(大副)** | 规则引擎(本设计核心) | 替舰长盯纪律性杂活,绿区自己干、红区请示 |
| **Sailor(水手)** | 每个 worktree 里的 agent | 在各自岗位干活的船员 |
| **Station(岗位)** | worktree | 水手的工位 |
| **Orders(航令)** | `TodoStore` / `WorktreeTaskStore` 里的任务 | 待派的任务 |
| **Watch(值更)** | A/C 通知 | 大副值班,有情况就报 |
| **Inspection(验船)** | B 跑测试 | 水手完工,大副先验一遍 |
| **Return to port(返港)** | E worktree 清理 | 任务完成,船只返港(需舰长批准入坞) |

### 设计原则:分级自治(信任边界)

上一次"舰长"构思弃用的根因:它替用户做了用户没想清楚的决定,导致不信任。解药是**分级**:

- **绿区(可逆 / 低风险)** → First Mate 直接做,做完汇报。
- **红区(不可逆 / 有成本 / 派生新工作)** → First Mate 把事情准备好,入队等舰长一键确认。

不可逆的永远要舰长点头,可逆的自己干 —— 信任成本几乎归零。

**First Mate 不做需要判断力的决策(不是全自动指挥官)。** 它只做确定性的纪律性杂活。决策权始终在舰长。

## 架构:AgentHead 之上的薄规则层

First Mate **不是新子系统**,不轮询、不检测状态。它订阅 `AgentHead`(状态真相源)的状态变化**边沿**,把边沿翻译成动作。

```
StatusPublisher → StatusDetector → WorktreeStatusAggregator → AgentHead(真相源)
                                                                   │ 状态变化 delegate
                                                                   ▼
                                                            ┌──────────────┐
                                                            │  First Mate  │  规则引擎(新)
                                                            │  evaluate()  │
                                                            └──────┬───────┘
                                                  产出 [Action]    │
                                ┌──────────────────────────────────┴────────────────────────┐
                                ▼ 绿区:立即执行                                 红区:入队等确认 ▼
                   NotificationManager / ProcessRunner                    PendingOrders(待批航令)
                   (值更通知 / 验船 / 拉 review 水手)                              │
                                                                                   ▼
                                                                    Bridge 舰桥渲染 → 舰长一键批准 → 执行
```

### 复用的现有设施

- `AgentHead` — 状态真相源 + delegate(订阅点)
- `StatusDetector` / `WorktreeStatusAggregator` / `DebouncedStatusTracker` — 状态与去抖
- `NotificationManager`(本地)+ `WeComBotChannel` / `WeChatChannel`(手机推送)
- `ClaudeHooksSetup` / `HooksChannel` / `WebhookServer` — agent 主动上报完工/事件
- `TodoStore` / `WorktreeTaskStore` / `IdeaStore` — 航令存储
- `ProcessRunner` — 执行验船命令
- `feat/new-task-auto-launch-agent` 分支的自动拉起 agent 能力 — 收进红区 D 动作

### 新增组件

1. **`FirstMate`**(`Sources/Core/FirstMate.swift`)— 规则引擎。订阅 `AgentHead`,实现 `evaluate(worktree, oldStatus, newStatus, event?)`,产出 `[FirstMateAction]`。为每个 worktree 维护"上次已处理状态",保证边沿驱动、不重复触发。
2. **`FirstMateAction`** — 动作模型,带 `zone: .green | .red`。
3. **`PendingOrdersQueue`** — 红区待批动作队列。每个 worktree 同类动作至多一条(幂等)。
4. **`FirstMateConfig`** — 配置(见下),挂到 `Config`,沿用 `decodeIfPresent`。
5. **Bridge UI** — 左栏面板的 "First Mate" tab(见 UI 章节)。

## 规则集(五类)

| 规则 | 触发边沿 | 区 | 动作 |
|---|---|---|---|
| **A 值更·等待** | 进入 `waiting/needs-input` 且持续 > `waitingTimeoutSec`(默认 30s) | 绿 | 通知(本地 + 配置的 channel),舰桥高亮 |
| **C 值更·异常** | 进入进程退出非 0 / error / 长时间无输出 | 绿 | 通知 + 升级标记(红色徽标) |
| **B 验船** | 收到完工 hook(兜底:`completed` 状态稳定持续去抖窗口) | 绿 | 跑 `inspectionCommands`(test/lint/build),结果回报舰桥;**完成后自动拉起 review 水手(只读,无副作用,故归绿区全自动)** |
| **B' 自动 commit** | 同 B | 绿·**默认关** | `autoCommit` 开启时,在该 worktree 分支 commit |
| **D 待命·派令** | 进入 `idle`(完工且无后续等待) | 红 | 若 `OrdersStore` 有该 repo 的航令 → 入队"派发下一条?";执行走 `feat/new-task-auto-launch-agent` |
| **E 返港·清理** | 任务标记完成 / 分支已 merge | 红 | 入坞前预检(未 merge / 未 push / 未提交改动 → 警告);通过才提示删 worktree |

### review 水手说明

完工后自动拉起的 review 水手是**只读**的(读 diff、给意见,不改代码),无副作用,因此从红区移入绿区·全自动。它在完工时先帮舰长过一遍,结果回报舰桥。

## 配置

`Config.swift` 新增 `firstMate` 节,沿用 `decodeIfPresent` 向后兼容:

```jsonc
"firstMate": {
  "enabled": true,
  "waitingTimeoutSec": 30,
  "autoInspect": true,
  "inspectionCommands": ["xcodebuild ... test"],   // 每 repo 可覆盖
  "autoReview": true,
  "autoCommit": false,
  "autoSuggestNextOrder": true,                      // D 是否入队提示
  "channels": ["local", "wecom"]
}
```

## UI:左栏 Bridge 面板

**方案:第一列做成 tab 面板**,折叠按钮旁加 icon 切换 **First Mate / 文件树 / changes**,默认 tab = **First Mate**。

> 演进路径:未来 worktree 侧栏 / 文件树 / changes 计划移除,届时这列自然退化为纯舰桥。

**First Mate tab 内容布局(自上而下):**

1. **待批航令(红区)** — 顶部。每条带"确认 / 否决"按钮。例:
   - `🔴 返港 docs?` [入坞] 否决
   - `🔴 派令 api → "next todo"?` [派发] 否决
2. **值更(绿区)** — 下方。只读的通知流:
   - `🟡 fix-y 等你回话 0:42`
   - `✓ api 验船通过`
   - `🔴 fix-z 进程退出(异常)`
3. 空闲(无待批、无新值更)时面板基本为空 = 一切正常。

**卡片增强(借线框 B 的细节):** sailor 卡片用左色边即时表达状态 —— 黄=等待(带计时)、绿=完工/验船通过、红=异常或待批、灰=working。

### 主内容区:每 worktree 一个 tab

主区从单一 Dashboard 改为**多 tab,一个 worktree(sailor)一个 tab**:

- 左栏舰桥 = 舰队总览 + 待批航令(全局视角);主区 tab = 钻进某条船干活(单船视角)。职责清晰分离。
- 每个 tab 标题 = sailor 名 / 分支名,带状态色点(复用卡片色边的同一套:黄/绿/红/灰),不切过去也能在 tab 条上看到哪条船要注意。
- 点左栏舰桥里的某个值更 / 待批项 → 跳到对应 worktree 的 tab。
- tab 的生命周期跟 worktree:E 返港入坞删除 worktree 时,对应 tab 关闭。
- 复用现有 `TabCoordinator`(已缓存 `repoVCs[repoPath]`、管 tab 切换与 surface 生命周期);本改动是把"项目 tab"粒度细化到"worktree tab",并与左栏舰桥的导航联动。

### 左栏舰桥交互

配合现有 vim 模态键盘(见 [[keyboard-mode-system]]),舰桥可全键盘操作:

- **j / k** — 在条目间移动焦点(待批航令 + 值更统一列表)
- **Enter** — 值更项:跳到对应 worktree tab;红区派令:执行派发;红区返港:见下确认流
- **n** — 否决当前红区航令
- **x** — 清除当前绿区值更项
- **→** — 看 diff(返港预检 / 验船结果上下文)
- 顶部 tab 切换 icon:First Mate / 文件树 / changes,紧挨折叠按钮(`‹`)

**红区确认流 — 分级(方案 C):**

- **派令(可重来)** → 一键执行:Enter 即派发下一条航令。
- **返港删除(不可逆)** → 两步:第一次 Enter 展开详情(预检结果 + 要删的 worktree 路径 + 未 merge/未 push 警告),第二次 Enter(或 `y`)才真正入坞删除。

与"绿区自动 / 红区请示"的分级哲学一致:可逆动作低摩擦,不可逆动作多一道保险。

## 边界情况(易翻车,需在实现中处理)

1. **"完成"怎么算?** 看屏会把中途停顿误判成完工。→ 优先用 hook 的明确完工信号;无 hook 时要求 `completed` 状态稳定持续去抖窗口(复用 `DebouncedStatusTracker`)才触发验船。
2. **"空闲(D)"vs"等待(A)":** 等待 = agent 主动问问题(`needs-input`);空闲 = 完工且不在等任何东西。靠 `StatusDetector` 现有状态区分,First Mate 不自己猜。
3. **红区幂等:** 同一 worktree 的"派令/返港"在队列里至多一条;不能每次状态抖动都塞一条。批准/否决后才允许该 worktree 再次入队。

## 测试策略

- `FirstMate.evaluate` 是纯函数式核心(输入状态边沿 + 配置 → 输出动作),用 XCTest 单测覆盖五类规则的触发与绿/红分区。
- `PendingOrdersQueue` 幂等性单测(同 worktree 重复入队只保留一条;批准/否决后可再入队)。
- 边沿去重单测(同状态持续不重复产出动作)。
- 配置向后兼容单测(缺 `firstMate` 节时用默认值)。

## 改名:amux → Seamux

项目从 `amux`(Agent Multiplexer)改名为 **Seamux**(sea + multiplexer):融入公司 "sea" 元素,保留 multiplexer 血脉,从 amux 平滑过渡。隐喻链不变(Bridge / First Mate / Sailor 全套照旧叠加在 Seamux 之上)。

横切改动范围(机械,建议作为独立计划线先行或并行):

- `project.yml` — target / scheme / product name(`amux` → `seamux`),regenerate Xcode project
- bundle identifier、app 显示名、Info.plist
- bridging header 文件名 `amux-Bridging-Header.h` 与引用
- 测试 target(`amuxTests` / `amuxUITests`)、`@testable import amux` → `import seamux`
- `run.sh`、`CLAUDE.md`、配置目录 `~/.config/amux/` → `~/.config/seamux/`(需读旧路径做一次迁移以兼容老用户)
- README / 文档 / logo 文案

> 配置目录迁移是唯一有数据风险的点:首次启动若新路径不存在而旧路径存在,复制旧 config 过来。

## 不做(YAGNI)

- 全自动指挥官(规则做判断、自动决策)—— 明确排除。
- First Mate 自己检测状态 —— 复用现有管线,不重造。
- 跨 repo 的航令编排 / 依赖图 —— 本期只做单 repo 内的"派下一条"。
