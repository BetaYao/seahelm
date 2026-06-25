# amux UI Specification

> Reference: OpenAI Codex macOS Desktop App
> Target: Native macOS (AppKit), dark-first design

---

## 1. Layout Architecture

### 1.1 Window Structure

```
+-----------------------------------------------------------------------+
|  Title Bar (40px) — traffic lights + project tabs + actions           |
+-----------------------------------------------------------------------+
|         |                              |                              |
| Sidebar |     Main Terminal Area       |    Review Panel (optional)   |
| (300px) |        (flexible)            |        (360px)               |
|         |                              |                              |
|  Thread |   Immersive terminal view    |   Git diff / AI chat /      |
|  List   |   (Ghostty + tmux)          |   Notifications              |
|         |                              |                              |
+-----------------------------------------------------------------------+
|  Status Bar (32px) — status text + indicators                         |
+-----------------------------------------------------------------------+
```

### 1.2 View Modes

| Mode | Description |
|------|-------------|
| **Dashboard** | Grid of agent cards showing all worktrees across all projects |
| **Project** | Sidebar (thread list) + immersive terminal (selected thread) |
| **Review Panel** | Slide-in overlay from right (360px), with backdrop dimming |

### 1.3 Responsive Behavior

- Window width <= 900px: sidebar stacks vertically above terminal (220px height)
- Window width > 900px: sidebar side-by-side with terminal (300px width)

---

## 2. Component Inventory

### 2.1 Title Bar (40px height)

```
[Traffic Lights]  [Dashboard]  [Project1 x]  [Project2 x]  [+]  ...  [Layout] [Bell] [AI] [Theme]
```

- **Traffic lights**: Custom (close/minimize/zoom), left-aligned
- **Project tabs**: Clickable pills, active tab highlighted with accent
- **Close button (x)**: On each project tab, triggers confirmation modal
- **Add button (+)**: Opens folder picker to add new project
- **Right actions**: Layout toggle, notifications bell, AI panel, theme toggle

### 2.2 Sidebar (300px)

**Thread List** — Each row (60px height):
```
+------------------------------------------+
|  Thread Name                         [.]  |
|  Status message or last output...         |
+------------------------------------------+
```

- **Active row**: Accent-tinted background (7% opacity) + accent border (38% opacity)
- **Status dot**: 8px circle, color matches agent status
- **Thread name**: Bold, 12px
- **Subtitle**: Muted color, 12px, 2-line clamp
- **Empty state**: Centered text "No thread yet. Click New Thread in titlebar."
- **Context menu**: Right-click for "Delete Worktree..."

### 2.3 Terminal Area (flexible width)

- **Ghostty-powered** terminal with Metal rendering
- **Auto Layout constraints**: Pin to all edges of container
- **tmux integration**: Each thread = tmux session
- **Resize sync**: `ghostty_surface_set_size` + `tmux resize-window -x COL -y ROW`
- **Corner radius**: 8px on left edges (inner corners toward sidebar)
- **Border**: 1px, `line` color at 38% opacity

### 2.4 Status Bar (32px height)

```
[Status icon]  Status: Dashboard ready · Focus thread-name         [connection] [version]
```

- Left-aligned status text
- Right-aligned metadata

### 2.5 Modal / Dialog

- **Full-screen overlay** with semi-transparent backdrop
- **Centered card**: Title + subtitle + optional input + Confirm/Cancel buttons
- **Dismiss**: Escape key or Cancel button
- **Confirm styles**: Default (accent), Warn (destructive red)

### 2.6 Slide-in Panels (360px)

- **Notification Panel**: Right side, shows agent status changes
- **AI Panel**: Right side, chat interface
- **Backdrop**: Click to dismiss
- **Animation**: Slide from right edge

---

## 3. Color System

### 3.1 Semantic Colors

