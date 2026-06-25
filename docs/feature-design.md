# amux 功能设计文档

> 基于代码梳理，最后更新：2026-03-19

## 一、项目概述

**amux** 是一个原生 macOS 终端复用器，基于 Swift 5.10 + AppKit 开发（macOS 14.0+ Sonoma）。集成 Ghostty 终端引擎（通过 C 绑定 + Metal 渲染），使用 tmux 进行会话持久化，提供仪表板 UI 用于浏览 Git 工作树并检测 AI 代理运行状态。

**技术栈：**
- Swift 5.10 + AppKit（非 SwiftUI）
- Ghostty C API（via `amux-Bridging-Header.h` → `ghostty.h`）
- 链接库：Metal, QuartzCore, IOSurface, Carbon, libghostty, libc++
- 无外部 SPM 依赖，纯系统框架

---

## 二、架构总览

```
┌──────────────────────────────────────────────────┐
│                   UI 层                           │
│  Dashboard · Repo · TabBar · Dialog · Settings   │
├──────────────────────────────────────────────────┤
│                 核心服务层                         │
│  WorkspaceManager · Config · StatusPublisher     │
│  StatusDetector · FuzzyMatch · Notification      │
├──────────────────────────────────────────────────┤
│              终端 & Git 系统层                     │
│  GhosttyBridge · TerminalSurface · Worktree*     │
│  GitDiff                                         │
└──────────────────────────────────────────────────┘
```

---

## 三、功能模块

### 3.1 仪表板（Dashboard）

仪表板是应用的主视图，始终占据标签栏第 0 个位置（不可关闭）。提供两种查看模式：

#### Grid 模式
- 所有工作树以响应式卡片网格排列
- 6 个缩放级别：180, 220, 260, 300（默认）, 380, 480
- 动态计算列数和行数，自适应窗口大小
- 支持拖放重新排序卡片（`DraggableGridView`）
- 卡片顺序持久化到配置文件

#### Spotlight 模式
- 点击任意卡片进入：一个大终端 + 右侧小卡片侧边栏
- 主终端获得完整键盘焦点
- 侧边栏终端为输出只读（`setFocus(false)`）
- ESC 返回 Grid 模式
- Ctrl+Tab / Ctrl+Shift+Tab 循环切换焦点

#### 终端卡片（TerminalCardView）
- 迷你终端预览（实时渲染）
- 状态徽章（彩色圆点）
- 分支名标签
- 双击 → 在标签页打开
- 右键菜单 → 删除工作树

### 3.2 Repo 视图

全屏 Repo 视图，通过"Open in Tab"（Cmd+↵）打开：

#### 侧边栏（SidebarViewController）
- 工作树列表，每行显示：
  - 分支名
  - 状态色条（2pt 宽）
  - 相对时间（现在、1s、1m、1h）
  - 最后消息预览
- 点击切换工作树
- 右键菜单 → 删除工作树

#### 终端区域（TerminalSplitView）
- 递归二叉树结构，支持任意复杂分割
- 垂直分割（Cmd+Shift+D）
- 水平分割（Cmd+Shift+E）
- 关闭窗格（Cmd+Shift+W）
- 焦点管理和表面同步

### 3.3 标签栏（TabBar）

- 索引 0："仪表板"（不可关闭）
- 索引 ≥ 1：Repo 标签（可关闭）
- "+" 按钮添加新 Repo
- 状态计数徽章（运行中、等待、错误）
- Cmd+0 切换到仪表板，Cmd+W 关闭当前标签

### 3.4 快速切换器（Quick Switcher）

Cmd+P 打开，Spotlight 风格搜索：
- 模糊搜索所有工作树（`FuzzyMatch`）
- 多维度评分：前缀 +10、边界 +5、连续匹配奖励、短名优先
- 箭头键导航，回车确认，ESC 取消
- 选中后自动切换到 Dashboard Spotlight 模式

### 3.5 新建分支对话框（New Branch）

Cmd+N 打开：
- Repo 选择下拉框
- 分支名输入
- 基础分支选择（从 `git branch -a` 获取）
- 创建 → `git worktree add -b <branch>`
- 自动放置到 `<repo>-worktrees/<branch>/`

### 3.6 设置面板（Settings）

Cmd+, 打开，标签式面板：

#### General 标签
- 工作空间路径列表
- 后端选择（tmux / local）
- 终端行缓存大小

#### Agent Detection 标签
- 代理检测规则配置
- 每个代理定义：名称、规则列表、默认状态、消息跳过模式

