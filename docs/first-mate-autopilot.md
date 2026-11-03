# First Mate Autopilot

状态：设计已定，第一阶段实施中。

First Mate 从"旁观者"变成"调度者"：一个跑在专属 pane 里的 LLM agent，被确定性的触发器叫醒，用 `seahelm` CLI 和 `gh` 去查、去做；它能做什么、要不要先问你，由 seahelm 按配置强制执行，不靠 LLM 自觉。

现有的 First Mate（`FirstMate.swift` 的状态边沿规则：watchWaiting、watchError、inspect、autoCommit、suggestNextOrder…）保留不动，作为这一层下面的"反射"。本文说的 First Mate 指新的 LLM pane。

## 1. 已定的决策

| 问题 | 决定 |
|---|---|
| 几个 First Mate | **全局一个**。规则按仓库写，First Mate 看整个 fleet |
| 谁来判断 | **专属 pane 里的 LLM**（默认 Claude Code，可配置）。规则只决定"什么时候叫醒它"，做什么由它判断 |
| 规则放哪 | **仓库里的 `.seahelm/automations.yml`**，设置界面可编辑，保存写回 yml |
| 自主程度 | **可配置**，按动作分级：`auto` 直接做 / `ask` 变审批卡片 / `deny` 拒绝。由控制 socket 强制 |
| 默认值 | 给已有 pane 发消息 `auto`；新开 agent `ask`；删 worktree `ask`；合并 PR 第一批不做 |
| token 预算 | 不单独设。用全局 Claude/Codex 5h 额度阈值（`pause_above_usage`）和每条规则的 `max_attempts` 控制 |
| 能否人工跟它说话 | 能，一等功能。人工消息优先于排队的事件，但同样越不过策略 |
| 展现 | 左下角常驻条（替代快捷键条）→ 点开占右侧焦点区（和选中 worktree 一样）→ 待批准角标弹小浮层 |

第一批场景：**CI 失败自动修**、**合并后自动清理**、**高优 GitHub issue 自动推荐**。

## 2. 结构

```
触发器（Swift，确定性）  →  First Mate（专属 pane 的 LLM）  →  动作（seahelm CLI，策略把关）
 ci.failed / pr.merged          收到事件 prompt，自己查、自己判断      pane send / worktree create
 schedule（cron）              gh、seahelm pane read、git…           worktree delete / propose
                                                                     ↑ auto 直接执行，ask 变卡片
```

### 2.1 触发器

| 事件 | 来源 | 何时触发 | 带的内容 |
|---|---|---|---|
| `ci.failed` | `WorktreePRStore`（每分钟每仓库一次 GraphQL） | 某个有 worktree 的分支，其 PR 的 checks 从「非失败」变成 `failing`。只认观察到的跳变：启动时已经是红的不触发 | 仓库、worktree、分支、PR 号与链接 |
| `pr.merged` | 同上 | PR 状态变成 `merged`；启动时首次看到已合并也触发，同一个 PR 只触发一次（持久化） | 同上 |
| `schedule` | yml 里的 cron（第二阶段） | 到点 | 规则名、仓库 |

触发器只产生事件，不做任何动作。事件按规则匹配（`on` + `when`），匹配到的规则把自己的 `brief` 填好变量，交给 First Mate。

### 2.2 First Mate pane

- 一个 zmx 会话 `seahelm-first-mate`，工作目录 `~/.config/seahelm/first-mate/`，里面有：
  - `CLAUDE.md`：角色、可用命令、行为准则（seahelm 写入并在升级时更新）；
  - `standing-orders.md`：长期指令。你说"记住……"时它写进去，抽屉里可看可改，启动时读；
  - seahelm skill（已全局安装）。
- 它注册进 `AgentRegistry`（状态检测、hooks、消息时间线都照常工作），但**不是 fleet 里的一行**：fleet、`/status`、web 列表把它过滤掉，它只出现在左下角。
- **它的 shell 也有边界。** seahelm 的策略只管 seahelm CLI；一个能随意跑 shell 的 agent 可以绕过去（直接 `git worktree remove`、`gh pr merge`）。所以它不带 yolo 启动，工作目录里放 `.claude/settings.json`：只读的 `gh`/`git`、`seahelm`、读文件、改 `standing-orders.md` 免问，`git push`、`gh pr merge`、`git worktree remove`、`rm` 明确拒绝，其余一律弹 Claude 自己的权限确认——在左下角显示为"needs you"。
- 状态：它没有 split tree，由 `StatusPublisher.pin` 单独扫描（hooks 照常认得它），但不进 worktree 聚合器，所以 fleet 的通知、卡片、未看标记都不会因为它的回合而触发。
- 事件投递：它 idle 时把事件作为一条 prompt 发进去；忙时排队，下次 idle 时合并成一条。人工消息不排队，直接发。
- 上下文：会话常驻；每天或每 N 个事件开新会话（`/clear`），`standing-orders.md` 保证长期指令不丢。

### 2.3 规则：`.seahelm/automations.yml`

