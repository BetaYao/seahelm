# SeaHelm 全键盘交互重设计

> 已定决策：**Vim 模态 + Leader 键** 范式 · **先出设计文档** · **保留现有 Cmd 快捷键作为别名（不破坏肌肉记忆）**
> 目标：把当前并存的两套焦点系统收敛为**一个统一心智模型**，让所有 UI 区域（分屏 / 卡片 / 侧栏 / 标题栏 / Helm / 对话框）都可纯键盘触达。

---

## 1. 现状问题（重设计要解决的）

当前是模态设计（`.normal` 仪表盘 / `.insert` 终端），但实际跑着**两套互不相关的焦点系统**：

| 问题 | 现状 | 位置 |
|------|------|------|
| **焦点导航二义** | 仪表盘卡片用裸 `hjkl`；分屏用 `Cmd+Option+方向键` | `DashboardViewController:938` / `MainWindowController:921-929` |
| **修饰键无规律** | 焦点用 `Cmd+Option`，缩放用 `Cmd+Ctrl`，无助记 | `MainWindowController:921-940` |
| **模式切换别扭** | `Cmd+Esc` 作 insert↔normal 切换，非标准、易误触 | `MainWindowController:955-961, 977-990` |
| **区域无统一切换键** | sidebar / panes / titlebar / dashboard 之间没有一致的跳转键 | 各区域各自为政 |
| **各区域键位自创** | Helm 表用 `ijkn`，仪表盘用 `hjkl`，Quick Switcher 用箭头 | `BridgePanelViewController:296` 等 |
| **鼠标独占死角** | 标题栏 worktree tab、Helm 补全菜单、浮动 order 卡片无法键盘触达 | 见 §7 |

---

## 2. 核心心智模型：三层

```
┌─ MODE ────────────────────────────────────────────────┐
│  INSERT  →  所有键进入终端 (Ghostty PTY)               │
│  NORMAL  →  键位由 App 解释（导航 / 命令）             │
├─ REGION（NORMAL 下当前被操作的区域）─────────────────┤
│  panes(分屏)  ·  dashboard(卡片)  ·  sidebar  ·        │
│  titlebar  ·  helm                                     │
├─ LEADER（Space 唤起 which-key 元命令菜单）────────────┤
│  Space → 分层命令树（split / new / delete / go / ...） │
└────────────────────────────────────────────────────────┘
```

**一条铁律**：在 NORMAL 下，`h j k l` 永远是「在当前 REGION 内移动焦点」；`Tab`/`Shift+Tab` 永远是「切换 REGION」；`Space` 永远是 leader。区域不同，只是 `hjkl` 落在不同的目标上，键位本身不变。

---

## 3. 模式（Mode）

| 模式 | 进入 | 退出 | 键行为 |
|------|------|------|--------|
| **INSERT** | `i` / `a` / `Enter`（在 pane 上）；或点击 pane | `Esc` | 全部键送给 Ghostty，除 App 全局 Cmd 快捷键 |
| **NORMAL** | `Esc`（从终端）；启动默认态 | `i`→INSERT | App 解释键位 |

**关键变更**：废弃 `Cmd+Esc` 切换。改为对称的 `Esc`（进 NORMAL）/ `i`（进 INSERT），符合 vim 直觉。
> 终端内的程序（vim/less）也用 Esc —— 采用「**单击 Esc 有 150ms 判定**」不可行，故改为：**INSERT 下的 Esc 直接透传给终端；回到 NORMAL 用 `Ctrl+[` 之外的专属键？** 见 §9 待决项 D1。

---

## 4. 区域（Region）与 `hjkl`

`Tab` 顺序（循环）：`panes → sidebar → titlebar → helm → panes`。当前区域有可见高亮框（复用现有 dim overlay / focus ring）。

