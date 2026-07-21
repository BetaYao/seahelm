# Seahelm 远程客户端统一设计(Mobile / Watch / ESP32)

> **Status (2026-07-21):** 单一权威文档。取代并删除以下旧文档,其有效内容已并入此处:
> - `docs/srp-protocol.md`(JSON-RPC over WSS 草图)
> - `docs/superpowers/specs/2026-07-19-multiplatform-host-design.md`(Fat Host `seahelmd` 路线)
> - `docs/superpowers/specs/2026-07-19-mobile-flutter-client-design.md`(Flutter M1 IA)
> - `docs/mqtt-topic-acl-design.md`(MQTT topic/ACL 草稿)
>
> **传输主干决策(issue #13):** 采 **MQTT 零自研服务端**,否决 Fat Host WSS + `seahelmd` 守护进程路线。
> Seahelm 自身是 MQTT 上的**单一发布者兼历史/命令应答方**,不写 relay/historian。
> 手机(Flutter)、Watch、ESP32 **三端统一走 MQTT**。Fat Host spec 里与传输无关的
> 设计(Flutter 信息架构、能力分档、QR 配对、状态归 App)在此保留并重定向到 MQTT。

---

## 0. 架构总览

```
                         ┌─────────────────────────────┐
   Seahelm(Mac) ── CocoaMQTT ──▶ NanoMQ(Mac, launchd) ◀── Flutter 手机
   单一发布者              │      唯一基础设施          ◀── Apple Watch
   历史/命令应答方         │                            ◀── ESP32(HaiTalk 萌宠)
                         └──── (未来 bridge → 阿里云 EMQX,topic 树不变) ──┘
```

**边界规则**
1. **状态判定永远在 Seahelm App**(`StatusPublisher` / `StatusDetector` / `WorktreeStatusAggregator` / `ShipLog`)。客户端只显示,不判定。
2. Seahelm 是唯一 publisher;broker 只做 retained / ACL / 路由,不含业务逻辑。
3. 本地 CLI / agent skill 继续用现有 Unix 控制 socket;**所有远程流量走 MQTT**。
4. 换云端 EMQX 时,NanoMQ 配 bridge,客户端与 topic 树零改动。

**为什么 MQTT 而非 Fat Host WSS**:retained message 天然满足"上线即得全量状态 + Mac 离线仍可见";
ESP32 原生 MQTT 支持最好;单 broker 二进制比自研 Rust 守护进程运维成本低。代价(Mac 离线查不到历史)可接受。

---

## 1. Topic 树

根前缀 `seahelm`,第二段是 Mac 实例标识 `{mac_id}`(稳定、每台机器唯一;建议取机器名哈希或配置显式指定,**避免把真实机器名 PII 写进 topic**)。多 Mac 时 `mac_id` 天然做隔离与 ACL 边界。

```
seahelm/{mac_id}/
├── presence                              [retained, QoS1]  Mac 在线/离线(LWT)
├── focus                                 [retained, QoS1]  单焦点:此刻最该被看见的一件事 + 计数
├── worktree/{worktree_id}/status         [retained, QoS1]  worktree 级汇总状态
├── pane/{pane_id}/
│   ├── status                            [retained, QoS1]  pane 快照,连上即得
│   ├── message                           [QoS1]            新消息流
│   └── event                             [QoS1]            suggest / question / notification
├── dnd/state                             [retained, QoS1]  C7 专注勿扰状态(剩余时间 / 拦截计数)
├── history/request                       [QoS1]  client→S,MQTT5 response-topic
├── command                               [QoS1]  client→S,MQTT5 response-topic
└── reply/{client_id}/{corr}              [QoS1]  S→client 应答(由 response-topic 指定)
```

| topic | 方向 | retain | 用途 |
|---|---|---|---|
| `pane/{id}/status` | S→* | ✅ | **列表快照核心**。订阅 `pane/+/status` 连上即得每 pane 最后状态。空 payload = 墓碑(pane 关闭时清 retained) |
| `pane/{id}/message` | S→* | ❌ | agent 消息流;Seahelm 同时本地 JSONL 落盘每 pane 最近 N 条 |
| `pane/{id}/event` | S→* | ❌ | suggest / question(见 §7 应答通道)/ notification 镜像 |
| `worktree/{id}/status` | S→* | ✅ | `WorktreeStatusAggregator` 汇总;客户端订 `worktree/+/status` 得 worktree 列表 |
| `focus` | S→* | ✅ | 单焦点设备(Watch/ESP32)只订这一条即知"此刻该显示什么"(见 §5) |
| `presence` | S→* | ✅ | Mac 在线状态;LWT 掉线自动置 offline |
| `dnd/state` | S↔C | ✅ | C7 专注状态;设备也可发 `command` 开关(见 §9.1) |
| `history/request` `command` | C→S | ❌ | 历史查询 / 命令注入,带 MQTT5 response-topic + correlation |
| `reply/...` | S→C | ❌ | 一次性应答 |

---

## 2. Retain / QoS / LWT

| topic | QoS | retain | 理由 |
|---|---|---|---|
| `pane/+/status`, `worktree/+/status`, `focus`, `presence`, `dnd/state` | 1 | **yes** | 上线即得最新态;去重靠 payload `seq` |
| `pane/+/message`, `pane/+/event` | 1 | no | 不重放旧消息;历史走 request/response |
| `history/request` `command` `reply/...` | 1 | no | 命令类不重放 |

- **QoS 全用 1**:对 WiFi 抖动的嵌入式设备,QoS2 不划算;应用层用 `seq` 幂等去重。
- **LWT**:Seahelm 连接时设 `will = {topic: .../presence, payload: offline, retain, qos1}`,连上后立刻发布 `online`(retained)。
- **retained 清理**:pane 关闭发**零长度 retained** 墓碑,避免幽灵 pane 常驻。

---

## 3. Payload 契约(复用现有序列化,不另立 schema)

- **`pane/{id}/status`** = `PaneSnapshot.dict`(`Sources/Core/ControlProtocol.swift:24`):`pane_id`/`session_name`/`worktree_path`/`branch`/`project`/`agent_type`/`status`/`last_message`,发布侧补 `seq`。
- **`pane/{id}/message` / `event`** = `ShipLog.event(from:)`(`Sources/Core/ShipLog.swift:382`):`type`/`seq`/`pane_id`/`session_name`/`status`/`old_status`/`agent_type`/`worktree_path`/`last_message`。
- **`command`**:`{method, params}`,与 `ControlRouter.handle(method:params:)`(`ControlProtocol.swift:152`)一字不差,MqttChannel 原样转交。MQTT5 properties 带 `Response-Topic` + `Correlation-Data`。
- **`reply/...`**:`ControlResult` 编码,`{ok:true, result:{…}}` 或 `{ok:false, error:{code, message}}`。

> 状态分类映射见 §附 A(StatusDetector 的 running/waiting/done/error → 客户端语义)。

---

## 4. 能力分档 = broker ACL

权限**不在 Seahelm 里做**,全部落 broker ACL(NanoMQ / EMQX 均支持 username/clientid 维度;public 阶段叠加 mTLS CN 绑定)。这是"零自研服务端"的关键:换云端 EMQX 时 ACL 语义平移。

三档(沿用 Fat Host spec 的 Read / Interactive / Control,映射到 pub/sub 权限):

| 档位 | 语义 | sub | pub |
|---|---|---|---|
| **Read**(只读) | 观察 | `pane/+/status`, `worktree/+/status`, `focus`, `presence`, `dnd/state` | — |
| **Interactive**(交互,= Read ∪ 引用式选择) | 只能从服务端下发过的选项里选 | Read 全部 + `pane/+/event`, `reply/{own}/#` | `command`(仅 `suggest.pick`/`question.answer`), `history/request` |
| **Control**(控制) | 等价于坐在电脑前 | Interactive 全部 | `command`(含 `pane.send_text`/`send_keys`/`run`/…) |

- **Interactive 是安全楔子**:交互 token 泄露只能"替你点已存在的按钮",不能自由输入。
- **典型分配**:ESP32 = Read + 部分 Interactive/Control(见 §9);Watch = Interactive(可选 Control);Flutter 手机 = Interactive 默认,Control 需显式授予。
- **"禁用远程写入"总开关**:①broker 层移除 `command` 的 pub 权限;②Seahelm 层 Config `mqtt.allowRemoteWrite=false` 时即使收到 `command` 也回 `-32003`。双保险。

---

## 5. 单焦点选择(Watch / ESP32 关键)

Watch 的会话卡片、ESP32 萌宠都是**"一次只看一件事"**的设备,而 `pane/+/status` 是扁平列表。**由 Seahelm 端决定"此刻最该被看见的那件事"**,发到 retained 的 `focus`:

```jsonc
// seahelm/{mac_id}/focus
{ "pane_id":"p3", "kind":"blocked",           // idle|working|say|blocked|offline
  "headline":"Claude", "line":"迁移 staging→生产库",
  "worktree":"main", "counts":{"running":2,"waiting":1,"total":8},
  "seq":1050 }
```

- 优先级由 App 算(blocked > working > say > idle)。萌宠/Watch 只订 `focus` 一条,零聚合逻辑,契合 lite 设备。
- `counts` 顺带满足"几个 pane 在 running"(ESP32 萌宠首页数字)。
- 需要 pane 明细时再订 `pane/+/status` 过滤(Watch 进入某 worktree 看 pane list 即此路径)。

---

## 6. 安全(public 部署硬性要求)

> ⚠️ `pane.send_text` 是远程命令执行。public 前必须同时满足:

1. **TLS 全链路**:局域网 NanoMQ 起 `wss://` / mTLS;云端 EMQX 强制 TLS。
2. **严格 ACL**:每身份最小权限,按 `{mac_id}` 隔离;client 只能读写自己的 `reply` 子树。
3. **凭据分离**:ESP32 / Watch / Flutter / Seahelm publisher 各自独立凭据与档位。
4. **交互档优先**:远程默认走引用式选项;Control 档按需开启 + 可要求本机确认(复用通知面板)。
5. **内容约束**:即便 Control 开启,`send_text` 内容在 Seahelm 侧可配置长度/字符限制。

---

## 7. 配对与发现(QR,沿用 Fat Host §7,重定向到 MQTT)

1. 桌面显示 QR:broker 地址(LAN `mqtt://mac.local:8083` 或云端 wss)+ 一次性配对密钥。
2. 设备扫码 → 用密钥换取**长期 MQTT 凭据**(username/password 或客户端证书),绑定能力档位 + device id。
3. 回退:手动输入 broker 地址 + 凭据。
4. 凭据存设备安全区;桌面设置可吊销(broker 侧禁用该 username / 撤 ACL)。
5. 出门模式:同一凭据连云端 EMQX 主机名(NanoMQ bridge 已桥接)。

> 凭据签发/吊销由**桌面 App + broker 配置**承担(不是自研 daemon)。QR 里的一次性密钥换取由 Seahelm 侧一个轻量配对流程处理。

---

## 8. 客户端一:Flutter 手机(iOS + Android)

**定位**:`seahelmd` 依赖去除后,Flutter 直接连 MQTT broker。信息架构沿用旧 mobile spec,传输换成 MQTT。

**三屏 IA**
```
[1 配对] ──► [2 First Mate] ──► [3 Pane]
                 │ All | Orders
                 │ Repo → Worktree → Pane
```

- **1 配对**:扫 QR(§7)→ 长期交互档凭据;手动回退;凭据入安全存储。
- **2 First Mate**:
  - **All**:完整 Repo → Worktree → Pane 紧凑树(无卡片 chrome)。former Watch 项作为提升状态(waiting/error 圆点 + `Waiting ·`/`Error ·` 前缀)融入,不另开 feed。数据 = 订 `worktree/+/status` + `pane/+/status`。
  - **Orders**:待处理 First Mate orders(批准/忽略/inspect),tab 带 badge。数据 = `pane/+/event` 的 question/suggest。
  - 紧凑行:repo 头行、worktree 行(chevron + 汇总圆点 + 分支 + pane 数)、pane 行(圆点 + pane id + 一行消息 + agent 类型)。
- **3 Pane**:头部(pane id/状态/worktree/repo/agent)+ 最终消息区(push 字段;可选 capped `pane.read` later)+ suggest/question 选项按钮(交互档)+ 底部 prompt composer(**发送走 Control 档**,交互档 token 下可见但禁用)。

**客户端结构**
```
ui/       Pairing, FirstMate(All/Orders), Pane
domain/   Repo/Worktree/Pane/Order 模型 + 会话;合并 snapshot + 事件成树
mqtt/     MQTT 客户端、auth、seq 续传、重连(替代旧 srp/)
storage/  token、hosts
```
UI 不直接持有 socket;Domain 层做 snapshot + 事件合并。

> **注**:旧 Flutter spec 里的 `srp/`(WSS JSON-RPC)整层替换为 `mqtt/`;`suggest.pick`/`question.answer` 从 SRP 方法变为发往 `command` topic 的 payload。

---

## 9. 客户端二:Apple Watch

**连接**:独立 Watch App,**CocoaMQTT over WebSocket**(watchOS 上 `URLSessionWebSocketTask` 是一等公民,裸 TCP 受限)。连 NanoMQ 的 MQTT-over-WS 端口;public 走 wss+TLS。

| 界面 | 数据来源 |
|---|---|
| 会话列表 + 状态角标(Messages 式) | 订 `pane/+/status`(retained),连上即全量;或订 `worktree/+/status` 看 worktree 概览 |
| 进入某 worktree 看 pane list | `pane/+/status` 按 `worktree_path` 过滤 |
| 进入某 pane 看历史 | 发 `history/request`(response-topic + correlation),Seahelm 从 JSONL 应答 |
| 快速回复 | 发 `command`(`pane.send_text`,Control 档) |

**watchOS 后台限制(设计重点)**:watchOS 不允许 App 挂起后维持 MQTT 长连。应对组合:
1. **前台实时**:抬腕/打开时才建 MQTT 连接,retained 秒补全状态(主路径)。
2. **离线唤醒走 APNs**:关键状态变更(如 running→waiting 需人)由 **Mac 端直接调 APNs HTTP/2** 发推送。⚠️ 这是"零服务端"的例外:需 Apple push key,但仍不需自研 relay。
3. **Complication / Smart Stack**:低频概览(几十分钟级),显示"N 个 pane 待处理",不实时。

**陪伴 App 取舍**:独立 Watch App(推荐,不依赖 iPhone)vs iPhone 中转(`WatchConnectivity`,更省电但依赖手机在身边)。默认独立。

---

## 10. 客户端三:ESP32(HaiTalk 萌宠)

**硬件**:Waveshare ESP32-S3-Touch-AMOLED-1.43(466×466 圆形 AMOLED,SH8601/CO5300 QSPI + 侧键)。
**框架**:ESP-IDF + LVGL 9。
**设计源**:claude.ai/design 的 HaiTalk 圆屏原型(灰灵墨云吉祥物 + 状态环 + Sumi 墨配色)。

> **原型 vs 落地**:原型探索了 ~20 个状态(通话/团队心跳/点名/广播/晨报等)。**本期只落地 3 个功能**;其余为愿景态,标为"暂不接 MQTT"(见 §附 B 收敛说明)。灰灵的 SVG feTurbulence 位移动画无法在 ESP32 廉价复现,需转为预渲染精灵序列或简化程序化墨团(设计翻译,非 1:1 移植)。

### 里程碑
- **M1(纯设备端,不碰 MQTT)**:点亮屏、状态环、灰灵、字体排版 + idle/working/blocked/say 核心态,mock 数据跑通视觉。
- **M2(接 MQTT)**:三功能真正随 agent 状态变。

### ESP32 三功能 ↔ Seahelm/MQTT

| # | 功能 | 通道 | Seahelm 侧现状 | 净新增 |
|---|---|---|---|---|
| 3 | **直接给 pane 下命令/文本** | 发 `command`(`pane.send_text`,Control 档) | `ControlRouter.pane.send_text` **现成**(`ControlProtocol.swift:183`) | **≈0**。设备用 retained `pane/+/status` 拿 `pane_id` 作目标 |
| 2 | **物理 2FA(接现有 suggestion)** | 订 `pane/{id}/event` 收 question → 发 `command`(`question.answer`) | question 事件**现成**(screen 权限提示 `StatusPublisher.swift:298` → 红区 order);但**服务端无 `question.answer` handler**(仅 UI 点击 `handleSuggestionTapped` / Flutter SRP) | 服务端 answer 通道(把 `MainWindowController.handleSuggestionTapped` 逻辑抽为非 UI 可达)+ `questionId` 方案(本地是组合键,需可回传 id)+ event payload 补 questionId/prompt/options |
| 1 | **C7 专注勿扰** | 订 `dnd/state`;设备发 `command`(`dnd.set`)开关 | **App 无 focus/DND 概念**;仅 `NotificationManager` 每-key 冷却去重(`NotificationManager.swift:139`) | App focus 模式 + 被拦通知计数(hook `NotificationManager.shouldNotify`)+ `dnd/state` topic + `dnd.set` 命令 |

**结论**:功能 3 白送;功能 2 需补应答通道 + id 方案;功能 1 需建 focus 子系统(两端全新)。

#### 9.1 C7 `dnd/state` payload
```jsonc
// seahelm/{mac_id}/dnd/state (retained)
{ "on":true, "ends_at_epoch":1753123456, "blocked_count":4, "seq":1060 }
// 设备开关:command → { "method":"dnd.set", "params":{ "on":true, "minutes":25 } }
```

#### 9.2 物理 2FA `question` payload(补齐 §3 未定义的形状)
```jsonc
// seahelm/{mac_id}/pane/{id}/event
{ "type":"question", "question_id":"<稳定可回传 id>", "pane_id":"p3",
  "prompt":"prod-deploy 需要你在场", "options":["批准","拒绝"],
  "danger":true, "seq":1044 }
// 设备确认:command → { "method":"question.answer", "params":{ "question_id":"…", "index":0 } }
```
`question_id` 需一个稳定编码(如 `worktreePath#kind#terminalID#payloadHash` 的 base64),服务端回查后经 `answerChoiceByArrows`/发数字键驱动原 TUI。`stale_suggest`(-32002)给出天然确认窗口。

---

## 11. 演进路径(topic 树零改动)

| 阶段 | broker | 客户端连接 | 变化 |
|---|---|---|---|
| 局域网 | NanoMQ(单机 launchd) | 同网直连 | — |
| public | 阿里云 EMQX | 连云端 wss;NanoMQ 配 bridge 上行 | 客户端与 topic 树**零改动** |

---

## 12. Seahelm 侧新建清单

1. `MqttChannel`(CocoaMQTT,实现 `ExternalChannel`;参照 `WeComBotChannel` 的重连退避)。**每 command 派发独立 worker 线程**,避开 `ControlRouter.waitForOutput` 的阻塞轮询。`ExternalChannelType` 增 `case mqtt`。
2. per-pane 消息环形缓冲 + JSONL 持久化(`~/.config/seahelm/`)。
3. `focus` / `worktree/{id}/status` 发布(复用 `WorktreeStatusAggregator`)。
4. **`question.answer` / `suggest.pick` 服务端 handler**(功能 2/Flutter/Watch 共用;抽 `handleSuggestionTapped` 逻辑)+ `questionId` 方案。
5. **focus/DND 子系统**(功能 1):focus 模式 + 被拦通知计数(hook `NotificationManager.shouldNotify`)+ `dnd/state` 发布 + `dnd.set` 命令。
6. Config `mqtt` 段(broker 地址/凭证/`enabled`/`allowRemoteWrite`),照 `wecomBot` 模式(`decodeIfPresent`)。
7. QR 配对流程(一次性密钥 → 长期 MQTT 凭据;broker ACL 侧配置)。

## 13. 开工检查清单

- [x] 统一设计(本文档)
- [ ] Mac 装 NanoMQ,验证 retained / MQTT-over-WS / LWT 连通性
- [ ] `MqttChannel` + Config `mqtt` 段
- [ ] `focus` / `worktree` 聚合发布
- [ ] `question.answer` 服务端 handler + questionId 方案
- [ ] focus/DND 子系统 + `dnd/state`
- [ ] per-pane JSONL 缓冲
- [ ] 客户端:Flutter(MQTT 替换 SRP 层)、Watch(CocoaMQTT/WS + APNs)、ESP32(M1 视觉 → M2 三功能)

---

## 附 A:状态分类映射(StatusDetector → 客户端语义)

| StatusDetector(App) | Flutter/Watch | ESP32 HaiTalk | 环颜色 |
|---|---|---|---|
| running | 运行中 | working(green breathing) | green |
| waiting(需输入/决策) | 等待 | blocked / 2FA(经 question 事件) | ember/red |
| done + last_message | 完成 | say(总结) | green |
| idle / 无会话 | 空闲 | idle(灰灵安然) | ash(soft) |
| error | 错误 | (困顿) | red |
| Mac 离线(presence) | 离线 | offline | 暗灰 |

> 精确枚举以 `ShipLog.event(from:)` 实际输出的 `status` 字符串为准,落地时对齐。

## 附 B:HaiTalk 原型范围收敛

本期 ESP32 只做 §10 的 3 个功能(C7 / 物理 2FA / 直接下命令)。原型中的以下能力**暂不接 MQTT**,建议各自另开 issue:

| 功能 | 暂缓原因 |
|---|---|
| C1 通话 | 实时音频,MQTT 不承载;需另开信令 + WebRTC/音频通道 |
| C4 心跳 / C5 点名 | 需跨用户多 Mac 的 team-presence 聚合层,单 `{mac_id}` 树装不下 |
| C3 广播 / C6 晨报 | 新 team 级 topic;晨报还含 TTS 音频输出 |
| §8 配对/联网 UI | 设备开通走 BLE/本地,非应用层 topic(配对凭据交换见 §7) |
