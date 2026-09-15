# Socket hook 实测清单

验证控制 socket + hook 迁移(command-over-socket)工作正常。全程需要 seahelm
app 正在运行(socket server 随 app 启动)。

约定:

`sh
SOCK="$HOME/.config/seahelm/seahelm.sock"
send() { printf '%s\n' "$1" | nc -U "$SOCK"; }
`

## A. socket 基础

- [ ] socket 存在且权限 0600
  `sh
  ls -l "$SOCK"
  `
- [ ] ping
  `sh
  send '{"id":"1","method":"ping"}'
  # 期望: {"id":"1","result":{"pong":true}}
  `
- [ ] session.snapshot 列出当前 pane
  `sh
  send '{"id":"2","method":"session.snapshot"}'
  `
- [ ] pane.read 读某个 pane 的终端文本
  `sh
  send '{"id":"3","method":"pane.read","params":{"pane_id":"<pane_id>","lines":20}}'
  `

## B. suggest 上 socket

- [ ] socket suggest 方法直接可用
  `sh
  send '{"id":"6","method":"suggest","params":{"options":["选项一","选项二"],"cwd":"'"$PWD"'"}}'
  # 期望: result.accepted=true 且 UI 里弹出两个按钮
  `
- [ ] seahelm-suggest 脚本走 socket
  `sh
  seahelm-suggest '做 A' '做 B'
  # 期望: UI 出现按钮
  `

## C. hook 上报

- [ ] Claude/Codex settings 已安装 Stop command hook
  `sh
  python3 -c "import json;print(json.load(open('$HOME/.claude/settings.json'))['hooks']['Stop'])" 2>/dev/null
  `
- [ ] seahelm-hook 手动模拟 Stop 不产生 stdout
  `sh
  echo '{"hook_event_name":"Stop","session_id":"t","cwd":"'"$PWD"'","last_assistant_message":"done"}' | seahelm-hook
  # 期望: 无输出；事件仍到达 seahelm
  `
- [ ] 带行内建议的最终回复能产生按钮
  `sh
  echo '{"hook_event_name":"Stop","session_id":"t","cwd":"'"$PWD"'","last_assistant_message":"done\n::seahelm-suggest:: run tests | open PR"}' | seahelm-hook
  # 期望: 无输出；UI 出现两个按钮
  `

Stop 是观察 hook，不会返回 decision:block，也不会因为缺少建议而发起
第二轮 agent 回复。无建议的回复仍然是正常完成。

## D. 其它事件不回归

- [ ] 触发 SessionStart/UserPromptSubmit/PreToolUse/PostToolUse，确认状态检测和通知照常。
- [ ] 正常使用时无明显卡顿；每个事件通过 Unix socket fire-and-forget 上报。
