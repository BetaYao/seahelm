# 四面板统一到左侧 — 设计

## 目标
把 worktree / bridge / file / change 四个 pane 全部收到左侧,用左上角的一排切换图标互斥切换;清空右上角按钮区。

## 决策
- **单栏四选一**:左栏任一时刻只显示一个 pane。右栏整体移除,中间终端变宽。
- **新建任务框仅 worktree pane 显示**。
- **左上图标顺序**:`折叠 | 主题 | worktree | bridge | file | change`(主题从右上迁来)。
- **右上**:全部删除(clean-worktree / files / changes / collapse-right / theme)。
- 左栏宽度 300。

## 改动

### TitleBarView.swift
- 新增顶层 `enum LeftPane { worktree, bridge, file, change }`。
- `TitleBarDelegate`:删除 `…CollapseRightColumn / …CleanMergedWorktrees / …ShowFiles / …ShowChanges`;新增 `titleBarDidSelectLeftPane(_:)`;保留 theme / collapseLeft / selectWorktree。
- 删除 rightArcBlock 及 files/changes/clean/collapseRight 按钮。theme 按钮移入左侧 `leftClusterStack`,其后排 4 个 pane 切换按钮(选中态用 `Theme.accent`,无 hover 干扰)。
- collapse-left 图标固定在最左(leading+4);cluster 紧随其右。tabStrip / titleStack 的 leading 改为锚到 cluster 右缘,trailing 改锚到 `trailingAnchor`。
- `updateChromeState(...canCleanWorktrees:)` 保留签名但空实现(源兼容)。

### DashboardViewController.swift
- 新增 `leftColumnContainer`,内含 worktree scroll、inlineCreate、`sidePanelVC.view`(默认隐藏)。宽度约束移到该容器。
- 删除 `rightColumnContainer` / `toggleRightColumnCollapse` / `showSidePanelTab` / right 列宽约束 / `isRightColumnCollapsed`。
- 中间 focus panel 的 leading 锚到 `leftColumnContainer.trailing`,trailing 锚到容器右缘。
- 新增 `selectLeftPane(_:)`:切换 worktree 列表与 sidePanel 的显隐,并 `sidePanelVC.selectTab(...)`;若左栏折叠则展开。
- `toggleLeftColumnCollapse` 改为对 `leftColumnContainer` 整体折叠/alpha。

### MainWindowController.swift
- `TitleBarDelegate` 扩展:删除 4 个旧方法,新增 `titleBarDidSelectLeftPane` → `dashboardVC?.selectLeftPane(pane)`。
- 保留 `cleanMergedWorktrees()`(暂无入口)。

### WorktreeSidePanelViewController.swift
- 隐藏内部那行 tab bar(切换改由标题栏驱动),仅保留内容区。

## 验证
xcodebuild Debug 编译通过;运行截图确认四图标切换、终端变宽、右上清空、新建框仅 worktree 显示。
