# seahelm-web — Host Gateway browser client

网页端 Seahelm 客户端(纯静态 + xterm.js),**生产路径经 Mac 内嵌 Host Gateway (WSS)**。
配对后直连 `wss://…/ws`,走 JSON-RPC 请求/应答 + VT notify;不再经 MQTT 传终端字节流。

> **不是 Artifact**:Claude Artifact 的 CSP 禁连外部 WS,故必须作普通静态页在浏览器打开。

## 生产用法(Gateway-first)

1. Mac 上启用 Host Gateway(Seahelm Settings → Host Gateway / Browser access)。
2. 浏览器打开 Gateway 页面(如 `http://<Mac Tailscale IP>:2783/` 或 localhost)——**http / https 均可**。
3. 在网页输入 Settings 里显示的 **8 位配对码** → 配对并连接。
4. 连接后自动 `session.snapshot` → First Mate 渲染 pane 列表 → 点一行开 VT 终端。
5. 浏览器会记住 token;下次打开同一页面自动重连。刷新配对码不会踢掉已配对浏览器;「撤销所有远程」才会。

传输选择(自动,无需手调):

| 条件 | 传输 |
|---|---|
| 页面同源 `/ws`(Host Gateway 托管),或 `?transport=gateway` | **WebSocket Host Gateway** |
| `?mqtt=1`,或 broker 为 `localhost:28083` | **MQTT**(devbroker 调试) |

Gateway 握手:

1. 首次:`auth` → `{code}` → 返回 `{ok, mac_id, token, vt_binary, vt_deflate}`
2. 回访:`auth` → `{mac_id, token}`(localStorage)
3. `session.snapshot` → 填充 First Mate
4. 选 pane → `pane.vt_open`; 服务端 push binary VT frames(或 JSON legacy)
5. 键盘 → `pane.send_keys` `{pane_session_key, b64}`

Wire 格式:

```
请求:  {"id","method","params"}
应答:  {"id","result"} 或 {"id","error"}
推送:  {"type":"notify","method","params"}
```

## 组成

| 文件 | 作用 |
|---|---|
| `index.html` | 网页客户端:Gateway + MQTT 双模;左栏 First Mate、中间 VT 终端、右栏报文日志 |
| `e2ee.js` | 配对 URI 解析 + HKDF auth/E2EE(与 Mac `MqttCrypto` 一致) |
| `mqtt.min.js` | vendored MQTT.js — **仅 devbroker / 遗留 MQTT 调试** |
| `xterm.js` / `xterm.css` | vendored xterm.js 5.5.0 |
| `xterm-addon-webgl.js` | vendored WebGL renderer — loaded on first terminal open, not at page load |
| `devbroker/` | 本地 MQTT 调试台(**非生产路径**) |

## 本地 MQTT 调试(dev-only)

`devbroker` + `mock:zmx` 用于协议/VT 开发,**不是**生产远程控制路径。

```bash
cd clients/seahelm-web/devbroker
npm install
npm run broker         # 终端 A: MQTT 2883 + WS 28083
MAC=live npm run mock  # 终端 B: Seahelm 替身(快照 + 命令)
```

浏览器打开 `index.html`,broker 默认 `ws://localhost:28083/mqtt`(自动走 MQTT)。
也可显式 `?mqtt=1`。

> `MAC=live` 因为 UI 上 mac 只能通过配对设置;本地替身需发到页面默认 `live`。

### 真实 zmx pane(dev-only)

```bash
npm run broker            # 终端 A
MAC=live npm run mock:zmx # 终端 B: ZMX_PANES=1,真实 zmx session → MQTT pane
```

**`mock:zmx` 仅供本地开发** — 生产浏览器应连 Mac Host Gateway,不经 MQTT。

## 界面构成

- **左栏 = First Mate**,按 Mac Dashboard "Group by Sailor" 模式移植。
- **中间 = 终端**,选 pane 即开 VT。
- **右栏 = 报文日志**,开发用,可隐藏。

### 响应式

| 宽度 | 布局 |
|---|---|
| > 1100px | 三栏,日志栏可手动开关 |
| ≤ 1100px | 日志栏自动隐藏 |
| ≤ 760px | 单栏,First Mate 抽屉(☰) |

终端按宽度贴合;字号下限 9px;右下角「↓ 最新」在回看时出现。

## VT 终端

Mac 侧经 **`zmx attach`** 保真 PTY 流;浏览器 xterm.js 渲染。
Gateway notify / MQTT topic 均携带 `{b64, cols?, rows?}`;客户端共用 `handleVT()` 解码路径。

命令(Gateway JSON-RPC / MQTT command 共用 method 名):

| method | 说明 |
|---|---|
| `pane.vt_open` | attach;首屏 `vt.snapshot`,其后 `vt.data` |
| `pane.vt_keepalive` | 20s 心跳 |
| `pane.vt_close` | 断开 attach 客户端 |
| `pane.send_keys` | `{b64}` UTF-8 键序列 |

## 协议一致性测试(MQTT devbroker)

```bash
cd clients/seahelm-web/devbroker
npm run broker && npm run mock
node protocol-test.js   # 22 项 §15
node vt-test.js         # VT 端到端
```

## 相关文档

- `docs/superpowers/specs/2026-08-10-web-host-gateway-design.md` — Gateway 设计
- `docs/remote-clients-design.md` — MQTT 协议(Watch/ESP32;web 生产走 Gateway)
