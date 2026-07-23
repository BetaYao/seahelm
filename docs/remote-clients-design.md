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

> **v1 部署决策(2026-07-23):** 直接用 **EMQX Cloud** 作唯一 broker,**公网可达 + MQTT over WSS/TLS**。
> 不先跑本地 NanoMQ、不做 bridge —— Seahelm 与所有客户端从第一天起都连云端。因此**安全(§6)不再是
> "public 前"的门槛,而是 v1 强制项**。本地 NanoMQ 仅作可选的开发期自托管(见 §11)。

```
                              ┌──────────────────────────┐
   Seahelm(Mac) ── CocoaMQTT/TLS ──▶  EMQX Cloud   ◀── Flutter 手机(WSS)
   单一发布者(出站连云)         │  (公网,WSS/TLS)  ◀── Apple Watch(WSS)
   历史/命令应答方               │                   ◀── ESP32(HaiTalk,MQTT/TLS)
                              └── retained / ACL / 认证 ──┘
```

**边界规则**
1. **状态判定永远在 Seahelm App**(`StatusPublisher` / `StatusDetector` / `WorktreeStatusAggregator` / `ShipLog`)。客户端只显示,不判定。
2. Seahelm 是唯一 publisher(**出站**连 EMQX Cloud,穿 NAT 无需公网 IP);broker 只做 retained / ACL / 认证 / 路由,不含业务逻辑。
3. 本地 CLI / agent skill 继续用现有 Unix 控制 socket;**所有远程流量走 MQTT**。
4. `{mac_id}` 是**多租户隔离与 ACL 的边界** —— 公网共享 broker 上,每台 Mac 及其配对客户端只能读写自己 `mac_id` 子树。

**为什么 MQTT 而非 Fat Host WSS**:retained message 天然满足"上线即得全量状态 + Mac 离线仍可见";
ESP32 原生 MQTT 支持最好;EMQX Cloud 托管 broker 比自研 Rust 守护进程 + Cloudflare Tunnel 运维成本低。代价(Mac 离线查不到历史)可接受。

> ⚠️ **隐私提示**:pane 消息 / `last_message` 会经 EMQX Cloud 中转,retained 状态**驻留在云 broker**上
> (传输 TLS 加密,但 broker 运营方在服务端可见)。终端内容属敏感数据 —— 对隐私敏感的用户应提供
> "仅局域网自托管 NanoMQ"的选项(§11),或对 message/last_message 做发布前脱敏/开关。

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
├── history/request                       [QoS1]  client→S,payload 内 reply_to+corr
├── command                               [QoS1]  client→S,payload 内 reply_to+corr
└── reply/{client_id}/{corr}              [QoS1]  S→client 应答(topic 由 payload reply_to 指定)
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
| `history/request` `command` | C→S | ❌ | 历史查询 / 命令注入,payload 内自带 `reply_to` + `corr`(不吃 MQTT5 properties) |
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
- **`command`**:`{method, params, reply_to, corr}`,`method`/`params` 与 `ControlRouter.handle(method:params:)`(`ControlProtocol.swift:152`)一字不差,MqttChannel 原样转交;`reply_to`(应答 topic)+ `corr`(关联 id)**放在 payload 里**,不依赖 MQTT5 properties(见 §15.0)。
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

## 6. 安全(v1 即公网,以下从第一天起强制)

> ⚠️ v1 直连公网 EMQX Cloud,`pane.send_text` 是**公网上的远程命令执行**。以下**全部为 v1 硬性项**,
> 不是"以后再加"。EMQX Cloud 的认证/ACL 在控制台配置,与 topic 树一一对应。

