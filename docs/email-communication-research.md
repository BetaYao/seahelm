# Seahelm 邮箱会话通信：一手文档调研（2026-08-05）

## 结论先行

“绑定一个邮箱、所有会话可经邮箱交流”应被拆成两个能力：

1. **出站通知**：Seahelm 把某 pane 的可读状态/问题发到用户邮箱；
2. **受控入站命令**：用户回复一封已关联邮件后，Seahelm 将其作为该 pane 的输入。

建议先做 **Gmail 账户连接 + 轮询同步 + 每 pane 一条持续的 email thread** 的 MVP；仅允许
“等待输入”的 pane 接收来自已绑定地址的纯文本回复，且在写入终端前展示/确认。macOS 自带
MailKit 或分享面板都不能提供所需的通用收信+静默发信能力。若产品要求 app 未运行时即时处理、
或要给每个会话分配可回信的独立地址，则需要一个 HTTPS 后端和专门的入站邮件服务，而不只是
原生 macOS 客户端。

Seahelm 已有 `ShipLog` 作为会话状态真源、`ControlRouter.pane.send_text` 作为向 pane 发送文本的
入口（见 `docs/technical-design.md`、`docs/remote-clients-design.md`）；邮件适合作为另一个受控
adapter，而不是再建一套 session 状态。

## 平台边界

