# 命令系统重新设计

状态：已实施（`Sources/Core/Command/`），旧动词别名保留一个版本。针对桌面 Helm 输入框、Telegram、邮件三个入口共用的命令语言。

实现与提案的差异：`/return` 不带参数时不走 `/yes`，而是像以前一样每个 worktree 出一张审批卡；桌面上的 `/integrate` 被本地改动卡住时由报告卡片提供"丢弃并重跑"，不再额外弹 sheet；`ParsedLine` 是提案里 `CommandLine` 的实际名字（后者和 Foundation 撞名）。
`seahelm` CLI（控制 socket）不在范围内，它是给 agent 用的程序接口，只要求名词一致。

## 1. 现状的问题

| # | 问题 | 现在的表现 |
|---|---|---|
| 1 | 同一句话在不同入口意思相反 | 桌面 Helm 输入框里的裸文本 = 新建 worktree 并派 agent；Telegram 里的裸文本 = 发给当前 agent |
| 2 | "当前"是隐式的，而且跨设备共享 | 手机上 `/pane #3` 会改桌面 dashboard 的选中；桌面点一下，手机下一句话就发到别处。手机上看不到当前是谁 |
| 3 | 编号是位置不是身份 | `#2` 指上次列表的第二行，舰队一变就漂。桌面 `/pane` 列当前 worktree，聊天 `/pane` 列全舰队，同一个 `#2` 两边指向不同 pane |
| 4 | 两套解析器，两份帮助 | 舰队动词在 `BridgeCommandParser`，`/status` `/idea` `/help` 在 `CommandParser` 靠 fallthrough 兜底；`/help` 字符串和 `MailSignature.entries` 已经不一致（邮件那份没有 `/integrate` `/feedback`） |
| 5 | 动词过载 | `/worktree` 干四件事；`/return` 靠名字解析到的是仓库还是分支来决定删 worktree 还是移除仓库，"撞名仓库优先" |
| 6 | 读操作有副作用 | `/pane #n` 是看一眼，但顺手把它设成当前 |
| 7 | 确认机制因入口而异 | 桌面 `/broadcast` 进红区卡片等审批，聊天里直接群发；`force` 是聊天专用的后缀 hack，`/integrate` 里又是另一套 token |
| 8 | `@` 和 `#` 语义混用 | `#` 既选 worktree 又选 pane；`@` 在 `/worktree` 里是仓库、在 `/return` 里是仓库或分支；`#`/`@` 前缀还可以互换 |

根因只有两个：**没有"会话"这个概念**（所以借用桌面选中当"当前"），**没有稳定的身份**（所以用位置当编号）。其余都是这两条的后果。

## 2. 设计原则

1. **一套语法，一个解析器，一份帮助来源。** 动词表是数据（`CommandSpec`），解析器、帮助文本、Helm 自动补全、邮件签名都从它生成。
2. **同一句话在哪个入口都是同一个意思。** 入口只决定"能不能弹 sheet"、"能不能开文件选择器"，不决定语义。
3. **每个入口有自己的会话，会话里记着"在跟谁说话"。** 桌面的会话就是 dashboard 选中；一个 Telegram chat 是一个会话；一个邮件线程是一个会话。互不影响。
4. **身份稳定，位置不进语法。** pane 有一个终身不变的编号，worktree 和仓库用名字。
5. **读不改状态，写必回显目标。** 看是看，绑是绑；每条改了东西的回复都带上改了谁。
6. **危险操作在哪个入口都要确认，确认方式随入口。** 桌面弹 sheet，聊天回 `/yes`。

## 3. 身份与寻址

两个前缀，各管一类东西，不再互换：

| 前缀 | 指什么 | 例子 | 解析 |
|---|---|---|---|
| `#` | **pane**，稳定编号 | `#7` | 只查 `PaneHandleRegistry`，不查别的 |
| `@` | **地点**：worktree 或仓库，按名字 | `@main`、`@seahelm/main`、`@seahelm` | 每个动词声明自己接受哪一类，所以没有"撞名谁优先"的规则 |

**pane 编号**：`PaneHandleRegistry` 在 pane 第一次出现时分配下一个整数，按 `paneSessionKey`（即 `SEAHELM_PANE_ID`）持久化到 `~/.config/seahelm/pane-handles.json`，永不复用。桌面的 pane 行也显示这个编号，所以你在卡片上看到的 `#7`、`/status` 里列出的 `#7`、Telegram 里敲的 `#7` 是同一个东西。

**worktree**：`@branch`；多个仓库有同名分支时用 `@repo/branch`，列表里遇到歧义会直接以长形式打印。

