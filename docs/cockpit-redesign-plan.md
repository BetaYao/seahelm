# SeaHelm 驾驶舱 UI 改造计划

> 来源原型：claude.ai/design `SeaHelm.dc.html`（Agent 驾驶舱控制台）
> 已定决策：**Bare TUI 极简皮肤** · **一次性完整落地** · **命令面板完整纳入**

## 设计基线（Bare TUI，取自原型 THEME.A）

- 背景渐变 `#114650 → #0c2c34 → #08222a`；面板 **透明**；发丝边框 `rgba(150,215,225,0.10)`
- accent 青 `#1fc8da`；agent 色：claude 橙 `#ff8a3d`(字形 ✻) / codex 蓝 `#5b93f0`(字形 ⟡)
- urgency：HIGH 红 `#e84635` / NORMAL 青
- **直角**(radius 0) · **无阴影** · **无辉光** · 面板间距 1px · 字体 **JetBrains Mono**

## 入口决策（已定）

- **删除** 左侧边栏的 First Mate / Bridge tab（sailboat icon）。
- **保留** 左侧三个 icon：file tree、changelog(changes)、worktree item。
- First Mate 唯一入口改为 **底部中央雷达球**。

## 键位决策（整体延后）

- **本轮不加任何快捷键。** 所有交互先走鼠标/点击（雷达球点击开合、卡片按钮点击、输入框直接点选补全）。
- 键位体系（开合键、`w`、`?`、overlay 内 `j/k`/`1–3`/`Tab`/`i`/补全/`Esc` 等）留到**最后阶段统一设计**。

---

## 工作包

### WP-1 主题层 — 色板已落地，字体待办
- [x] `SemanticColors.swift` 暗色分支整体重指向 Bare TUI(THEME.A) 航海板：bg→#08222a、panel→#0e2d37、text→#cfe0e0(ink)、muted→#7fa0a3、line→#96d7e1(半透明发丝)、accent→#1fc8da、running→#1bb062、waiting→#5b93f0(cornflower)、danger→#e84635。浅色分支保持不动。
- [x] 默认主题已是 `.dark`（AppDelegate fallback），开箱即 Bare TUI；驾驶舱/orb/命令行内联色与之一致。
- [x] **JetBrains Mono 字体**：`Resources/Fonts/JetBrainsMono-{Regular,Medium,Bold}.ttf`（OFL）打包进 bundle（`project.yml` 注册资源）；`AppFont.swift` 在 `applicationDidFinishLaunching` 用 `CTFontManagerRegisterFontsForURL` 运行时注册（无需 Info.plist），提供 `AppFont.mono(size:weight:)` 回退 `monospacedSystemFont`；全仓 `monospacedSystemFont(ofSize:)` 调用已替换为 `AppFont.mono(size:)`。已验证 .ttf 落入 `seahelm.app/Contents/Resources/`。

### WP-2 底部驾驶舱（核心）— 已落地（看效果版），编译通过
- [x] 新建 `Sources/UI/Helm/HelmOrbView.swift`：雷达球（旋转扫描弧 + pending badge；Bare 风格细环、无辉光）。
- [x] 新建 `Sources/UI/Helm/HelmCockpitController.swift`：全屏穿透容器 + 底部居中浮层 + scrim 点击关闭；**直接内嵌复用** `BridgePanelViewController` 渲染 Orders/Watch。
- [x] `BridgePanelViewController` 增加 `onOrdersCountChanged` 回调驱动 orb badge（不抢占 queue 的回调）。
- [x] `PendingOrdersQueue` / `WatchFeed` 改为 **token 多观察者**（sidebar 与 cockpit 同时订阅、互不覆盖、可注销）。
- [x] `DashboardViewController` 顶层挂载 cockpit；`MainWindowController` 用同一 queue/feed/回调接线。
- [ ] **移除左侧 Bridge tab 入口（延后）**：标题栏 `.bridge` 切换图标 + 底栏耦合 —— 底栏（命令输入 + 新建 worktree 表单）gated 在 `isBridge`，需随 WP-3 把底栏 rehome 后再删，否则会破坏新建 worktree。当前 cockpit 与旧 Bridge tab **并存**。