1. **TLS 全链路**:EMQX Cloud 强制 TLS;客户端一律 `wss://`(WSS/TLS),Seahelm 出站 `mqtts://`。
2. **认证**:每身份独立 username/password(或客户端证书);EMQX 内置认证或外接。禁止匿名连接。
3. **严格 ACL**:每身份最小权限,按 `{mac_id}` 隔离(多租户边界);client 只能读写自己 `mac_id` 子树 + 自己的 `reply` 子树。ACL 规则见 §4。
4. **凭据分离**:ESP32 / Watch / Flutter / Seahelm publisher 各自独立凭据与档位;泄露单个不波及其它。
5. **交互档优先**:远程默认走引用式选项(`suggest.pick`/`question.answer`);Control 档(`pane.send_text` 等)按需开启 + 可要求本机确认(复用通知面板)。
6. **内容约束**:即便 Control 开启,`send_text` 内容在 Seahelm 侧可配置长度/字符限制,防注入超长/控制序列。
7. **凭据吊销**:桌面设置可吊销某设备(EMQX 控制台禁用该 username / 撤 ACL);配对密钥一次性、短时效。

---

## 7. 配对与发现(QR,沿用 Fat Host §7,重定向到 MQTT)

1. 桌面显示 QR:EMQX Cloud 的 broker 地址(`wss://<cluster>.emqxsl.com:8084/mqtt`)+ 一次性配对密钥。
2. 设备扫码 → 用密钥换取**长期 MQTT 凭据**(username/password 或客户端证书),绑定能力档位 + device id。
3. 回退:手动输入 broker 地址 + 凭据。
4. 凭据存设备安全区;桌面设置可吊销(broker 侧禁用该 username / 撤 ACL)。
5. v1 即公网:所有客户端(局域网/外网)都用同一 EMQX Cloud WSS 端点 + 凭据,天然随处可用,无"出门模式"切换。

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

**连接**:独立 Watch App,**CocoaMQTT over WebSocket**(watchOS 上 `URLSessionWebSocketTask` 是一等公民,裸 TCP 受限)。连 EMQX Cloud 的 **WSS/TLS** 端点(`wss://<cluster>.emqxsl.com:8084/mqtt`)。

| 界面 | 数据来源 |
|---|---|
| 会话列表 + 状态角标(Messages 式) | 订 `pane/+/status`(retained),连上即全量;或订 `worktree/+/status` 看 worktree 概览 |
| 进入某 worktree 看 pane list | `pane/+/status` 按 `worktree_path` 过滤 |
| 进入某 pane 看历史 | 发 `history/request`(payload 内 `reply_to`+`corr`),Seahelm 从 JSONL 应答 |
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
// 设备开关:command → { "method":"dnd.set", "params":{ "on":true, "minutes":25 }, "reply_to":"…", "corr":"…" }
```

#### 9.2 物理 2FA `question` payload(补齐 §3 未定义的形状)
```jsonc
// seahelm/{mac_id}/pane/{id}/event
{ "type":"question", "question_id":"<稳定可回传 id>", "pane_id":"p3",
  "prompt":"prod-deploy 需要你在场", "options":["批准","拒绝"],
  "danger":true, "seq":1044 }
// 设备确认:command → { "method":"question.answer", "params":{ "question_id":"…", "index":0 }, "reply_to":"…", "corr":"…" }
```
`question_id` 需一个稳定编码(如 `worktreePath#kind#terminalID#payloadHash` 的 base64),服务端回查后经 `answerChoiceByArrows`/发数字键驱动原 TUI。`stale_suggest`(-32002)给出天然确认窗口。

---

## 11. 部署(v1 = EMQX Cloud;NanoMQ 仅可选自托管)

**本项目 v1 集群(EMQX Serverless,cn-hangzhou):**

| 项 | 值 |
|---|---|
| Host | `a81fb6d3.ala.cn-hangzhou.emqxsl.cn` |
| MQTT over TLS(Seahelm / ESP32) | `mqtts://…:8883` |
| WSS over TLS(Watch / Flutter / Web) | `wss://…:8084/mqtt` |
| CA 证书 | `emqxsl-ca.crt` = **DigiCert Global Root G2(公开根)**;iOS/macOS 系统信任库已含,Apple 端多半无需内置。ESP32 需内置此根做 esp-tls 校验。仓库存 `certs/emqxsl-ca.crt` |
| 认证 | username/password(EMQX 控制台创建;**禁匿名**)。每身份独立凭据 + ACL(§4/§6) |

> ⚠️ 凭据(username/password)不入库,走各端安全存储 / 配置;CA 证书可入库(非机密)。

