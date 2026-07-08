# Socket hook 实测清单

验证控制 socket + hook 迁移(command-over-socket)工作正常,**再**决定删除 HTTP/WebhookServer。
全程需要 seahelm app **正在运行**(socket server 随 app 启动)。

约定:
```sh
SOCK="$HOME/.config/seahelm/seahelm.sock"
send() { printf '%s\n' "$1" | nc -U "$SOCK"; }   # 发一条请求、打印响应 (Apple nc: 不加 -N/-w)
```

---

## A. socket 基础(读侧)

- [ ] **socket 存在且权限 0600**
  ```sh
  ls -l "$SOCK"    # 期望: srw------- ... seahelm.sock
  ```
- [ ] **ping**
  ```sh
  send '{"id":"1","method":"ping"}'
  # 期望: {"id":"1","result":{"pong":true}}
  ```
- [ ] **session.snapshot 列出当前 pane**
  ```sh
  send '{"id":"2","method":"session.snapshot"}'
  # 期望: {"id":"2","result":{"panes":[{"pane_id":"...","status":"...","agent_type":"...",...}]}}
  ```
  记下某个 `pane_id` 供下一步用。
- [ ] **pane.read 读某个 pane 的终端文本**
  ```sh
  send '{"id":"3","method":"pane.read","params":{"pane_id":"<粘贴 pane_id>","lines":20}}'
  # 期望: {"id":"3","result":{"text":"...最近 20 行..."}}
  ```
- [ ] **未知方法 / 缺参 返回 error**
  ```sh
  send '{"id":"4","method":"bogus"}'                       # error code -32601
  send '{"id":"5","method":"pane.read","params":{}}'       # error code -32602 (pane_id required)
  ```

## B. pane 环境注入（①）

在一个**由 seahelm 启动了 agent 的 pane 里**(claude/codex),执行:
- [ ] **SEAHELM_ENV / SEAHELM_SOCKET_PATH 已注入**
  ```sh
  echo "env=$SEAHELM_ENV sock=$SEAHELM_SOCKET_PATH"
  # 期望: env=1 sock=/Users/<you>/.config/seahelm/seahelm.sock
  ```
  > 注:只有走 `zmx run` 启动的 agent pane 会有;纯 `zmx attach` 的普通 shell 不会。

## C. suggest 上 socket（fire-and-forget）

- [ ] **socket suggest 方法直接可用**
  ```sh
  send '{"id":"6","method":"suggest","params":{"options":["选项一","选项二"],"cwd":"'"$PWD"'"}}'
  # 期望: {"id":"6","result":{"accepted":true}}  且 UI 里 first mate 弹出两个按钮
  ```
- [ ] **seahelm-suggest 脚本走 socket**（在有 socket 的目录跑)
  ```sh
  seahelm-suggest '做 A' '做 B'
  # 期望: UI 出现按钮。脚本内优先 nc -U;socket 存在时不应打 HTTP。
  ```
- [ ] **（可选）确认没走 HTTP**:临时把 socket 改名,再跑 seahelm-suggest,应回退 HTTP 仍出按钮;测完改回。
  ```sh
  mv "$SOCK" "$SOCK.bak"; seahelm-suggest 'fallback 测试'; mv "$SOCK.bak" "$SOCK"
  ```

## D. hook 迁移 + 阻塞语义（②，关键）

- [ ] **Claude settings 已是 command hook**
  ```sh
  python3 -c "import json;print(json.load(open('$HOME/.claude/settings.json'))['hooks']['Stop'])" 2>/dev/null \
    || grep -A4 '"Stop"' "$HOME/.claude/settings.json"
  # 期望: type=command, command=".../.local/bin/seahelm-hook"
  ```
- [ ] **seahelm-hook 手动模拟 Stop → 打印 block 决策到 stdout**
      (需 config 里 suggestOnStop 开启;非 agentStop / stop_hook_active=true / 结尾问号 不该阻塞)
  ```sh
  # 应阻塞:打印 {"decision":"block","reason":"...seahelm-suggest..."}
  echo '{"hook_event_name":"Stop","session_id":"t","cwd":"'"$PWD"'","stop_hook_active":false,"last_assistant_message":"done"}' | seahelm-hook

  # 不应阻塞:stop_hook_active=true → 无输出
  echo '{"hook_event_name":"Stop","session_id":"t","cwd":"'"$PWD"'","stop_hook_active":true}' | seahelm-hook

  # 不应阻塞:结尾问号(agent 在问用户)→ 无输出
  echo '{"hook_event_name":"Stop","session_id":"t","cwd":"'"$PWD"'","stop_hook_active":false,"last_assistant_message":"要我继续吗?"}' | seahelm-hook
  ```
- [ ] **真实 Claude 会话端到端**(最关键,替代不了):
  1. 在一个 claude pane 里让它做个小任务并让它自然结束一轮;
  2. 期望:Stop 被阻塞,claude 继续并调用 `seahelm-suggest`,UI 弹出按钮;
  3. 点一个按钮,claude 收到对应下一步。
- [ ] **base64 往返无损**(block reason 含引号/特殊字符也不炸):上面手动 Stop 的输出应为**合法 JSON**、无多余换行:
  ```sh
  echo '{"hook_event_name":"Stop","session_id":"t","cwd":"'"$PWD"'","stop_hook_active":false,"last_assistant_message":"done"}' \
    | seahelm-hook | python3 -m json.tool    # 能 parse 即通过
  ```

## E. 其它 hook 事件不回归

- [ ] 正常用一会儿 claude(触发 PreToolUse/PostToolUse/UserPromptSubmit),观察:
  - [ ] 状态检测/通知照常(hook 事件确实到达了 seahelm);
  - [ ] **无明显卡顿**(每个 hook 走 `nc -U`,正常应 sub-ms;若感到工具调用变慢,检查 socket server 是否响应及时)。

---

## 全绿之后的收尾(才可以删 HTTP)

1. 迁移 **Codex** hook 到 socket(`~/.codex/hooks.json` + config.toml,机制不同,需单独适配 seahelm-hook)。
2. 删除 `WebhookServer` 的实例化 + `WebhookServer.swift`;删掉 `seahelm-hook`/`seahelm-suggest` 脚本里的 HTTP 兜底分支;移除 `ClaudeHooksSetup` 里已无用的 port 依赖。
3. `config.webhook` 若无其它用途一并清理。

> 任一 D 项失败,**不要删 HTTP**——保留兜底,回到 seahelm-hook 脚本 / router `hook` 方法排查。
