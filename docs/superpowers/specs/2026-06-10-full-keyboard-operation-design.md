# 全键盘操作改造 — 设计文档

**日期**: 2026-06-10
**分支**: feat/single-layout-redesign（或新建专用分支）
**状态**: 已批准设计，待写实现计划

## 目标

让 amux 支持完整的全键盘操作。采用 **vim 式模式化** 交互模型，把现有半成品的 "D-state"（Cmd+J 切换的 dashboard 导航态）正式化为一套干净的模式系统，并消除当前只能用鼠标的核心交互。

**优先覆盖范围**（用户选定）：
1. 卡片导航 + 进入终端
2. 新建 worktree 全流程
3. 卡片动作（删除 / diff / 文件浏览）

**非本期重点**：Diff / Inspector 内部的键盘导航（选文件、切 Files/Changes tab、滚动）。后续可另开。

## 非目标（YAGNI）

- 不做 config.json 可配置 keymap、不做用户自定义键位。
- 不做多段按键序列（如 `gg` 之外的复杂组合）。
- 不做 which-key 弹出面板（可发现性靠底部状态栏解决）。

## 架构决策：集中式 ModeController + 声明式键映射

新建 `KeyboardModeController` 作为键盘模式的**单一真相源**（类比 `AgentHead.shared`），持有当前模式与一张声明式键映射表。窗口层 (`AmuxWindow.performKeyEquivalent` / `keyDown` / `sendEvent`) 在分发前先询问它。所有现在散落在 `DashboardViewController.keyDown`、`MainWindowController` 的键逻辑收敛到这里。状态栏订阅其 delegate 显示当前模式与热键。

理由：键位集中、可发现性 UI 几乎是免费副产品、未来加键/加模式只改一张表、与项目现有 delegate 风格一致。

## 模式模型

### 两个模式 `KeyboardMode`

- **`.normal`（普通模式）** — App 默认落地态。dashboard 上有键盘焦点环，单键导航与触发动作。取代现有 D-state，并**移除 Cmd+J 开关**——启动即 Normal。
- **`.insert`（插入模式）** — 焦点在某个终端 surface 上，所有按键透传给 Ghostty（vim/claude/tmux 正常使用）。

> 注：创建 worktree 的表单不是独立模式，而是 Normal 模式下一个「焦点受困的小表单」子态（见下文）。删除二次确认是 Normal 下的瞬时子态 `deletePending`。

### 切换规则

| 触发 | 从 → 到 | 说明 |
|---|---|---|
| 启动 / 回到 dashboard | → Normal | 不再需要 Cmd+J |
| `Return` 或 `i`（焦点在卡片上） | Normal → Insert | 进入该卡片终端 |
| `Cmd+Esc` 或 双击 `Esc` | Insert → Normal | 逆向三键，不抢 vim 的单 Esc |
| 单 `Esc`（Insert 中） | 透传终端 | vim/claude 照常收到 |
| 单 `Esc`（Normal 中） | 关闭叠层 / 无操作 | 若有 diff 等叠层则先关 |

**双击 Esc 判定**：`KeyboardModeController` 记录上一次 Esc 时间戳，约 400ms 窗口内第二次 Esc 触发退出。用 AppKit 运行时的 `Date()` / `ProcessInfo` 时间戳实现（不受 workflow 脚本环境对 `Date.now()` 的限制影响——这是 App 代码）。

**Cmd+Esc 拦截路径**：Insert 模式下 `Cmd+Esc` 由 `AmuxWindow.performKeyEquivalent` 拦截（Cmd 组合键 AppKit 优先于终端透传）。此路径已被现有 Cmd+D 等分屏快捷键验证可行。

## Normal 模式键映射

以下单键**仅在 `.normal` 生效**，因此与终端内程序零冲突。

### 导航（移动键盘焦点环）

| 键 | 动作 |
|---|---|
| `h` `j` `k` `l` / 方向键 | 卡片间移动焦点（grid 二维；focus 布局的 mini-card 竖列用 `j`/`k`） |
| `1`–`9` | 直接跳到第 N 张卡片 |
| `g` / `G` | 跳到第一张 / 最后一张（可选，低优先，可后置） |

### 进入 / 动作（作用于当前焦点卡片）

| 键 | 动作 | 取代现状 |
|---|---|---|
| `Return` / `i` | 进入该卡片终端（→ Insert） | 双击卡片 |
| `d` | 删除该 worktree（二次确认，main 不可删） | 右键菜单 / Delete |
| `c` | 看 changes / diff | 右键「Show Changes」/ Cmd+Shift+F |
| `f` | 浏览文件（inspector Files） | 右键「Browse Files」 |
| `n` | 新建 worktree（聚焦内联创建器） | Cmd+N |

### 删除二次确认（`deletePending` 子态）

不弹模态框，避免打断键盘流。按 `d` 后进入 `deletePending`，状态栏就地变为 `DELETE? · d/y confirm · esc cancel`（色块转红/橙）。再按 `d` 或 `y` 真删；`Esc` 或其他键取消。main worktree 直接拒绝（不进入待确认）。

### 保留不变的全局 Cmd 快捷键

两个模式下均可用，本期不动：`Cmd+P` 快速切换、`Cmd+}`/`{` 切项目 tab、`Cmd+D` / `Cmd+Shift+D` 分屏、`Cmd+B` 侧栏、`Cmd+-` / `Cmd+=` 缩放、`Cmd+W` 关闭。

## 新建 worktree 全流程（键盘化）

创建表单是 Normal 下一个**焦点受困的小表单**子态（`createForm`），不引入新模式。