| 方案 | broker | 定位 |
|---|---|---|
| **v1(默认)** | **EMQX Cloud**(公网,WSS/TLS) | 正式部署:Seahelm 出站连云,客户端公网直连,随处可用、免自建 |
| 可选自托管 | NanoMQ(单机 launchd,局域网) | 隐私敏感/离线用户:仅局域网,终端内容不出本机网络。topic 树与 ACL 语义相同,客户端只换 broker 地址 |

- **topic 树与 payload 在两种部署下完全一致** —— 换 broker 只改连接地址与凭据。
- EMQX Cloud 提供 retained / LWT / ACL / WSS / 认证,覆盖本设计全部依赖(仅用 MQTT 3.1.1 特性集,MQTT5 不作依赖)。
- 不再需要 NanoMQ→EMQX bridge(v1 直接连云);bridge 仅在"本地采集 + 云端汇聚"的未来场景才考虑。

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

见 **§14 落地路线图**(按 Phase 0 后端 → Phase 1 Watch → Phase 2 ESP32 排好的分阶段勾选清单)。

---

## 14. 落地路线图(优先级:后端 → Watch → ESP32)

商业价值判断:Watch 是软件生意(App Store 分发、零硬件摩擦、嵌入日常工作流、可挂订阅),
优先级高于 ESP32(硬件生意,供应链/物流重,更适合做营销 halo)。但两者**共用同一套 MQTT
后端**,所以真正的关键路径是先打通后端,再优先接 Watch,ESP32(已到 M1)顺势接上。

### Phase 0 — 共享 MQTT 后端(阻塞一切,先做)
> 完成标志:一个脚本客户端经**公网 WSS/TLS** 连 EMQX Cloud,订到 retained 状态、发命令、收应答。

- [ ] **开通 EMQX Cloud** 集群(WSS/TLS 端点),配认证(禁匿名)+ ACL 三档 + `{mac_id}` 隔离(§4/§6)
- [ ] `MqttChannel`(CocoaMQTT + `ExternalChannel`,**出站 `mqtts://` 连云**,每命令派发独立 worker)+ Config `mqtt` 段(endpoint/凭证/`allowRemoteWrite`)+ `ExternalChannelType` 加 `case mqtt`
- [ ] 出站发布:`pane/{id}/status`(retained)+ `message` + `event`;`presence`(LWT);`worktree/{id}/status`;`focus`(单焦点选择算法)
- [ ] 入站命令:复用 `ControlRouter` A 表现成 method(`pane.send_text` 等)
- [ ] per-pane JSONL 环形缓冲 + `history/request` 应答
- [ ] 隐私:message/last_message 发布前脱敏开关(§0 提示);为敏感用户预留"自托管 NanoMQ"配置项

### Phase 1 — Apple Watch(商业主线)
> 依赖 Phase 0。完成标志:配对后腕上看状态+最终消息,能 2FA/快速回复,关键事件推送到腕上。

- [ ] **服务端新增 handler**:`question.answer` / `suggest.pick`(抽 `MainWindowController.handleSuggestionTapped` 逻辑为非 UI 可达)+ questionId 方案 → 支撑 **2FA 与 order pick**
- [ ] **focus/DND 子系统**:`dnd.set` + `dnd/state` + hook `NotificationManager.shouldNotify`(被拦计数)→ 支撑 **专注**
- [ ] QR 配对流程(一次性密钥 → 长期 MQTT 凭据 + broker ACL 绑定)
- [ ] **APNs**:Mac 端直发关键状态变更(离线唤醒;需 Apple push key —— 零服务端的唯一例外)
- [ ] Watch app:CocoaMQTT/WS、会话列表(retained)、worktree→pane、快速回复(`command`)、2FA(`question.answer`)、focus
- [ ] 上架:Apple 开发者号 + App Store 审核

### Phase 2 — ESP32(HaiTalk,营销 halo;已 M1)
> 依赖 Phase 0,复用 Phase 1 的 handler。完成标志:萌宠随真实 agent 状态变,可作 demo/周边。