**仓库**：`@repo`（目录名）。

## 4. 会话与绑定

`CommandSession` 是每个入口自己的状态：

```
key            "desktop" | "telegram:<chat_id>" | "mail:<thread_id>"
bound          绑定的 pane（按 paneSessionKey 存，pane 关了绑定自动失效）
pending        待确认的动作（60 秒过期）
```

- **桌面**：会话 = dashboard 选中。`/go` 就是切选中。这是唯一能看见"当前"的入口，所以它的绑定就是它的选中。
- **Telegram**：一个 chat 一个会话，私聊和群各自独立。`/go` 只改这个 chat 的绑定，**不动桌面**。
- **邮件**：一个线程一个会话（现在的 `EmailConversationStore` 并入同一个 `CommandSessionStore`，`commander` 字段保留）。

裸文本发给 `bound`。未绑定时：
- 如果全舰队只有一个 pane，自动绑上并在回复里说明；
- 否则回复 "还没在跟哪个 pane 说话。`/status` 看一眼，`/go #7`，或者 `/new <任务>`"。

`/new` 创建成功后自动绑定到新 pane，`/go` 显式绑定。除这两个动词外没有任何命令会改绑定。

通知：agent 完成的通知仍发到 Telegram 的默认 chat；此外，凡是绑定了那个 pane 的会话（某个群、某个邮件线程）也各收一份。

持久化：`~/.config/seahelm/command-sessions.json`。

## 5. 语法

裸文本：发给绑定的 pane。每条命令在桌面 / Telegram / 邮件 / First Mate 各自的支持情况见 `docs/command-surfaces.md`。

| 命令 | 作用 | 确认 |
|---|---|---|
| `/new [@repo] <任务>` | 新建 worktree，派 agent，绑定到它。不写 `@repo` 用第一个仓库 | |
| `/go #pane` / `/go @worktree` | 绑定到这个 pane（或该 worktree 的 pane）。桌面上等于选中 | |
| `/show [#pane]` | 看 pane 的最近输出和活动。不带参数看绑定的那个。**不改绑定** | |
| `/order #pane <文字>` | 给某个 pane 发一次，不改绑定 | |
| `/broadcast <文字>` | 给所有 pane 发 | 是 |
| `/status [worktrees\|repos]` | 列表。默认列 pane，按仓库/worktree 分组，带编号、状态、标题，标出绑定的那个 | |
| `/return` | 收工所有 worktree：没东西可交付的直接删，其余列出各自的计划 | 否 |
| `/return @worktree` | 收工这一个：干净且已合并直接删；否则 commit、push、开 PR、再删（不能删 main） | 有东西要推时 |
| `/forget @repo` | 把仓库从 seahelm 移除，磁盘不动 | 是 |
| `/integrate [full]` | 跑一轮集成；`full` 带冲突标记合入 | 会丢本地改动时 |
| `/idea <文字>` | 记一条 idea | |
| `/feedback <文字>` | 给 seahelm 开 issue | |
| `/help [命令]` | 命令表；带参数给单条详解 | |
| `/yes` | 确认会话里待确认的动作 | |
| `/add` | 桌面专用（要文件选择器），聊天里回提示 | |

跟现在的对照：

| 现在 | 之后 |
|---|---|
| 裸文本（桌面）= 新建 worktree | `/new <任务>` |
| `/worktree` | `/status worktrees` |
| `/worktree <描述>` | `/new <描述>` |
| `/worktree #n` | `/go @branch` |
| `/pane` | `/status` |
| `/pane #n`（看 + 设当前） | `/show #n`（只看）、`/go #n`（只绑） |
| `/order #n` / `/broadcast` | 不变，`#n` 变成稳定编号 |
| `/return` / `/return @branch` | 不变 |
| `/return @repo` | `/forget @repo` |
| `... force` 后缀 | `/yes`；`force` 作为尾词保留给脚本用 |
| `/status`（聊天专用） | 并入 `/status` |
| `/integrate ... force` | `/integrate` 后回 `/yes` |

## 6. 确认

标了"确认"的动词，执行前先在会话里放一个 `pending`（动作 + 摘要 + 60 秒过期），回复摘要并提示 `/yes`：

```
/broadcast 先跑一遍测试
→ 发给 5 个 pane：#3 #4 #7 #9 #12。回 /yes 确认，60 秒内有效。
```

`/yes` 执行并清掉 `pending`；任何别的命令或文字都取消它。命令末尾带 `force` 跳过确认（给脚本和邮件用，邮件回一封 `/yes` 太慢）。