| Region | `h j k l` 含义 | `Enter` | 备注 |
|--------|---------------|---------|------|
| **panes** | 按几何方向移动分屏焦点（复用 SplitTree 方向查找） | `i` 进 INSERT | 取代 `Cmd+Option+方向` 作为**主**路径；后者保留为别名 |
| **dashboard** | 上下切卡片（`1-9` 直达） | 进入该 worktree | 单列时 `h/l` 无效 |
| **sidebar** | 上下走 worktree/文件树（复用 NSOutlineView） | 打开/展开 | `Cmd+B` 折叠仍保留 |
| **titlebar** | 左右切 worktree tab | 激活 tab | **填补当前鼠标独占死角** |
| **helm** | 在 Orders/Watch 表内上下（复用现有） | 跳到对应 pane | 统一为 `hjkl`，弃用 `ijkn` |

> 说明：dashboard 与 panes 在不同布局下可能是同一屏的不同呈现；REGION 判定基于「当前哪个容器可见且激活」。

---

## 5. Leader（`Space`）which-key 菜单

`Space` 在 NORMAL 下弹出底部 which-key 提示条，显示下一层可用键（模仿 Spacemacs/LazyVim）。**超时不消失，需选键或 Esc**。

```
Space
 ├─ s   split ▸           s→水平  v→垂直  x→关闭 pane  =→重置比例
 ├─ n   new worktree      (打开 Helm /new)
 ├─ d   delete worktree   (二次确认 d/y)
 ├─ g   go ▸              w→worktree 切换器  0→dashboard  b→切 sidebar
 ├─ w   window/pane ▸     H J K L→缩放  m→最大化 pane
 ├─ c   changes           (左栏切 Changes)
 ├─ f   files             (左栏切 Files)
 ├─ /   command palette   (Helm 命令行)
 └─ ?   keyboard help
```

设计要点：
- **一级常用动作也给单键别名**（见 §6），leader 是「可发现的完整树」，单键是「熟手快路」。
- which-key 条复用 `KeyboardHelpOverlay` 的渲染，改为分层、随按键下钻。
- 任意层 `Esc` 回退一层 / 关闭。

---

## 6. 完整键位表（NORMAL 模式）

### 6.1 导航（无修饰）
| 键 | 动作 |
|----|------|
| `h j k l` | 当前 REGION 内移动焦点 |
| `Tab` / `Shift+Tab` | 下一个 / 上一个 REGION |
| `1`–`9` | 当前 REGION 内直达第 N 项 |
| `i` / `a` / `Enter` | 进入 INSERT（聚焦终端） |
| `Esc` | 关闭 leader/菜单；否则回退焦点 |

### 6.2 单键快路（等价于 leader 深层）
| 键 | 动作 | Leader 等价 |
|----|------|-------------|
| `Space` | 打开 leader | — |
| `d` | 删除聚焦 worktree（d/y 确认） | `Space d` |
| `n` | 新建 worktree | `Space n` |
| `c` | Changes | `Space c` |
| `f` | Files | `Space f` |
| `/` | 命令面板 | `Space /` |
| `?` | 键盘帮助 | `Space ?` |

### 6.3 保留的 Cmd 全局别名（不破坏肌肉记忆，任意模式可用）
| 键 | 动作 | 新范式等价 |
|----|------|-----------|
| `Cmd+D` / `Cmd+Shift+D` | 水平 / 垂直分屏 | `Space s s` / `Space s v` |
| `Cmd+P` | Quick Switcher | `Space g w` |
| `Cmd+N` | 新建 worktree | `n` / `Space n` |
| `Cmd+W` | 关闭 pane/tab | `Space s x` |
| `Cmd+0` | Dashboard | `Space g 0` |
| `Cmd+B` | 折叠 sidebar | `Space g b` |
| `Cmd+Option+方向` | 分屏焦点 | `hjkl`（panes region） |
| `Cmd+Ctrl+方向` | 分屏缩放 | `Space w HJKL` |
| `Cmd+Ctrl+=` | 重置比例 | `Space s =` |
| `Cmd+,` / `Cmd+U` / `Cmd+Q` | 设置 / 更新 / 退出 | 仅 Cmd |

---

## 7. 填补鼠标独占死角