### WP-3 命令面板 `/ @ #` — 已落地，编译+测试通过
- [x] 新建 `Sources/UI/Helm/CommandInputView.swift`：`›` 输入框 + `/@#` 提示行。
- [x] cockpit 内置补全下拉（`trailingToken` 解析 + `MenuRowButton` 鼠标点选插入；键盘导航属 WP-6 延后）。
- [x] **后端直接复用** 既有 `BridgeCommandParser` + `BridgeCommandRouter`（new/order/commit/return/broadcast），提交走 `MainWindowController.submitBridgeCommand`。
- [x] 补全数据 `helmMenuItems`：`/` 命令静态表 · `@` worktree 分支(ShipLog) · `#` agent 类型。

### WP-3b 删除旧 Bridge tab — 已落地
- [x] 标题栏移除 `sailboat`(First Mate) pane 图标；默认 pane 改 `.file`。
- [x] 侧栏移除 First Mate tab（仅留 Files / Changes）。
- [x] 底栏（fleet status + 新建 worktree 表单）从「仅 bridge 可见」改为**常驻可见**，保住新建 worktree。
- [x] 队列/feed 测试改用 `addObserver`；23 项相关单测通过。

### WP-4 浮卡 — 已落地；帮助 overlay 并入 WP-6
- [x] 新建 `Sources/UI/Helm/HelmFloatingCard.swift`：底部中央浮卡（左色条 + 倒计时条 + 3 行正文 + hint），点击路由进驾驶舱。
- [x] cockpit 直接再订阅 `PendingOrdersQueue`/`WatchFeed`（多观察者），diff `seen*Ids` 检测**新到事件**才弹卡；启动时 seed seen 避免弹历史项；cockpit 打开时抑制弹卡并清掉现有卡。
- [x] order 卡 urgency 着色（危险 kind 红 / 否则橙），watch 卡 accent；倒计时 6.5s/5s 自动消失。
- [ ] **帮助 overlay（`?` 双栏键位图）并入 WP-6**：触发依赖键位，放到键位体系一起做。
- [ ] ⚠️ 待定：现有右侧 `NotificationPanelView` 仍会弹通知，与底部浮卡**并存**；是否让浮卡取代右侧面板需你定。

### WP-5 标题栏 — agent 字形已落地
- [x] `SailorType.tabGlyph`：✻ Claude · ⟡ Codex · ◇ OpenCode · ✦ Gemini · ◆ 其它 AI · ❯ shell · unknown 无。
- [x] `WorktreeTabButton` 在状态点与标题间渲染字形（JetBrains Mono），claude 橙 / codex 蓝 / 其它 accent；无 agent 时宽度塌缩为 0。
- [x] tab 元组贯穿 `MainWindowController.refreshWorktreeTabs` → `setWorktreeTabs`。
- [ ] tab 的按键提示数字(1–5)**延后**，随键位体系一起做。

### WP-6 键位体系 — v1 已落地
- [x] NORMAL 模式：`space` 开合驾驶舱 · `?` 开合键位帮助 overlay · `Esc` 关闭最上层驾驶舱面（help → cockpit）后再回退原"退出导航"。
- [x] 驾驶舱命令输入框聚焦时 `Esc`（`cancelOperation`）：先收补全菜单，否则关驾驶舱。
- [x] 新建 `KeyboardHelpOverlay`（`?` 双栏 NORMAL/HELM 键位图，Bare TUI）。
- [x] 状态栏 NORMAL hint 增补 `space Helm · ? keys`。
- [x] INSERT(终端聚焦)下这些键天然透传（dashboard 非响应者）。
- [x] **overlay 内全键盘导航**：驾驶舱打开即进"导航态"（聚焦 Orders 表，非输入框）；`j/k` 选卡 · `1–9` 选项 · `n` 关单 · `x` 清 watch · `→` 跳 worktree（复用 bridge 既有逻辑）· `Tab` 在 Orders/Watch 表间切焦点（`insertTab:`）· `i` 聚焦命令输入框 · `Esc` 两级（输入框→收菜单/回导航；导航→关驾驶舱，经 `cancelOperation:`）。

## 验证
- 单测：`CommandDispatcher`、`computeMenu` 补全（纯逻辑可 TDD）。
- 构建：`xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build`。
- 手动跑 App 验证驾驶舱开合 / 浮卡 / 命令补全；按 CLAUDE.md 跳过 UI tests。

## 复用资产（已有，无需重建）
- `PendingOrdersQueue` / `WatchFeed` / `FirstMate.evaluate` / `SailorStatus`(6 态) / agent 建议选项 / 危险态二次确认 / `WorktreeDiscovery` / `ExternalChannel`。