1. Normal 按 `n` → 聚焦内联创建器，光标落名字输入框，直接打字。
2. `Tab` / `Shift+Tab` 在字段间环形移动：**名字 → repo → agent → reuse env → 名字**。每字段聚焦时有清晰焦点环。
3. **repo / agent** 字段：`←` / `→`（或 `[` / `]`）**就地循环切换选项**为主路径（选项少、最快），不弹 NSMenu；`Space` / `Return` 仍可展开菜单上下选作为备选。
4. **reuse env** 字段：`Space` 切换勾选。
5. `Cmd+Return` 提交（沿用现有），`Esc` 取消并收起，回到 Normal。

**实现要点**：现 repo/agent 是点击 chip 弹 `NSMenu`（`InlineWorktreeCreateView.swift:168-206`）。需给两个 chip 加 `acceptsFirstResponder` + 焦点环 + `←/→` 循环；底层选项数据已存在，只换驱动方式。reuse-env 复选框加 `Space` 响应。Tab 字段环串联。

## 底部状态栏

窗口底部加一条细条（约 22px，helix/vim 风格，低调），**始终可见**，订阅 `KeyboardModeController` delegate。左侧模式标签（带色块），右侧上下文热键提示。

| 状态 | 显示内容 |
|---|---|
| Normal | `NORMAL · hjkl move · ⏎ enter · d del · c diff · f files · n new` |
| Insert | `INSERT · ⌘esc / esc·esc → normal` |
| deletePending | `DELETE? · d/y confirm · esc cancel`（色块转红/橙） |
| createForm | `CREATE · tab field · ←→ change · ⌘⏎ create · esc cancel` |

布局上窗口内容区让出该条高度，需在 `MainWindowController` 的 frame 计算中减去。

## 组件与文件

### 新增

- `Sources/App/KeyboardModeController.swift` — 单一真相源。持有 `mode`、双击 Esc 时间戳、瞬时子态（`deletePending` / `createForm`）；`KeyboardModeDelegate { modeDidChange, hintsDidChange }`；对外暴露当前 hint 集供状态栏。
- `Sources/App/Keymap.swift` — 声明式 `[KeyboardMode: [KeyChord: Action]]` 映射 + `Action` enum；`KeyChord` 表示键 + 修饰符。
- `Sources/UI/StatusLine/StatusLineView.swift` — 订阅 controller，渲染模式 + 热键。

### 改动

- `MainWindowController` / `AmuxWindow` — `performKeyEquivalent` / `keyDown` 先问 controller；布局让出状态栏高度；删除 Cmd+J 分支。
- `DashboardViewController` — D-state 键逻辑迁入 keymap；保留并扩展焦点导航 API（`h/j/k/l` 移动、`1-9` 跳转、取当前焦点卡片），供 Action 调用；去掉自动进/出 D-state 的开关语义，改为常驻 Normal。
- `InlineWorktreeCreateView` — repo/agent chip 加 `acceptsFirstResponder` + 焦点环 + `←/→` 循环；reuse-env 加 `Space`；Tab 字段环。
- `MenuBuilder` — 移除 Cmd+J 菜单项（若存在）。

### 数据流

```
按键
  → AmuxWindow.performKeyEquivalent / keyDown
    → KeyboardModeController.handle(chord)
        ├─ 查 Keymap[mode][chord] → Action
        ├─ 派发 Action → DashboardViewController / 创建器 / TerminalCoordinator
        └─ 模式/子态变化 → KeyboardModeDelegate
              → StatusLineView 刷新
```

## 测试策略

沿用 `Tests/` 的 XCTest 风格（`@testable import amux`，无外部依赖）。

- `KeyboardModeControllerTests` — 模式切换、双击 Esc 时间窗（400ms 内/外）、`deletePending` 两段确认、main worktree 拒删。
- `KeymapTests` — 键 → 动作派发正确；Normal/Insert 下同一键行为不同。
- `StatusLineViewTests` — 各状态下 hint 文本正确。
- 调整现有 `DashboardViewControllerTests`（若有 D-state 相关）与 `InlineWorktreeCreateViewTests` 以匹配新交互（Tab 字段环、`←/→` 循环、`Space` 切换）。

## 错误处理与边界

- **无卡片可导航**：Normal 下 `h/j/k/l` 在空 dashboard 上无操作，状态栏正常显示。
- **删除 main**：`d` 在 main worktree 上不进入 `deletePending`，状态栏短暂提示不可删。
- **焦点丢失**：从 Insert 因外部原因（点击、删除终端）丢焦时，controller 需感知并回落 Normal，状态栏同步。
- **创建表单中按全局 Cmd 键**：`Cmd+P` 等仍可用；`Esc` 优先取消表单而非触发 Normal 的叠层关闭。
- **双击 Esc 误触**：400ms 窗口要足够短，避免 vim 里连按两下 Esc 被误判——但 vim 的 Esc 是单 Esc 路径，pmux 只在「Insert 模式且两次 Esc 都到达 AmuxWindow.sendEvent」时计数；需确认 Esc 在 Insert 下的拦截层级（现有 `sendEvent` 已拦截 Escape）。

## 开放风险（实现时确认）

1. **Esc 拦截层级**：当前 `AmuxWindow.sendEvent` 已拦截 Escape。需确认双击计数逻辑放在这里，且不影响单 Esc 透传给 vim/claude。
2. **焦点导航 API 抽取**：`DashboardViewController` 现有 D-state 与 focus 布局耦合较深，迁移时要保证 grid 与三种 focus 布局的焦点环行为一致。
3. **状态栏高度**对现有四种布局 frame 计算的影响面，需逐一核对。