| 死角 | 现状 | 新方案 |
|------|------|--------|
| 标题栏 worktree tab | 仅点击 | `Tab` 进 titlebar region → `hjkl`/`1-9` 选中 → `Enter` |
| Helm 补全菜单 | 仅点击 | 输入框内 `↑↓`+`Enter`/`Tab`（已部分具备，纳入统一规范） |
| 浮动 order 卡片 | 仅点击 | 进 helm region → `hjkl` 选 → `Enter` 跳转 / `x` 关闭 |
| 文件树 | 原生箭头，未整合 | 纳入 sidebar region，`hjkl` 统一 |

---

## 8. 对话框内统一键位

所有模态（Quick Switcher / Settings / 确认框）统一：
- `↑↓` 或 `k/j`（无输入焦点时）移动
- `Enter` 确认，`Esc` 取消/关闭
- Quick Switcher 保持「输入即筛选」，导航键不被吞

---

## 9. 定案（D1–D4，已拍板 2026-07）

- **D1 — NORMAL 回切键 → 定案 (a)**：保留 `Cmd+Esc` **仅**用于 INSERT→NORMAL（沿用现有 `handleEsc(hasCommand:)` 语义，零改动、零终端冲突）；NORMAL→INSERT 一律用 `i`/`a`/`Enter`。不引入双击 Esc（已在现有代码中明确废弃），不引入 tmux prefix（与模态范式重复）。
- **D2 — REGION 高亮 → 定案：复用现有 dim overlay + 升级为区域级边框**。非当前 region 整体降透明度（复用 SplitContainer 现有 dim），当前 region 加 1px accent 发丝边框（复用 focus ring 视觉 token）。不新造一套高亮系统。
- **D3 — which-key 弹出 → 定案：延迟 400ms 弹**。按下 `Space` 立即进入 leader 态并可接收下一键；若 400ms 内未按下一键才渲染 which-key 条。熟手无视觉噪音，生手有提示。（计时属 WP-3 UI 层；WP-1 只建纯状态机，不含计时。）
- **D4 — `1-9` 消歧 → 定案：完全靠 REGION 上下文**。`1-9` 只作用于**当前 region** 的目标（dashboard 卡片 / helm 行 / titlebar tab），无全局占用；`RegionFocusController` 负责路由，dispatch 时以 `current region` 为准。

---

## 10. 工作包（WP）

### WP-1 键位基础设施（无 UI 变更）
- [ ] 新增 `Region` 枚举 + `RegionFocusController`（纯值逻辑，仿 `DashboardFocusController`）
- [ ] `KeyboardModeController` 扩展：mode × region × leader-state 分发
- [ ] 单元测试覆盖分发矩阵

### WP-2 统一 `hjkl` 焦点
- [x] **titlebar region 键盘导航（填补纯鼠标死角）**：`TitleBarView.adjacentPath(paths:from:forward:)` 纯逻辑 + `selectAdjacentWorktree(forward:)`；`MainWindowController.selectAdjacentWorktree`；`SeahelmWindow.performKeyEquivalent` 绑 `Ctrl+Tab`/`Ctrl+Shift+Tab`（终端前拦截，无 responder 交接）。10 项单测。
- [ ] panes region 接 SplitTree 方向查找（复用现有 `Cmd+Option` 逻辑）
- [ ] dashboard / sidebar / helm region 各接现有导航
- [ ] `Tab` 循环切 region + 高亮（D2）

> **WP-2 落地说明（2026-07）**：本轮先落地 titlebar 键盘导航——这是唯一「无 first-responder 交接、纯逻辑可单测、无需 GUI 验证」的区域。其余三处（sidebar / panes / helm）的 `Tab` 循环切换都要求把 first responder 在 dashboard VC ↔ NSOutlineView/NSTableView/Helm 表之间交接，且 helm 内部已占用 `Tab`（Orders↔Watch）——这些改动的正确性必须**跑 GUI 才能验证**（当前会话无法）。故 `RegionFocusController` 基础设施已就绪（WP-1），跨区域实际接线留待可跑 App 的会话逐一验证落地。