- [ ] M2 接入:`sh_data` 由 retained `pane/+/status` + `focus` 填充;overlay 由 `pane/{id}/event` 触发
- [ ] 三功能全走已建通道:直接命令(`pane.send_text`)、物理 2FA(`question.answer`)、专注(`dnd.set`/`dnd/state`)
- [ ] CJK 升级:M1 的子集字体 → FreeType 全字库(任意 agent 中文输出)
- [ ] 范围收敛:通话 / 团队心跳-点名 / 广播 / 晨报 标记"暂缓,另开 issue"(见附 B)

### 关键路径与复用
```
Phase 0 后端 ─┬─► Phase 1 Watch(+ question.answer/suggest.pick、focus、QR、APNs)
              └─► Phase 2 ESP32(复用 Phase 1 的 question.answer/focus,几乎只剩客户端接线)
```
Phase 1 建的 `question.answer` / focus 子系统,Phase 2 直接复用 —— 所以 Watch 先做不仅商业优先,
技术上也**替 ESP32 铺好了服务端**,ESP32 的 M2 主要只是客户端接线 + 字体升级。

---

## 15. 协议报文规范(Normative)

字段以现有 Swift 序列化为**唯一真相**:出站 = `PaneSnapshot.dict`(`ControlProtocol.swift:24`)/ `ShipLog.event(from:)`(`ShipLog.swift:382`);命令 = `ControlRouter.handle`(`ControlProtocol.swift:152`)。

### 15.0 通用约定
- **库 & 特性集**:Apple 端(Seahelm + Watch)用 **CocoaMQTT**;只用 **MQTT 3.1.1 的最小特性集**(retained / LWT / QoS1),**不依赖 MQTT 5 properties** —— 兼容 ESP32 原生 MQTT、绕开各库 MQTT5 完整度差异。
- **请求-应答关联**:命令/历史请求在 **payload 内自带** `reply_to`(应答发往的 topic)+ `corr`(关联 id),取代 MQTT5 的 Response-Topic/Correlation-Data 与 socket 的 `id`。
- **seq**:所有出站带全局递增序号(`EventHub`/`IngestOutcome.seq`),客户端幂等去重/判续传。
- 命令 payload = `{ "method": <string>, "params": <object>, "reply_to": <topic>, "corr": <string> }`(method/params 与 socket `params` 一字不差)。
- 应答 payload = 成功 `{ "ok":true, "result":{…}, "corr":<string> }` / 失败 `{ "ok":false, "error":{ "code","message" }, "corr":<string> }`。

### 15.1 出站报文(Seahelm → client)
| topic | 字段 | 说明 |
|---|---|---|
| `presence` | `{online, seq}` | LWT 预置 offline;连上发 online |
| `pane/{id}/status` | `PaneSnapshot.dict` + `seq` | retain;空 payload = 墓碑 |
| `pane/{id}/message` | `ShipLog.event(from:)` + `seq` | |
| `pane/{id}/event` | 见 15.1.1 | question/suggest/notification |
| `worktree/{id}/status` | `{worktree_id, worktree_path, branch, project, status, pane_count, seq}` | Aggregator 汇总;retain |
| `focus` | 见 §5 | 单焦点+counts;retain |
| `dnd/state` | `{on, ends_at_epoch, blocked_count, seq}` | C7;retain |

#### 15.1.1 `pane/{id}/event`
```jsonc
{ "type":"pane.status_changed", "seq":1042, "pane_id":"p3", "session_name":"…",
  "status":"waiting", "old_status":"running", "agent_type":"claude",
  "worktree_path":"…", "last_message":"…" }
{ "type":"question", "seq":1044, "pane_id":"p3", "question_id":"<可回传 id>",
  "prompt":"prod-deploy 需要你在场", "options":["批准","拒绝"], "danger":true }
{ "type":"suggest", "seq":1043, "pane_id":"p3", "suggest_id":"<可回传 id>",
  "options":["跑测试","提交并推送"], "message":"<最近助手总结>" }
```
> `question_id`/`suggest_id`:本地 order id 是确定性组合键 `worktreePath#kind#terminalID#payloadHash`(`PendingOrdersQueue.swift:36`),需 base64 编码为可回传 id,服务端回查驱动原 TUI。**新增工作**(§12.4 / Phase 1)。

