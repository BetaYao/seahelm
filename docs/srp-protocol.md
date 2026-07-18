# Seahelm Remote Protocol (SRP) v1

对外远程协议设计。参考 Zed ACP(Agent Client Protocol)的核心思路 —— JSON-RPC 2.0
语义、双向消息、能力协商、会话化 —— 但 ACP 是 stdio 上的本地协议,SRP 面向跨网远程
客户端(手机、网页、脚本、ESP32 嵌入式设备)。

## 总体结构:一份 IDL,三种承载

以 protobuf(proto3)作为唯一 schema 源,JSON 表示使用 proto3 标准 JSON 映射生成,
避免两套定义漂移:

```
        ┌─ 语义层:JSON-RPC 2.0 方法/通知/错误码(与 ACP 同构)
协议 ───┼─ 编码层:JSON(默认)或 protobuf 二进制(协商后切换)
        └─ 传输层:WebSocket(主) / HTTP+SSE(受限客户端) / MQTT(嵌入式)
```

对外协议是现有 Unix 控制 socket(`Sources/Core/ControlProtocol.swift`)的**超集**:
其方法表已是 `{"id","method","params"}` 形式,补上 `"jsonrpc":"2.0"` 字段即为合法
JSON-RPC,不另起一套。

## 1. 连接与握手

客户端连接后必须先发 `initialize`(仿 ACP):

```jsonc
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
     "protocolVersion": 1,
     "clientInfo": {"name":"stopwatch","kind":"device"},
     "encodings": ["json","protobuf"],
     "capabilities": {"subscribe":true, "paneWrite":false, "suggestPick":true},
     "token": "srp_xxx"                      // WebSocket/MQTT 时放这里;HTTP 走 Authorization 头
  }}
← {"jsonrpc":"2.0","id":1,"result":{
     "protocolVersion": 1,
     "encoding": "json",                     // 服务端选定
     "serverInfo": {"name":"seahelm","version":"0.9"},
     "capabilities": {"events":["status","suggest","question","notification"],
                      "methods":["session.snapshot","pane.read","pane.run", "..."]}
  }}
```

- 版本协商:整数 `protocolVersion`,不匹配直接以错误关闭连接。
- 能力协商决定后续行为:未获授权的方法调用返回 `-32003 capability_denied`。
- 协商 `encoding:"protobuf"` 后,WebSocket 切二进制帧,payload 为 `Envelope`(见 §4)。

## 2. 方法(request/response,客户端 → seahelm)

沿用现有命名空间,按权限分三档:

| 档位 | 方法 | 说明 |
|---|---|---|
| 只读 | `session.snapshot` `pane.list` `pane.read` `pane.explain` `layout.export` | 观察 |
| 交互 | `suggest.pick` `question.answer` | 只能从服务端下发过的选项里选 |
| 控制 | `pane.run` `pane.send_text` `pane.send_keys` `pane.split` `pane.zoom` `pane.focus` `pane.close` `layout.apply` | 等价于坐在电脑前 |

交互档是安全设计的关键:`suggest.pick {suggestId, index}` 与
`question.answer {questionId, index}` 只引用服务端此前下发的 ID,不接受自由文本 ——
凭据泄露时攻击面仅限于"替你点了一个已存在的按钮"。

```jsonc
→ {"jsonrpc":"2.0","id":7,"method":"suggest.pick","params":{"suggestId":"s-88","index":1}}
← {"jsonrpc":"2.0","id":7,"result":{"accepted":true}}
```

## 3. 事件(通知,seahelm → 客户端,无 id)

订阅制:

```jsonc
→ {"jsonrpc":"2.0","id":2,"method":"subscribe","params":{
     "topics":["status/*","suggest/*","question/*"],
     "scope":{"repo":"seahelm"},
     "sinceSeq": 1042                        // 断线重连时续传;首次连接省略
  }}
```

事件源为内部 `NormalizedEvent`,一一映射:

```jsonc
← {"jsonrpc":"2.0","method":"event.status","params":{
     "repo":"seahelm","worktree":"main","pane":"p3",
     "status":"waiting","agent":"claude","seq":1042,"ts":"2026-07-18T09:30:00Z"}}
← {"jsonrpc":"2.0","method":"event.suggest","params":{
     "suggestId":"s-88","pane":"p3","options":["跑测试","提交并推送"],"seq":1043}}
← {"jsonrpc":"2.0","method":"event.question","params":{
     "questionId":"q-12","pane":"p3","prompt":"覆盖已有分支?","options":["是","否"],"seq":1044}}
← {"jsonrpc":"2.0","method":"event.notification","params":{
     "level":"error","text":"…","pane":"p3","seq":1045}}
```