### WP-3 Leader / which-key
- [x] `LeaderMenu` 数据模型（分层命令树，`Sources/App/LeaderMenu.swift`）：`LeaderNode`(submenu/command) + `LeaderCommand` 叶动作 + `entries(at:)` / `hints(at:)` / `resolve(path:key:)`。树结构对齐 §5。15 项单测（含与 WP-1 状态机的 drill-down/back 联动）。
- [x] 下钻 + `Esc` 回退（状态机 WP-1 已备：`openLeader`/`descendLeader`/`leaderBack`/`closeLeader`；WP-3 `resolve` 决定 descend/fire/unknown）。
- [ ] which-key 条渲染（复用 `KeyboardHelpOverlay`）+ 400ms 延迟（D3）— **GUI 层，需跑 App 验证**。
- [ ] dashboard keyDown 接线：`Space` 开 leader → 按 `resolve` 下钻/触发 → `LeaderCommand` 落到现有动作 — **触碰 first responder / 实机交互，需跑 App 验证**。

> **WP-3 落地说明（2026-07）**：命令树 + 解析 + 状态机联动是纯逻辑，已完整落地并单测。剩余两项（which-key 视觉条 + dashboard 实际接线）涉及 NSView 渲染、400ms 计时与按键实机分发，正确性须跑 GUI 验证，留待可跑 App 的会话。届时 `LeaderCommand` → 现有能力的映射：`splitHorizontal/Vertical`→`splitFocusedPane`、`closePane`→`closePaneOrTab`、`resetRatio`→`resetSplitRatio`、`resize`→`resizeSplit`、`newWorktree`→`onRequestNewWorktree`、`quickSwitcher`→`showQuickSwitcher`、`dashboard`→`switchToDashboard`、`toggleSidebar`→`toggleLeftColumnCollapse`、`showChanges/browseFiles`→现有 dashboard 动作、`commandPalette`→`helmCockpit.openWithCommand`、`keyboardHelp`→`toggleHelp`。

### WP-4 填补死角
- [ ] titlebar region 键盘选 tab
- [ ] helm 浮动卡片键盘操作
- [ ] 文件树纳入 sidebar region

### WP-5 Cmd 别名与迁移
- [x] **窗口级快捷键收敛为单一真相源**：新增 `GlobalShortcut` + `GlobalKeymap.resolve(chars:keyCode:flags:hasSplitContext:)`（`Sources/App/GlobalKeymap.swift`），把原先散在 `SeahelmWindow.performKeyEquivalent` 的 if 链抽成纯函数；handler 改为 `resolve → switch` 分发（方向映射用 `axisPositive`/`axisDelta` 辅助）。行为被 14 项单测锁定，零语义变更。
- [x] 全部 §6.3 Cmd 别名保留并指向新逻辑（split / focus / resize / reset / sidebar / Cmd+Esc + 新增 Ctrl+Tab worktree 循环）。
- [x] `Cmd+Esc` 按 D1 收窄为 INSERT→NORMAL（`.exitInsert`）。
- [ ] `?` 帮助覆盖层文案改为反映新键位 — GUI 文案，待跑 App 时一并更新。

### WP-6 对话框统一
- [x] **共享对话框导航解析器**：新增 `DialogNav` + `DialogKeymap.resolve(chars:keyCode:flags:allowVimKeys:)`（`Sources/App/DialogKeymap.swift`），统一 `↑↓`/`Enter`/`Esc`（+ 可选 `k/j`），供 Quick Switcher / Settings / 确认框复用。10 项单测。
- [ ] 各对话框实际改用 `DialogKeymap`（Quick Switcher / Settings / 确认框）— 触碰各 VC 的 first responder / 文本框，待跑 App 验证接线。

---

## 11. 迁移影响一览

| 现有绑定 | 结局 |
|----------|------|
| `Cmd+Esc` 双向切换 | 收窄为单向 INSERT→NORMAL（D1） |
| 仪表盘 `hjkl` | 保留，纳入 dashboard region |
| 分屏 `Cmd+Option`/`Cmd+Ctrl` | 保留为别名，主路径改裸 `hjkl` + `Space w` |
| Helm 表 `ijkn` | **弃用**，统一 `hjkl`（`i` 现在=进 INSERT） |
| 全部 `Cmd+*` 菜单键 | 全部保留 |
</content>
</invoke>
