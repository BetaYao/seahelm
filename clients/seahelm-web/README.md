# seahelm-web — MQTT 调试台 + 本地链路

网页端 Seahelm 客户端(纯静态,MQTT.js over WS),兼作**整个 MQTT 后端的调试台**。
和 Watch/ESP32 用完全相同的 topic 树 / payload(`../../docs/remote-clients-design.md` §15),
所以它先跑通 = 替所有客户端把协议验证掉。

> **不是 Artifact**:Claude Artifact 的 CSP 禁连外部 WS,故必须作普通静态页在浏览器打开。

## 组成

| 文件 | 作用 |
|---|---|
| `index.html` | 网页客户端:连 broker、渲染 focus/worktree/pane/详情、发命令、报文日志 |
| `mqtt.min.js` | vendored MQTT.js 浏览器包(离线可用) |
| `devbroker/broker.js` | 本地 dev broker(aedes):MQTT `2883` + MQTT-over-WS `28083`（避开 seahelm-stack EMQX 的 1883/8083） |
| `devbroker/mock-seahelm.js` | Seahelm 替身:发 retained 快照、处理 `command`/`history`,**= 真 MqttChannel 的可执行规格** |

## 跑起来(本地全链路,无需真 Seahelm / EMQX)

```bash
cd clients/seahelm-web/devbroker
npm install            # 首次:aedes + ws + websocket-stream + mqtt
npm run broker         # 终端 A:起 broker(MQTT 2883 + WS 28083)
npm run mock           # 终端 B:起 Seahelm 替身(发快照 + 应答命令)
```

然后浏览器打开 `clients/seahelm-web/index.html`(直接双击或 `open index.html`):
- Broker 填 `ws://localhost:28083/mqtt`,user/pass 留空(本地 aedes 允许匿名),mac 填 `testmac`
- 点**连接** → 立即渲染 retained 快照(3 panes + focus)
- 点某 pane → 看消息流;底部输入框发 `pane.send_text`(收 reply + 回显)
- p3 有个待决策 `question` → 点选项测 `question.answer`(2FA 路径)
- 右上角**同步历史**测 `history/request`（最新页）；顶部**继续加载**测 `before_seq` 分页；**DND** 测 `dnd.set`
- 右栏**报文日志**看所有收发 JSON

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