### 3.7 Diff 叠加面板

Cmd+D 打开：
- 左侧：更改文件列表（状态标识 + 行数变化）
- 右侧：unified diff 内容（颜色编码：绿色增加、红色删除）
- 头部：统计摘要（文件数、+/- 行数）

---

## 四、核心服务

### 4.1 配置管理（Config）

- 路径：`~/.config/amux/config.json`
- JSON 序列化/反序列化，`decodeIfPresent()` 保证向后兼容

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `workspace_paths` | [String] | [] | 工作空间路径列表 |
| `backend` | String | "tmux" | 终端后端 |
| `terminal_row_cache_size` | Int | 200 | 终端行缓存 |
| `agent_detect` | Object | 内置规则 | 代理检测配置 |
| `webhook` | Object | disabled | Webhook 配置（未实现） |
| `auto_update` | Object | disabled | 自动更新（未实现） |
| `card_order` | [String] | [] | 卡片排序 |
| `zoom_index` | Int | 3 | 缩放级别索引 |

**自动保存触发点：** 添加/移除 Repo、卡片重排、缩放变更、设置修改

### 4.2 工作空间管理（WorkspaceManager）

```swift
struct WorkspaceTab {
    let repoPath: String
    var displayName: String    // 重复时自动添加父目录前缀
    var worktrees: [WorktreeInfo]
}
```

- 管理 Repo 标签列表
- 自动消歧义重复名称（`folder/repo` 格式）

### 4.3 状态检测系统

#### 轮询（StatusPublisher）
- 2 秒间隔定时器轮询所有终端表面
- 流程：读取视口文本 → 匹配代理定义 → 检测状态 → 去抖 → 回调

#### 检测优先级（StatusDetector）
```
优先级 1: ProcessStatus（exited/error > running）
    ↓
优先级 2: OSC 133 shell phase（权威信号）
    ↓
优先级 3: 文本模式匹配（agent rules）
    ↓
优先级 4: Unknown
```

#### 代理状态（AgentStatus）

| 状态 | 图标 | 颜色 | 说明 |
|------|------|------|------|
| Running | ● | 绿色 | 代理正在执行 |
| Idle | ○ | 灰色 | 代理空闲 |
| Waiting | ◐ | 黄色 | 等待用户输入 |
| Error | ✕ | 红色 | 执行出错 |
| Exited | ◻ | 深灰 | 进程已退出 |
| Unknown | ? | 中灰 | 无法判断 |

#### 去抖（DebouncedStatusTracker）
- Unknown 状态不覆盖当前状态，避免 UI 闪烁

#### 通知（NotificationManager）
- 状态从 Running 变为 Idle/Waiting/Error 时发送 macOS 通知

### 4.4 代理检测规则（AgentDetectConfig）

```swift
struct AgentDef {
    var name: String                    // "claude", "agent"
    var rules: [AgentRule]             // 按顺序匹配
    var defaultStatus: String           // 无匹配时默认状态
    var messageSkipPatterns: [String]  // 消息过滤模式
}

struct AgentRule {
    var status: String      // 目标状态
    var patterns: [String]  // 文本包含则匹配
}
```

- 内置 claude 和 agent 两组规则
- 不区分大小写匹配
- 消息提取：跳过装饰线和 skip patterns，截断至 80 字符

---

## 五、终端系统

### 5.1 Ghostty 桥接（GhosttyBridge）

- 单例模式：`GhosttyBridge.shared`
- `initialize()`：初始化运行时，设置回调（唤醒、动作、剪贴板）
- `tick()`：每帧处理事件
- `shutdown()`：清理资源

### 5.2 终端表面（TerminalSurface）

生命周期管理：
1. **创建**：每个工作树一个表面，自动检测/创建 tmux 会话
2. **重新父化**：切换容器时无需销毁重建，自动同步大小
3. **销毁**：显式删除工作树或应用退出时

tmux 会话命名：`amux-<parent>-<name>`（特殊字符替换为下划线）

关键能力：
- `readViewportText()`：读取可见文本（用于状态检测）
- `processStatus`：进程状态查询
- `reparent(to:)`：2 级延迟同步（布局解析 + 网格重算）
- `setFocus(Bool)`：键盘焦点管理

### 5.3 Metal 渲染（GhosttyNSView）

- 继承 NSView，Metal 后端渲染
- 完整键鼠事件处理
- 修饰符映射：Shift, Ctrl, Alt, Cmd, CapsLock
- 坐标转换（Y 轴翻转）
- Retina 支持（内容缩放管理）