| 方案 | 能做什么 | 为什么不足以实现目标 |
| --- | --- | --- |
| `NSSharingService` / `NSSharingServiceNameComposeEmail` | 交给 Mail 等 app 弹出邮件撰写 sheet；Apple 明确把它定义为分享内容并显示 sheet，ComposeEmail 是“撰写 email”的服务。([Apple: NSSharingService](https://developer.apple.com/documentation/appkit/nssharingservice), [ComposeEmail](https://developer.apple.com/documentation/appkit/nssharingservice/name/composeemail)) | 每封需用户交互；没有读取邮箱、追踪回复或后台入站通道。只适合“导出/转发当前会话”。 |
| MailKit | Mail app extension 可做内容拦截、下载时 action、撰写校验/自定义头、消息安全处理。([Apple: MailKit](https://developer.apple.com/documentation/mailkit)) | 扩展运行在 Apple Mail 的能力模型内；文档所列能力不是 Seahelm 作为独立 client 对任意邮箱的收发 API。 |
| 账户提供商 API | Gmail/Graph 以 OAuth 授权后可发信、读信、建立增量同步。([Gmail messages list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list), [Graph get message](https://learn.microsoft.com/en-us/graph/api/message-get?view=graph-rest-1.0)) | 需提供商逐一接入、OAuth 同意及令牌生命周期；不是“绑定任意 IMAP/SMTP 邮箱”就免费成立。 |

## 推荐的 Gmail MVP

### 授权与存储

- 使用 Google 的 **Desktop app OAuth 2.0 Authorization Code + PKCE**。Google 将 loopback redirect 列为 macOS/Linux/Windows desktop 的推荐用法，并说明 installed app 无法保守 client secret；每次授权应使用高熵 `code_verifier` 和推荐的 S256 challenge。([Google: OAuth 2.0 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app))
- 可用 macOS `ASWebAuthenticationSession` 启动第三方网页登录；在 macOS 会打开默认浏览器或 Safari，并把 callback URL 交回发起 app。([Apple: ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession))
- 最小 scope 从 `gmail.send`（出站）与 `gmail.readonly`（读/同步）开始；如果需要自动加标签、标已处理/已读，才升级 `gmail.modify`。`users.messages.list` 明确列出这些读权限及 `mail.google.com`，且 metadata scope 不能搭配搜索 `q`。([Google: list messages](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list)) `gmail.send` 属 Sensitive scope，`gmail.readonly`/`gmail.modify` 等读 scope 属 Restricted；外部发布前应把 OAuth verification 与（若在 server 储存/传输 restricted data）安全评估列为上线门槛。([Google: Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes), [Google: verification requirements](https://support.google.com/cloud/answer/13464321))
- access/refresh token 只放 Keychain，不写进 Seahelm 的 JSON config 或日志；Keychain 是系统加密的机密存储，Apple 的示例以 `SecItemAdd` 保存网络凭据。([Apple: Keychain Services](https://developer.apple.com/documentation/security/keychain-services), [Adding a password](https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain))

### 线程和同步设计

为每个 `pane_session_key` 建一个 `EmailConversation`，存 provider message/thread ID、最后处理的
入站 message ID、方向、状态与审计时间；不要以可变 `pane_id` 作长期关联键。出站使用固定主题如
`[Seahelm <短码>] <repo>/<branch>`，优先复用 provider thread ID，并在正文带上不可伪造的会话短码
供人工恢复。入站只接受与该 thread/短码匹配、来源为绑定账号允许地址的 **新** message；以 message ID
去重，保存同步 cursor/history ID 后再执行，避免重启重放。

Gmail 发送应构造 RFC 2822 MIME、base64url 放入 `Message.raw` 后调用 `users.messages.send`。要让 Gmail
归入既有 thread，除了提供 `threadId`，subject 必须匹配，且 MIME 的 `In-Reply-To` 与 `References` 必须
符合 RFC 2822。([Google: sending email](https://developers.google.com/workspace/gmail/api/guides/sending), [Google: messages.send](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/send))

Gmail `messages.list` 每个结果只给 `id` 和 `threadId`，正文必须再 `messages.get`；列表可用 Gmail
搜索语法及 label 过滤。([Google: list messages](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages/list))
因此 MVP 可在 app 存活时每 30--60 秒按关联 thread/label 拉取；首次连接从“现在”建立 cursor，绝不把
旧收件箱邮件当作 agent 输入。

Gmail 增量同步应持久化 `historyId`，收到变化后用 `history.list(startHistoryId)` 拉取；历史记录可能
消失（通常至少一周、也可能更短），`404` 时必须全量重同步。([Google: synchronize clients](https://developers.google.com/workspace/gmail/api/guides/sync))

Gmail 的 `watch` 不是桌面客户端直连推送：它把通知交给同一 Google Cloud project 的 Cloud Pub/Sub，且官方明确表示对于
installed app/移动端/浏览器等用户设备，仍推荐 poll-based sync。([Google: Gmail push notifications](https://developers.google.com/workspace/gmail/api/guides/push))
所以 **不应** 为了 MVP 在本机暴露公网 webhook；若以后有常驻后端，可由后端接 Pub/Sub 后触发增量
history 同步，再在 Seahelm 启动时补拉。watch 响应带 `historyId` 和 expiry、成功时会立即发一条通知；
Google 要求至少每七天续订并建议每日续订。([Google: users.watch](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/watch), [Google: Gmail push notifications](https://developers.google.com/workspace/gmail/api/guides/push))

### 发送与失败语义

发送端要把“请求已接受”与“邮件已送达”分开：Microsoft Graph `sendMail` 的 `202 Accepted` 明确不表示
交付完成，Gmail/SMTP 同样应把 provider 接受、可见于 Sent、退信/失败作为不同状态。出站事件应当
按 session 节流并合并，不能把每次 viewport 刷新转为邮件。

## Microsoft 365（第二提供商，而非 MVP 前置条件）

- Graph 的 `POST /me/sendMail` 接受 JSON 或 MIME；最小 delegated permission 是 `Mail.Send`，成功返回
  `202 Accepted`，默认保存 Sent Items。([Microsoft: sendMail](https://learn.microsoft.com/en-us/graph/api/user-sendmail))
- 收信读取 `GET /me/messages/{id}` 需要 delegated `Mail.ReadBasic` 或 `Mail.Read`；取完整 MIME 使用
  `/$value`。要解析引用链/原始 headers 时应选后者，而不是仅信任展示字段。([Microsoft: get message](https://learn.microsoft.com/en-us/graph/api/message-get))
- Graph 可把 Outlook message 变更送往 **HTTPS** `notificationUrl`；subscription 有限期且 Outlook
  message/event/contact 最长 10,080 分钟（少于七天），含资源数据的 rich notification 最长 1,440 分钟。
  因此必须有公网可用后端、验证请求来源、续订 job 和失效后的补同步；桌面 app 不能可靠充当这个 endpoint。
  ([Microsoft: subscription resource](https://learn.microsoft.com/en-us/graph/api/resources/subscription), [Outlook change notifications](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview))

## 不可省略的产品与安全决策

1. **谁能回信？** 只允许绑定地址本人，还是 allowlist 多人？`From` 显示名不足以鉴权；必须按 provider
   已认证 mailbox 中的地址、thread 和一次性/高熵关联码共同判定。
2. **回信能做什么？** 推荐 v1 仅把纯文本作为 waiting pane 的候选输入。禁止把 HTML、附件、转发内容、
   自动回复或任意邮件直接当 shell/agent 指令。将它当不可信用户输入；对于 destructive command、agent
   approval 或跨 repo 操作，仍要求 Seahelm UI 本地确认。
3. **如何避免误投递？** 一个会话只能有一个活动 email conversation；pane 结束/恢复/关闭后应停止接收或
   进入显式 “reopen” 流程。保留可撤销审计：原 message ID、解析文本、目标 `pane_session_key`、投递结果。
4. **隐私与噪声预算？** 默认发最终回复、等待输入和错误，正文截断并显式标注仓库/分支是否可泄露；不要默认
   转发终端全屏、diff、token 或密钥。用户可设每 session 的开关、收件人和速率上限。
5. **“一个邮箱”是什么意思？** 若是“连接用户自己的 Gmail/Outlook”，上面的 OAuth adapter 足够；若是
   “Seahelm 托管一个 `reply+<session>@…` 地址”，则需购买/运营发信域、MX 入站、DKIM/SPF/DMARC、反滥用
   与持久化后端——这是不同级别的产品和合规承诺。

## 建议的验收线

- 连接/断开 Gmail 不泄露令牌，断开同时清 Keychain、同步 cursor 与本地关联。
- 对一个 waiting pane 发一封通知；用户从绑定 Gmail 回复一次，Seahelm 仅投递一次到正确
  `pane_session_key`，并显示已投递审计。
- 无 thread、旧邮件、不同来源、HTML/附件、自动回复、pane 非 waiting、重复 message ID 均不投递，
  而是留下可解释的拒绝状态。
- 离线、token 失效、发送被接受但无法证实送达、重启及增量 cursor 失效都有可见且可恢复的状态，绝不静默
  重放邮件。