```yaml
first_mate:
  budget:
    max_concurrent_agents: 4     # First Mate 开出来的 agent 同时最多几个
    pause_above_usage: 80        # Claude/Codex 5h 额度超过 80% 不再新开 agent
  quiet_hours: "23:00-08:00"     # 这段时间事件只排队，不叫醒

rules:
  - name: fix-ci
    on: ci.failed
    when: { branch: "!main" }
    max_attempts: 2              # 同一个 PR 每天最多 2 次
    autonomy: { message_pane: auto, start_agent: ask }
    brief: |
      PR #{{pr}} 的 CI 失败了。用 gh run view --log-failed 看原因。
      worktree 里的 agent 空闲就让它修；它在忙就等它；没有 agent 就开一个。

  - name: cleanup-merged
    on: pr.merged
    autonomy: { delete_worktree: ask }
    brief: PR #{{pr}} 已合并。确认没有未推送的工作、pane 都空闲后，删掉 worktree。

  - name: triage-issues
    on: { schedule: "0 9 * * 1-5" }
    autonomy: { start_agent: ask }
    brief: |
      用 gh 看 label 为 P0/P1、未分配的 open issue，排除已有 worktree 在做的，
      推荐最值得做的 3 个并说明理由，用 seahelm propose 给出"开工"选项。
```

变量：`{{repo}}` `{{worktree}}` `{{branch}}` `{{pr}}` `{{pr_url}}` `{{rule}}`。

没有 yml 的仓库用内置默认规则（fix-ci、cleanup-merged，均按上面的默认 autonomy）；全局开关在设置里，默认关闭，开启后才生效。

### 2.4 动作与策略

First Mate 调用 CLI 时，请求带着 `_meta.caller = 它自己的 pane id`。控制路由认出调用方是 First Mate，就按动作类别查策略：

| 动作类别 | CLI | 默认 |
|---|---|---|
| `message_pane` | `seahelm pane run/send …`（发给别的 pane） | auto |
| `start_agent` | `seahelm worktree create --repo … --task …` | ask |
| `delete_worktree` | `seahelm worktree delete <wt>` | ask |
| `propose` | `seahelm propose …`（第二阶段，见 §4） | 永远是卡片 |

- `auto`：执行，写审计。
- `ask`：不执行，生成一张审批卡片（桌面 / Island / Telegram / web 都能批），返回 `{"queued": "approval", "card": id}`；你批了，seahelm 以 First Mate 的名义执行，并把结果作为一条消息告诉它。
- `deny`：返回错误，写审计。

策略来源：规则的 `autonomy` 覆盖全局默认。First Mate 处理某个事件期间（从投递到它下一次 idle），用触发规则的 autonomy；人工对话期间用全局默认。**人工在对话里说"直接删"也越不过 `ask`**，要改只能改配置。

护栏：`max_concurrent_agents`、`pause_above_usage`、`quiet_hours`、每条规则的 `max_attempts`、一键暂停（左下角 ⏸、Telegram `/pause`、设置开关）。暂停时事件照常记录、不投递。

### 2.5 审计

每个事件、每次投递、每个动作（含被拒、待批、批准/拒绝）写一行 JSON 到 `~/.config/seahelm/first-mate/audit.jsonl`，并：

- 出现在 First Mate 视图的时间线里；
- 自动动作推一条 Telegram：做了什么、因为哪条规则；
- 被动过的 worktree 行在状态点旁带一个 ⎈，悬停显示最近一次。

## 3. 界面

1. **左下角常驻条**（替代 `ShortcutHintBar`）：第一行状态（空闲 / 思考中 / 执行中 / 已暂停）+ ⏸；第二行最近一个动作，里面的 `#3`、`#207` 可点；右侧琥珀色角标 = 待批准数；角上一个小 `?` 打开快捷键表。
2. **点开占右侧焦点区**：和选中一个 worktree 一样，左侧 fleet 完整可见。内容是按事件组织的时间线（触发 → 判断 → 动作 → 结果），待批准卡片嵌在里面，底部输入框直接跟它说话，⤢ 切到它的真实终端。Esc 或再点一次常驻条回到之前选中的 worktree。
3. **角标浮层**：点待批准角标，只弹出待批准卡片，批完即关。
4. fleet 行上的 ⎈ 标记（见审计）。

## 4. 分阶段

**第一阶段**（打通"CI 失败自动修"和"合并后清理"）
- 1a 规则与事件：yml 解析、`ci.failed`/`pr.merged` 跳变检测、规则匹配与 brief 渲染、`max_attempts` 与已触发记录的持久化、审计日志。纯逻辑，全部单测。
- 1b First Mate pane：会话与工作目录、`CLAUDE.md`、注册但不进 fleet、事件队列与投递、左下角常驻条、右侧视图（先放真实终端 + 审计时间线）。
- 1c 策略把关：控制路由按调用方分类（只读方法放行；`pane.run/send_text/send_keys` = `message_pane`，`worktree.create` = `start_agent`，`worktree.delete` = `delete_worktree`；其余一律拒绝）、`auto/ask/deny`、预算（`max_concurrent_agents`、`pause_above_usage`）、审批卡片（Island 与 Telegram，划掉卡片 = 拒绝）、`seahelm worktree create/delete` CLI、批准后在后台执行并回告 First Mate。

**第二阶段**：`schedule` 触发与"高优 issue 推荐"，以及它需要的 `seahelm propose`（带结构化选项的推荐卡片：选中一项即视为批准该项对应的动作，不再二次询问）；设置界面编辑规则；Telegram 审批与默认对话对象改为 First Mate；右侧视图换成结构化时间线 + 输入框；角标浮层。

**第三阶段**：更多触发源（agent 跑完、review 评论、issue 标签）；每日总结。

## 5. 依赖

- yml 解析用 [Yams](https://github.com/jpsim/Yams)（MIT，SPM），不自己写 YAML 解析器。
- PR/CI 数据来自 `WorktreePRStore`（#207）。
