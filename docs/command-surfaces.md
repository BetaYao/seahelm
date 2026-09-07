# 命令与入口支持矩阵

哪条命令在哪个入口能用，以及 First Mate 会不会自己做同样的事。语法本身见 `docs/command-redesign.md`；动词表的唯一来源是 `Sources/Core/Command/CommandSpec.swift`，改动词先改那里，再回来对这张表。

## 入口

| 入口 | 会话 key | "当前"是什么 | 确认方式 |
|---|---|---|---|
| 桌面 Helm（Island 的输入框） | `desktop` | dashboard 选中的 pane | 原生 sheet |
| Telegram | `telegram:<chat_id>` | 这个 chat 用 `/go` 绑定的 pane；私聊和群各自独立 | 回 `/yes`（60 秒内） |
| 邮件 | `mail:<thread_id>` | 这个线程用 `/go` 绑定的 pane | 回 `/yes`，或命令末尾加 `force`（推荐，邮件往返慢） |
| First Mate（侧栏的舰队总览） | 无输入框 | 不适用 | Island 卡片上的按钮 |

### Telegram：私聊 vs 群聊

- **私聊**里任何一行都是命令：裸文本发给绑定的 pane，`/…` 走动词表。
- **群里只有 `/命令` 算命令**，裸文本是闲聊——共享群里随口一句话不该驱动 agent（`TelegramChannel.command`）。
- 群里的命令**必须以 `/` 开头**。Telegram 的 privacy mode 默认开着（`getMe` 里 `can_read_all_group_messages: false`），bot 在群里只收得到以斜杠开头的消息、对它自己消息的回复、以及服务消息；`@yourbot /status` 这种把提及写在前面的形式 **Telegram 根本不会投递**，seahelm 这边连日志都不会有。群里有多个 bot 时用后缀形式 `/status@yourbot`，`TelegramChannel.stripBotMention` 会把后缀去掉。
- 只有要用 Triggers（让 bot 读群里其他人的普通消息去触发 agent）时，才需要在 @BotFather 里 `/setprivacy` → Disable，并且**把 bot 移出群再重新加回去**才生效。即便如此 seahelm 在群里仍然只把 `/命令` 当命令，其余走规则匹配。
- 白名单（`allowed_users`）按发消息的**用户**判定，与在私聊还是群里无关；不在白名单的人发的 `/命令` 会被忽略。

三个文字入口共用同一个 `CommandExecutor`，差别只在确认方式和"当前"的定义。First Mate 是侧栏的舰队总览加上背后的监督者，不接受文字命令；监督者发起的动作以卡片形式出现在 Island 里，下表最后一列写的是它会不会自己做这件事。目前 Island 只渲染 suggestNextOrder 一类卡片；integrationReport 会进队列，但没有界面把它画出来。

## 矩阵

图例：✓ 支持 · △ 部分支持（见说明） · ✗ 不支持

| 命令 | 用途 | 邮件 | Telegram | 桌面 Helm | First Mate |
|---|---|---|---|---|---|
| 裸文本 | 发给当前绑定的 pane | ✓ 舰队只有一个 pane 时自动绑定 | ✓ 同左 | ✓ 发给选中的 pane | ✗ |
| `/new [@repo] <任务>` | 新建 worktree、派 agent、绑定过去 | ✓ | ✓ | ✓ 也可用 dashboard 内联表单 | ✗ |
| `/go #pane` / `/go @worktree` | 之后的话都发给它 | ✓ 只改这个线程 | ✓ 只改这个 chat，不动桌面 | ✓ 等于选中 | ✗ |
| `/show [#pane]` | 看 pane 最近输出和活动，不改绑定 | ✓ | ✓ | ✓ 顺带选中 | ✗（相近的是 inspect：agent 卡住时自动在 pane 里跑检查命令） |
| `/order #pane <文字>` | 给一个 pane 发一次 | ✓ | ✓ | ✓ | △ suggestNextOrder 卡片：批准后把建议的任务发给那个 pane |
| `/broadcast <文字>` | 群发所有 pane | ✓ 需确认 | ✓ 需确认 | ✓ sheet | ✗ broadcastOrder 卡片类型存在，但当前没有代码触发它 |
| `/status [worktrees\|repos]` | 舰队列表，稳定编号，标出绑定的那个 | ✓ | ✓ | ✓ 切到 dashboard 总览，不出文字 | ✗（dashboard 本身就是） |
| `/return` | 收工所有 worktree：没东西可交付的直接删，其余列出计划 | ✓ | ✓ | ✓ 有剩余时弹 sheet | ✗ |
| `/return @worktree` | 收工一个：干净且已合并直接删；否则 commit → push → 开 PR → 删 | ✓ 有东西要推时确认；agent 在跑会拒绝 | ✓ 同左 | ✓ sheet 确认，结果弹 sheet；侧栏右键 Return… 走同一条命令 | ✗ |
| `/forget @repo` | 移除仓库，磁盘不动，杀掉它的会话 | ✓ 需确认 | ✓ 需确认 | ✓ sheet | ✗ |
| `/integrate [full]` | 跑一轮集成 | ✓ 本地改动挡住时才问确认 | ✓ 同左 | ✓ 报告卡片上带选项 | △ 只出 integrationReport 卡片，不自己跑 |
| `/idea <文字>` | 记 idea，来源记成会话 key | ✓ | ✓ | ✓ | ✗ |
| `/feedback <文字>` | 开 GitHub issue（在 Mac 上开浏览器） | ✓ | ✓ | ✓ | ✗ |
| `/help [命令]` | 命令表 / 单条详解 | ✓ 每封回信签名里也带命令表 | ✓ | ✓ 输入 `/` 出菜单 | ✗ |
| `/yes` | 确认刚才那个要确认的动作 | ✓ 60 秒窗口对邮件不实用，用 `force` | ✓ | 不适用 | 对应卡片上的批准按钮 |
| `/add` | 加仓库 | ✗ 回提示 | ✗ 回提示 | ✓ 文件选择器 | ✗ |
| `… force` 尾词 | 跳过确认 | ✓ | ✓ | ✓ 跳过 sheet | 不适用 |

旧别名 `/worktree`、`/pane`、`/panes`、`/remove` 三个文字入口都还认，保留一个版本，不列在 `/help` 里。

## First Mate 自己的动作

不在命令语法里，卡片出现在 Island：

| 动作 | 区域 | 做什么 |
|---|---|---|
| watchWaiting / watchError | 绿区 | agent 等输入或报错时发通知；通知同时镜像到 Telegram 默认 chat |
| inspect / autoCommit | 绿区 | agent 卡住时在它的 pane 里跑配置的检查命令、自动提交 |
| suggestNextOrder | 红区 | 从 agent 输出里抓到的下一步建议，做成卡片，批准即发送 |
| AskUserQuestion / 屏幕选项 | 红区 | agent 在问问题，做成可点选的卡片，答案按编号或方向键送回 |
| integrationReport | 红区 | 一轮集成有冲突或被挡住时的报告 |

## 通知走向

- agent 完成的通知发到 Telegram 的默认 chat（`default_chat_id`，缺省为第一个数字 id 的白名单用户）。
- 凡是用 `/go` 绑定了那个 pane 的会话（某个 Telegram 群、某个邮件线程）也各收一份。
- 桌面上就是 Island 和系统横幅。
