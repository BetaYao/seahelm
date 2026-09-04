# Seahelm

一个为 coding agent、git worktree 和并行开发准备的原生 macOS 工作台。

[English](README.md) · [网站](https://www.seahelm.dev/zh/)

## Demo

![Seahelm demo](assets/tour.gif)

完整演示：[YouTube](https://youtu.be/WUUcuglx_Ks)

## 为什么选择 Seahelm

- **简洁** — 没有复杂的代码编辑和 diff review,一切都交给 agent,界面不挡路。
- **高性能** — macOS 原生,基于 Ghostty 终端和 AppKit 渲染,低延迟、响应快。
- **兼容性** — 兼容多达 12 种 coding agent,不绑死在单一平台。

## 安装

```bash
curl -fsSL https://seahelm.dev/install.sh | sh
```

或从 [GitHub Releases](https://github.com/BetaYao/seahelm/releases/latest) 手动下载。

## 截图

### Workspace

![Workspace](assets/screenshots/workspace.png)

### 文件浏览 & 代码编辑

![File browser and code editor](assets/screenshots/code-editor.png)

### Tab 布局

![Tab layout](assets/screenshots/tab-layout.png)

## 功能

**工作区 & 分屏** — 多个仓库和 git worktree 各为一个 tab,worktree 内可拆分 pane 让多个 agent 并行推进。

**Agent 状态** — 清单驱动的状态识别,覆盖 12 种 agent:agent、aider、amp、claude、cline、codex、cursor、gemini、goose、kiro、opencode、pi。Claude Code 和 Codex 有原生 hook 集成和建议卡片。

| Agent | 状态识别 | Hook 上报 | 建议卡片 |
|---|---|---|---|
| Claude Code | ✅ | ✅ 原生 hooks | ✅ |
| Codex | ✅ | ✅ 原生 hooks | ✅ |
| opencode | ✅ | ✅ 插件 | ⚠️ 依赖模型自觉 |
| 其他 9 种 | ✅ 屏幕识别 | — | — |

**侧边栏** — 文件树、代码编辑器(CodeEditSourceEditor)、Markdown 预览、git diff 审查,不离开当前 worktree。

**灵动岛** — 屏幕顶部常驻胶囊,平时安静,有事才展开:哪个 worktree 在跑、在等你、出错了。agent 建议弹成可点卡片。

**First Mate** — 观察 pane 状态迁移,生成建议卡片、等待/报错提醒、worktree 回收提示。

**控制接口** — agent 可通过 CLI 驱动 Seahelm:

```bash
seahelm pane list
seahelm pane read <pane> --lines 50
seahelm pane split <pane> --direction right
seahelm pane run <pane> "npm test"
seahelm wait agent-status <pane> --status Idle
seahelm pane explain <pane>       # 这个状态是哪条规则判出来的?
seahelm layout export
```

每个 pane 拿到 `SEAHELM_PANE_ID`。完整命令:`seahelm <ping|session|pane|wait|events|layout>`。

**Token 用量** — Claude 和 Codex 的 token/额度用量在 app 内汇总展示。

**会话持久化** — 由 [zmx](https://zmx.sh) 持久化:关掉 app、重启机器,agent 还在原地。zmx 不可用时降级为普通进程。

## 适合的人

- 重度使用 coding agent 的开发者
- 同时维护多个分支、多个 worktree 的个人和团队
- 已把 AI 辅助编程放进日常工作流的人

## 本地开发

需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

构建(`CodeEditSourceEditor` 需跳过插件校验):

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm \
  -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
```

构建并启动(产物在 `.build/`):

```bash
./run.sh
```

运行 UI 测试:

```bash
./run_ui_tests.sh
```

打当前架构的 release 包:

```bash
./scripts/package_release.sh   # → dist/
```

## 架构

Swift + AppKit,macOS 14.0+,四层结构:

- **App coordinators**(`Sources/App/`)— 窗口、tab、split pane、侧边面板
- **UI 层**(`Sources/UI/`)— dashboard、灵动岛、分屏、标题栏、worktree 侧边栏
- **核心服务**(`Sources/Core/`、`Sources/Status/`)— agent 状态跟踪、状态识别流水线、First Mate 规则引擎、控制 socket
- **终端与系统**(`Sources/Terminal/`、`Sources/Git/`)— Ghostty C API、git worktree 发现

详见 [`CLAUDE.md`](CLAUDE.md),设计文档见 [`docs/`](docs/)。

## 发布

推送 `v*` tag 触发 release workflow,构建 `arm64` 和 `x86_64` macOS 产物。

配置仓库 secrets(`APPLE_CERTIFICATE_P12`、`APPLE_DEVELOPER_IDENTITY`、`APPLE_ID`、`APPLE_TEAM_ID` 等)后,workflow 会自动签名、notarize、staple。

## 许可

Seahelm 以 [MIT License](LICENSE) 发布。

本项目建立在他人的工作之上 —— 主要是 [Ghostty](https://github.com/ghostty-org/ghostty)
终端引擎(MIT)和负责会话持久化的 [zmx](https://zmx.sh)。捆绑的 Swift 包分别采用
MIT、BSD-3-Clause 或 Apache-2.0 协议,各自保留其版权与许可。

随 app 分发的第三方组件 —— Ghostty、zmx、Sparkle 及各 Swift 包 —— 及其完整协议原文
见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。