| Token | Purpose | Dark Mode | Light Mode |
|-------|---------|-----------|------------|
| `bg` | Window background | `#1a1a1a` | `#f5f5f5` |
| `panel` | Sidebar background | `#202020` | `#ffffff` |
| `panel2` | Terminal container | `#1e1e1e` | `#fafafa` |
| `surface` | Card / elevated surfaces | `#282828` | `#ffffff` |
| `line` | Borders, dividers | `#333333` | `#e0e0e0` |
| `text` | Primary text | `#e5e5e5` | `#1a1a1a` |
| `muted` | Secondary text | `#808080` | `#666666` |
| `accent` | Interactive elements | `systemBlue` | `systemBlue` |

### 3.2 Status Colors

| Status | Color |
|--------|-------|
| Running | `systemGreen` |
| Idle | `systemGray` |
| Waiting | `systemYellow` |
| Error | `systemRed` |
| Exited | `systemGray` (dimmed) |

### 3.3 Theme Modes

- **System**: Follow macOS appearance
- **Light**: Force light
- **Dark**: Force dark

---

## 4. Typography

| Use | Font | Size | Weight |
|-----|------|------|--------|
| Tab labels | System | 13px | Medium |
| Thread name | System | 12px | Bold |
| Thread subtitle | System | 12px | Regular |
| Status bar | System | 11px | Regular |
| Terminal | Ghostty config (user's font) | — | — |

---

## 5. Spacing & Sizing

| Element | Value |
|---------|-------|
| Title bar height | 40px |
| Status bar height | 32px |
| Sidebar width | 300px (side-by-side) / full width (stacked) |
| Panel width | 360px |
| Grid spacing | 12px |
| Card corner radius | 8px |
| Row height (thread list) | 60px |
| Row spacing | 4px |
| Content insets | 6px (sidebar scroll view) |

---

## 6. Interaction Patterns

### 6.1 Navigation

| Action | Result |
|--------|--------|
| Click project tab | Switch to project view (sidebar + terminal) |
| Click Dashboard tab | Return to dashboard grid |
| Click thread in sidebar | Switch terminal to that thread's tmux session |
| Escape | Dismiss modal > dismiss panel > return to dashboard |
| Cmd+0 | Dashboard |
| Cmd+W | Close current project tab (with confirmation) |
| Cmd+, | Settings |
| Cmd+P | Quick switcher |
| Cmd+N | New thread/branch |
| Cmd+D | Show diff overlay |

### 6.2 Project Lifecycle

1. **Add**: Click `+` in title bar > folder picker > project added to config + tab
2. **Switch**: Click project tab in title bar
3. **Close**: Click `x` on tab > modal confirmation > kill tmux sessions > remove from config

### 6.3 Terminal Resize Flow

1. View container resizes (window resize, tab switch, sidebar toggle)
2. GhosttyNSView `setFrameSize` fires
3. `ghostty_surface_set_size(width, height)` updates Ghostty
4. `tmux resize-window -x COLS -y ROWS` updates tmux
5. `tmux refresh-client -S` forces redraw

---

## 7. Accessibility

- All interactive elements have `accessibilityIdentifier` for UI testing
- Tab buttons: `accessibilityRole = .button`
- Thread rows: `accessibilityRole = .cell`
- Terminal container: `accessibilityRole = .group`
- Keyboard navigation: Tab key moves focus, Enter activates
- VoiceOver: Labels on all status indicators

---

## 8. File Structure

```
Sources/
  App/
    AppDelegate.swift          — App lifecycle
    MainWindowController.swift — Window orchestrator
  UI/
    TitleBar/                  — Custom title bar + project tabs
    Dashboard/                 — Agent grid, card views
    Repo/                      — Project view (sidebar + terminal)
      SidebarViewController.swift  — Thread list
      RepoViewController.swift     — Terminal container
    Shared/                    — Theme, SemanticColors, reusable components
    Dialog/                    — Quick switcher, new branch
    Diff/                      — Diff overlay
    Settings/                  — Settings panel
  Terminal/
    TerminalSurface.swift      — Ghostty surface wrapper
    GhosttyBridge.swift        — Ghostty C API singleton
  Core/
    Config.swift               — JSON config (~/.config/amux/config.json)
    WorkspaceManager.swift     — Tab/project state
  Status/
    StatusPublisher.swift      — Agent status polling
  Git/
    WorktreeDiscovery.swift    — git worktree integration
```
