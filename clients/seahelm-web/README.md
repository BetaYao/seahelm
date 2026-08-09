# seahelm-web — MQTT 调试台 + 本地链路

网页端 Seahelm 客户端(纯静态,MQTT.js over WS),兼作**整个 MQTT 后端的调试台**。
和 Watch/ESP32 用完全相同的 topic 树 / payload(`../../docs/remote-clients-design.md` §15),
所以它先跑通 = 替所有客户端把协议验证掉。

> **不是 Artifact**:Claude Artifact 的 CSP 禁连外部 WS,故必须作普通静态页在浏览器打开。

## 组成

| 文件 | 作用 |
|---|---|
| `index.html` | 网页客户端:左栏 First Mate(by pane)、中间 **VT 终端**、右栏报文日志(可隐藏) |
| `mqtt.min.js` | vendored MQTT.js 浏览器包(离线可用) |
| `xterm.js` / `xterm.css` | vendored xterm.js 5.5.0 —— 浏览器里的终端渲染器 |
| `devbroker/broker.js` | 本地 dev broker(aedes):MQTT `2883` + MQTT-over-WS `28083`（避开 seahelm-stack EMQX 的 1883/8083） |
| `devbroker/mock-seahelm.js` | Seahelm 替身:发 retained 快照、处理 `command`/`history`,**= 真 MqttChannel 的可执行规格** |
| `devbroker/zmx-vt.js` | zmx ↔ VT 字节流桥:经 attach 拿首屏+实时流,合并后发布 |
| `devbroker/zmx-attach.py` | pty 中继(Node 没有内建 pty,而 attach 需要控制终端) |
| `devbroker/vt-test.js` | VT 通道端到端测试(含乱序 + **重绘保真**回归) |

## 跑起来(本地全链路,无需真 Seahelm / EMQX)

```bash
cd clients/seahelm-web/devbroker
npm install            # 首次:aedes + ws + websocket-stream + mqtt
npm run broker         # 终端 A:起 broker(MQTT 2883 + WS 28083)
MAC=live npm run mock  # 终端 B:起 Seahelm 替身(发快照 + 应答命令)
```

> `MAC=live` 不是可选的。页面里 broker/user/pass/mac 那排手动字段(`#advRow`)是
> `hidden` 的,且**没有任何代码会揭开它** —— UI 上唯一能设 mac 的入口是「配对」按钮,
> 而它只吃 macOS 配对界面产生的 `seahelm://pair?…` 链接,本地 devbroker 没有。
> 所以只能让替身发到页面默认的 `live` 上。(`mock` 自己的默认仍是 `testmac`,
> 因为 `vt-test.js` / `protocol-test.js` 用的是那个。)

然后浏览器打开 `clients/seahelm-web/index.html`(直接双击或 `open index.html`):
- 字段已有默认值(broker `ws://localhost:28083/mqtt`、mac `live`),user/pass 留空即可(本地 aedes 允许匿名)
- 点**连接** → 立即渲染 retained 快照
- 点左栏任意一行 → 中间直接开该 pane 的终端(没有中间步骤,中间栏就是终端)
- 有 `question` 时,卡片**悬浮在整页最底部**,点选项测 `question.answer`(2FA 路径)
- 顶栏**日志**按钮收起右栏;**DND** 测 `dnd.set`

### 界面构成

- **左栏 = First Mate**,按 `Sources/UI/Dashboard/DashboardViewController.swift` 的
  "Group by Sailor"(by pane)模式 1:1 移植:deck 分组头 → 每个 worktree 一行
  (状态字形 + 标题 + 耗时 / deck + 分支 + `+adds −dels ↑ahead↓behind` + `N sailors`)→
  **仅当该 worktree 有 2 个以上 pane 时**才展开缩进的 pane 行。度量、字号、间距和
  `SemanticColors` 取值都来自 Swift 源码,不是照着截图estimate 的。
  web 端**只做 by pane 这一种布局**,不提供 Mac 上的分组模式切换。
- **中间 = 终端**,没有消息流、没有历史分页、没有整行发送框(都已移除)。
- **右栏 = 报文日志**,开发用,可隐藏,状态记在 `localStorage`。

### 响应式与滚动

| 宽度 | 布局 |
|---|---|
| > 1100px | 三栏,日志栏可手动开关 |
| ≤ 1100px | 日志栏自动隐藏(没地方同时调试和干活) |
| ≤ 760px | 单栏,First Mate 变成抽屉(☰),选中后自动收起 |

终端**按宽度**贴合,不是两轴都贴合:列被截断或折行对 TUI 的破坏远大于纵向滚动,
而且把纵轴让出来给 xterm 自己的 scrollback 滚动条,两者就不会抢同一个手势。
字号下限 9px —— **128 列在 390px 的手机上无论如何都不可读**,低于这个下限
诚实的做法是横向平移而不是继续缩小(实测手机上需平移 345px)。
右下角的「↓ 最新」在你往回翻时出现:终端是活的,新输出还在往下落。

> attach 的重放**包含 scrollback**(实测一接上就有上百行),所以往回翻是有内容的。

> deck / 分支 / diff 数是**真的 git 读数**(`git rev-parse` / `diff --shortstat` /
> `rev-list --count`,按 worktree 缓存 30s),不是造的。没有来源的只有"任务标题" ——
> zmx session 不知道自己在做什么任务,所以退回 worktree 目录名;Mac 上那一栏是
> `PaneTitleResolver` 从 agent 解析出来的。start_dir 已被删除的 session 归到
> `Unknown deck`(Mac 的同名兜底)。

## VT 终端(远程终端渲染 PoC)

验证「把 Mac 上一个真实 pane 的 VT 字节流搬到远端客户端渲染」这条路走不走得通。
**Mac 侧不需要改 libghostty**,但**只有一个原语是保真的**:

```
zmx attach <name>         → 真·原始 VT 流(首屏重放 + 实时),经 zmx-attach.py
zmx send <name> <text>    → 键级输入(未 attach 时的回退路径)
```

> ⚠️ **`zmx tail` 和 `zmx history --vt` 都是线性化的,不能用来渲染。**
> 它们保留 SGR 颜色,但**丢弃全部光标移动**。结果是:原地重绘的 TUI(Codex、
> Claude Code)每重绘一帧就被摊平成一段追加文本,回放时是 N 份堆叠的画面,
> 完全没法看。同一负载实测(5 次 `ESC[3A` 重绘):
>
> | 源 | cursor-up 数 | 帧数 |
> |---|---|---|
> | `zmx attach` | **5** | 5 |
> | `zmx tail` | **0** | 5 |
>
> attach 正是 Seahelm 自己渲染 pane 所走的路径(Ghostty 的 PTY 里跑的就是它),
> 所以它必然保真。`vt-test.js` 里有一条回归测试盯着这个,别再换回 tail。

两个坑,`zmx-attach.py` 的 docstring 里也写了:

1. **`ZMX_SESSION` 必须清掉。** 从 Seahelm pane 里继承下来的话,attach 会被劫持到
   *那个* session 上,流**静默地空**(不报错)。
2. **attach 不是只读的。** 它是一个真客户端,窗口尺寸不同会**把 session 缩放掉**,
   连带影响 Mac 上的显示。所以桥接先量出 session 的真实尺寸(pid → tty → `stty size`)
   再把 pty 钉死在那个尺寸上。

浏览器里 xterm.js 就是渲染器,所以这个 PoC 一行 Zig 都不用写。
（原生客户端才需要 custom-io Ghostty 的 `ghostty_surface_feed_data`。）

```bash
cd devbroker
# 跑测试(mock 与 vt-test 都默认 testmac):
npm run broker            # 终端 A
npm run mock:zmx          # 终端 B:ZMX_PANES=1,把真实 zmx session 发成 pane
node vt-test.js           # 终端 C:7 项端到端全绿

# 用网页看渲染:终端 B 改成发到页面默认的 live(理由见上面那条注)
MAC=live npm run mock:zmx
```

网页上:点**连接** → 左栏 First Mate 出现真实 zmx session → 点任意一行,终端即刻打开。
键盘直接打字。

新增 topic 与命令(尚未进 `docs/remote-clients-design.md`,PoC 阶段):

| topic / method | 方向 | 说明 |
|---|---|---|
| `pane/{key}/vt` | S→* | **不 retained**。`{type:'vt.snapshot'\|'vt.data', b64, cols?, rows?}` |
| `pane.vt_open` | C→S | 起 attach 客户端;头 350ms 的重放作为 `vt.snapshot`(含几何)发出,其后转直播 |
| `pane.vt_close` | C→S | 断开该 attach 客户端(**绝不能调 `zmx detach`,那会断开所有客户端**) |
| `pane.send_keys` | C→S | `{b64}` = UTF-8 键序列的 base64;已 attach 时直接写进 pty |
| `mock.vt_stats` | C→S | 吞吐读数(字节/消息/秒) |

### 三个已知坑(PoC 暴露出来的,不是遗漏)

1. **base64 双层。** E2EE 信封只封字符串(`e2ee.js`),二进制会从 `sealSync` 旁边明文溜过去。
   所以 VT 先 base64 再进信封,开 E2EE 时约 1.8x 膨胀。要还的债是给信封加二进制路径。
2. **几何不可协商。** zmx 不报尺寸也没有 resize 动词。桥接改用 `pid → tty → stty size`
   从外部读,把尺寸随快照一起下发,客户端据此 `resize`。**行数对不上会让所有绝对光标定位
   (`ESC[r;cH`)错行**,新输出直接盖进 scrollback 中间 —— 这个必须先修才看得对。
   代价是远端只能缩放字号去适配,不能真的改大小。
3. **MQTT 不是流的合适管道 —— 已据此改道。** 本地 devbroker 跑得动,但 retained/QoS1
   是为快照设计的,EMQX Serverless 还有速率和 payload 配额。**结论:网页端不走 MQTT,
   改为经 Tailscale 直连内网。** 本目录的 MQTT 链路继续作为协议调试台和 mock 存在
   (`mock.vt_stats` 与每 10s 的 `[vt]` 日志仍是量吞吐的地方),但不再是网页端的生产传输。
   另外:任何订到 base 的客户端都能拿到全量 VT scrollback —— 上面那个匿名 sniffer 就是
   证明,§0 的隐私提示对全量 scrollback 要放大好几倍来读。这一条在 Tailscale 方案里
   同样要回答,只是换成了内网边界的问题。

## 协议一致性测试

```bash
cd clients/seahelm-web/devbroker
npm run broker   # 终端 A
npm run mock     # 终端 B
node protocol-test.js   # 终端 C:22 项 §15 功能全绿则协议契约通过
```

## 指向真 broker(EMQX Cloud)

同一个网页,Broker 改成 `wss://a81fb6d3.ala.cn-hangzhou.emqxsl.cn:8084/mqtt` + 填 EMQX 用户名/密码即可。
届时 `mock-seahelm.js` 换成真 Seahelm 的 `MqttChannel`,网页零改动。

## 协议要点(与 §15 一致)

- 只用 MQTT 3.1.1 最小集(retained / LWT / QoS1),**不吃 MQTT5 properties**。
- 请求-应答:命令/历史在 **payload 内自带** `reply_to` + `corr`,应答回 `{ok,result|error,corr}`。
- status/worktree/focus/presence/dnd = retained(上线即得);message/event 不 retained。