---

## 六、Git 集成

### 6.1 工作树发现（WorktreeDiscovery）
- `git rev-parse --show-toplevel` 查找仓库根
- `git worktree list --porcelain` 枚举工作树
- 解析 `worktree`, `HEAD`, `branch`, `detached` 行

### 6.2 工作树创建（WorktreeCreator）
- 路径规则：`<repoParent>/<repoName>-worktrees/<branchName>`
- 优先 `git worktree add -b`（新分支），失败则 `add`（已有分支）

### 6.3 工作树删除（WorktreeDeleter）
- `git worktree remove <path> [--force]`
- 可选删除分支：`git branch -d/-D <branch>`
- 未提交更改检测：`git status --porcelain`

### 6.4 Diff 解析（GitDiff）
- `git diff --no-color` + `--cached` 合并
- unified diff 格式解析 → `DiffFile` / `DiffHunk` / `DiffLine`
- `git diff --stat HEAD` 统计摘要

---

## 七、键盘快捷键

| 快捷键 | 动作 |
|--------|------|
| Cmd+, | 打开设置 |
| Cmd+N | 新建分支/工作树 |
| Cmd+P | 快速切换器 |
| Cmd+G | 切换到 Grid 模式 |
| Cmd+D | 显示 Diff |
| Cmd+0 | 切换到仪表板 |
| Cmd+1...9 | 聚焦第 N 个终端（Spotlight 模式） |
| Cmd+W | 关闭当前标签 |
| Cmd+↵ | 在标签页打开 |
| Cmd+Shift+D | 垂直分割 |
| Cmd+Shift+E | 水平分割 |
| Cmd+Shift+W | 关闭窗格 |
| Cmd+- | 缩小卡片 |
| Cmd+= | 放大卡片 |
| Esc | 退出 Spotlight |
| Ctrl+Tab | 下一个焦点（Spotlight） |
| Ctrl+Shift+Tab | 上一个焦点（Spotlight） |

---

## 八、关键数据结构

### WorktreeInfo
```swift
struct WorktreeInfo {
    let path: String
    let branch: String
    let commitHash: String       // 缩短至 8 字符
    let isMainWorktree: Bool
    var displayName: String      // main worktree: 目录名，其他: 分支名
}
```

### AgentStatus
```swift
enum AgentStatus: String {
    case running, idle, waiting, error, exited, unknown
    var color: NSColor
    var icon: String
    var priority: Int            // 用于状态汇总
    var isUrgent: Bool           // error | waiting
    var isActive: Bool           // running | waiting
}
```

### DiffFile
```swift
struct DiffFile {
    let path: String
    let status: FileStatus       // A / M / D / R / ?
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]
}
```

---

## 九、关键流程

### 应用启动
```
main.swift → AppDelegate → GhosttyBridge.initialize()
→ MainWindowController:
  1. Config.load()
  2. 布局 TabBar + 内容容器
  3. 枚举 workspace_paths，发现工作树
  4. 为每个工作树创建 TerminalSurface
  5. 应用保存的卡片顺序
  6. 启动 StatusPublisher（2s 轮询）
```

### 表面重新父化
```
surface.reparent(to: newContainer)
  → 禁用 CA 事务
  → 移动到新容器
  → 延迟 1: 布局解析
  → 延迟 2: Ghostty 网格重算 + tmux 布局刷新
```

### 工作树删除
```
右键 → 确认（检查未提交更改）
  → 3 选项：Delete / Delete + Branch / Cancel
  → surface.destroy()
  → WorktreeDeleter.deleteWorktree()
  → 更新 UI（dashboard, tabs, statusPublisher）
```

---

## 十、窗口状态持久化

- 窗口大小/位置：`NSWindow.setFrameAutosaveName("PmuxMainWindow")`
- 配置持久化：JSON 文件自动保存

---

## 十一、预留扩展点

| 功能 | 状态 | 说明 |
|------|------|------|
| OSC 133 集成 | 已实现解析器，未集成 | ShellState 可连接 StatusPublisher |
| Webhook 通知 | 配置已定义 | 支持外部通知（Slack/Discord）|
| 自动更新 | 配置已定义 | 版本检查和升级逻辑 |
| Local 后端 | 配置已定义 | 非 tmux 的本地 PTY 管理 |
| 主题切换 | Theme 已抽象 | 浅色/深色模式支持 |