桌面入口有 sheet，同一个 `pending` 直接渲染成 sheet，不用 `/yes`。`/broadcast` 在桌面上现在走红区卡片，改为和其他确认一致：sheet。

## 7. 回复

- 每条改了东西的回复都带目标的编号和位置：`→ #7 seahelm/main`。
- 列表用稳定编号，不用序号：

```
seahelm
  main
    #3 ● Claude — 修登录页
    #7 ○ Codex — 跑测试            ← 在跟它说话
  task/telegram
    #9 ● Claude — 换 Telegram
teamclaw
  main
    #12 ◐ Claude — 等你回答
```

- 错误回复说清"没找到什么"和"怎么找"：`没有 #8。/status 看现在有哪些。`

## 8. 代码结构

新目录 `Sources/Core/Command/`：

| 文件 | 职责 |
|---|---|
| `CommandSpec.swift` | 动词表：名字、参数形态、一句话说明、是否确认、是否桌面专用。唯一的真相来源 |
| `Command.swift` | 解析结果枚举（现在的 `BridgeCommand`，加上 `status` `idea` `help` `yes` `show` `forget`） |
| `CommandParser.swift` | 纯函数：文本 + `FleetIndex` → `Command`。替换 `BridgeCommandParser` 和老的 `CommandParser` |
| `FleetIndex.swift` | 解析用的快照：pane（带编号）、worktree、仓库。`MainWindowController` 负责生成 |
| `PaneHandleRegistry.swift` | 稳定编号的分配和持久化 |
| `CommandSession.swift` | `CommandSession` + `CommandSessionStore`：会话、绑定、待确认；持久化，首次启动导入旧的 `gmail-mail-conversations.json` |
| `HeadlessCommandHost.swift` | 空舰队上的 host，给测试和窗口还没起来的时候用 |
| `CommandExecutor.swift` | 一个执行器，替换 `routeChatCommand`、`submitBridgeCommand`、`BridgeCommandRouter` 三处。输入 `Command` + `CommandSession` + 入口能力（能否弹 sheet、能否开面板），输出 `CommandReply`（文本 + 可选的导航动作） |
| `CommandFormatter.swift` | 列表、详情、帮助的渲染。帮助从 `CommandSpec` 生成 |

删除：`BridgeCommand.swift` 里的解析和格式化、`BridgeCommandRouter.swift`、`CommandParser.swift`、`AgentRegistry.executeCommand`、`MailSignature.entries`（改为生成）、`EmailConversationStore`（并入会话存储）。

各入口只剩薄薄一层：

- 桌面：Helm 输入框提交 → `CommandExecutor`，`CommandReply.navigation` 变成切 tab / 弹 sheet，文本进浮卡。自动补全从 `CommandSpec` 生成。
- Telegram：`AgentRegistry.handleInbound` 只做"找会话 → 执行 → 回复"。
- 邮件：`MailPaneRouter` 同样只做这三步，`MailCommandContext` 协议删掉。

桌面 UI 改动一处：`DashboardOverviewView` 的 pane 行显示 `#n`。

## 9. 分步落地

每一步单独可提交、可发布：

1. **稳定编号**：`PaneHandleRegistry` + 桌面 pane 行显示 `#n`。不碰命令。
2. **一个解析器**：`CommandSpec` + 新解析器 + 格式化，旧动词作为别名保留一个版本（`/worktree <描述>` → `/new`，`/pane #n` → `/go`）。三个入口切到 `CommandExecutor`，删旧解析器。测试：`CommandParserTests` 重写自 `BridgeCommandParserTests`，加 `CommandSpecTests`（帮助和补全和动词表一致）。
3. **会话与确认**：`CommandSessionStore`、Telegram 按 chat 绑定、`/yes`、邮件并入。测试：`CommandSessionTests`。
4. **删别名**。

## 10. 需要拍板的三个决定

1. **桌面裸文本的含义。** 提案改为"发给选中的 pane"，新建用 `/new`。代价是桌面少了"敲一句话就开 worktree"的便利；好处是三个入口一致，而且 NORMAL 模式下不进 INSERT 就能给 pane 说话。另一种选择是桌面保留裸文本 = 新建，接受不一致。
2. **确认用 `/yes` 还是 `force` 后缀。** 提案两个都收，`/yes` 是主路径。
3. **聊天里的 `/go` 要不要顺带切桌面。** 提案不切。如果你经常"手机上切好，回到桌面接着看"，可以加 `/go! #7` 表示"同时切桌面"。