**续传语义**:每个事件带全局递增 `seq`。服务端保留环形缓冲(最近 512 条);
`sinceSeq` 落在窗口内则补发缺口,超出窗口回 `{"snapshotRequired":true}`,客户端应
重新调用 `session.snapshot` 全量对齐。这是 WiFi 频繁掉线的嵌入式设备可靠性的核心。

## 4. 编码层:proto 骨架

完整定义放 `Protos/srp.proto`,骨架如下:

```protobuf
syntax = "proto3";
package seahelm.v1;

message Envelope {            // WebSocket 二进制帧 / MQTT payload 统一外壳
  oneof kind {
    Request request = 1;
    Response response = 2;
    Event event = 3;
  }
}
message Request  { string id = 1; string method = 2; bytes params = 3; }
message Response { string id = 1; oneof r { bytes result = 2; Error error = 3; } }
message Error    { int32 code = 1; string message = 2; }
message Event    { string topic = 1; uint64 seq = 2; bytes payload = 3; }

enum PaneStatus { PANE_STATUS_UNKNOWN = 0; RUNNING = 1; WAITING = 2; DONE = 3; FAILED = 4; }
message StatusEvent   { string repo = 1; string worktree = 2; string pane = 3; PaneStatus status = 4; string agent = 5; }
message SuggestEvent  { string suggest_id = 1; string pane = 2; repeated string options = 3; }
message QuestionEvent { string question_id = 1; string pane = 2; string prompt = 3; repeated string options = 4; }
```

JSON 客户端不接触 proto,直接按 §1–3 的 JSON-RPC 使用;proto 客户端(ESP32 用
nanopb,`StatusEvent` 解码仅需几百字节 RAM)获得同一份语义。

## 5. 传输层矩阵

| 传输 | 场景 | 说明 |
|---|---|---|
| **WebSocket** `wss://…/srp` | 主通道:手机 app、网页、局域网设备 | 全双工;文本帧 = JSON,二进制帧 = protobuf `Envelope` |
| **HTTP** `POST /srp/rpc` + `GET /srp/events`(SSE) | 脚本、curl、无 WS 能力的客户端 | 同一 JSON-RPC body;SSE 单向推事件,`Last-Event-ID` 对接 `seq` 续传 |
| **MQTT 桥** | ESP32 / M5Stack StopWatch 跨网 | broker 上 `srp/<deviceId>/tx` 与 `srp/<deviceId>/rx` 承载同样的 `Envelope`(protobuf);seahelm 侧 `MqttChannel` 做桥;状态另发 retain 的 `srp/state/<repo>/<worktree>` 供设备上线即显 |

跨局域网:WebSocket/HTTP 端点经 VPS 反代或 Cloudflare Tunnel 转发回 Mac;MQTT 天然
经 broker 中转。三条路复用同一语义层。

## 6. 鉴权与安全

- **Bearer token per client**:token 绑定能力档位(只读 / 交互 / 控制)。
  设备(手表)发交互 token;本人手机发控制 token。
- 全链路 TLS;MQTT 桥使用 broker 的 mTLS + ACL,限定每设备只能访问 `srp/<deviceId>/#`。
- 控制档方法可配置为需要本机确认:seahelm 通知面板弹出
  "允许 stopwatch 执行 pane.run?"。

## 7. 错误码

沿用 JSON-RPC 保留段(现有 `ControlError` 已用 `-32601`),业务错误自 `-32000` 起:

| code | 名称 | 含义 |
|---|---|---|
| -32600/-32601/-32602/-32700 | JSON-RPC 标准 | invalid request / method not found / invalid params / parse error |
| -32001 | `unknown_pane` | pane 不存在或已关闭 |
| -32002 | `stale_suggest` | suggest/question 选项已过期 |
| -32003 | `capability_denied` | token 档位不足或未协商该能力 |
| -32004 | `seq_gap_unrecoverable` | 续传窗口外,需重新 snapshot |

## 8. 实施顺序

1. 现有 socket handler 外包一层 JSON-RPC 2.0 兼容壳(近零成本)。
2. WebSocket 服务端 + token / 能力档。
3. `Protos/srp.proto` 定稿,生成 JSON / 二进制两套编码。
4. MQTT 桥(`MqttChannel`,实现 `ExternalChannel`)对接 StopWatch。