### 15.2 命令(client → `command`)
**A. 现成 method**(`ControlRouter` 已实现,原样转交):

| method | params 必填 | 成功 result | 档位 |
|---|---|---|---|
| `ping` | — | `{pong:true}` | Read |
| `session.snapshot`/`pane.list` | — | `{panes:[…]}` | Read |
| `pane.read` | `pane_id`(+source/lines) | `{text}` | Read |
| `pane.send_text` | `pane_id`,`text`(+enter) | `{sent:true}` | **Control** |
| `pane.run` | `pane_id`,`text`/`command` | `{sent:true}` | **Control** |
| `pane.send_keys` | `pane_id`,`keys` | `{sent:true}` | **Control** |
| `pane.split` | (pane_id/direction/focus) | `{pane_id:<new>}` | **Control** |
| `pane.zoom` | (pane_id/mode) | `{zoomed:bool}` | **Control** |
| `pane.close`/`pane.focus` | `pane_id` | `{closed/focused:true}` | **Control** |
| `pane.options` | `pane_id` | `{options:[{index,label,selected}]}` | Read |
| `pane.explain`/`agent.explain` | `pane_id` | `<dict>` | Read |
| `layout.export` | — | `<dict>` | Read |
| `layout.apply` | `root` | `{applied:true}` | **Control** |
| `suggest` | `options:[string]` | `{accepted:true}` | **Control** |

> ⚠️ `wait.output`/`wait.agent_status` **阻塞调用线程**(`Thread.sleep` 轮询,`ControlProtocol.swift:320`)。MqttChannel 必须每命令派发独立 worker,否则卡死全部 MQTT。远程建议默认不开。

**B. 新增 method**(服务端尚无 handler,Phase 1 建):

| method | params | result | 现状 |
|---|---|---|---|
| `question.answer` | `question_id`,`index` | `{answered:true}` | 2FA;抽 `handleSuggestionTapped`→`answerChoiceByArrows`/数字键 |
| `suggest.pick` | `suggest_id`,`index` | `{picked:true}` | First Mate 选 order;同上新建 |
| `dnd.set` | `on`(+minutes) | `{on, ends_at_epoch}` | 专注;新建 focus 子系统 |

> 交互档只允许 A 的 Read + B 的 `question.answer`/`suggest.pick`(引用式);Control 档才允许 `pane.send_text` 等自由输入。

### 15.3 历史查询(`history/request` → `reply`)
```jsonc
{ "pane_id":"p3", "limit":50, "before_seq":1042, "reply_to":"seahelm/{mac}/reply/{client}/{corr}", "corr":"h1" }  // 请求
{ "ok":true, "result":{ "messages":[…], "has_more":true }, "corr":"h1" }                                         // 应答
```
数据来自本地 per-pane JSONL(§12.2)。**Mac 离线查不到历史**(retained 状态仍在)。

### 15.4 字段参考(逐字对齐源码)
- `PaneSnapshot.dict`:`pane_id`·`session_name`·`worktree_path`·`branch`·`project`·`agent_type`·`status`·`last_message`(+发布侧 `seq`)。
- `ShipLog.event(from:)`:`type`(`pane.status_changed`|`pane.updated`)·`seq`·`pane_id`·`session_name`·`status`·`old_status`·`agent_type`·`worktree_path`·`last_message`。
- `status`/`old_status` = `SailorStatus.rawValue`;`agent_type` = `AgentType.rawValue`(映射见附 A)。

### 15.5 错误码(`ControlError` + 设计层补充)
| code | 名称 | 含义 |
|---|---|---|
| -32700 | parse | JSON 解析失败 |
| -32600 | invalidRequest | 请求非法 |
| -32601 | methodNotFound | 未知 method |
| -32602 | invalidParams | 参数缺失/非法 |
| -32004 | notFound | pane 不存在/已关闭 |
| -32003 | capability_denied | 档位不足 / `allowRemoteWrite=false`(新增) |
| -32002 | stale_suggest | suggest/question 过期,天然确认窗口(新增) |

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
