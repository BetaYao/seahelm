# Two-Column Window Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the spanning title-bar accessory with a `WindowChromeController` two-column shell (glass sidebar + opaque terminal), draggable divider, ⌘B collapse, and a repo-grouped two-line worktree list.

**Architecture:** New chrome owns headers, divider, width/collapse, and traffic-light hosting. `DashboardViewController` becomes content-only (navigator + terminal host slotted into chrome). `TitleBarView` tab strip dies; icons migrate into `SidebarHeaderView` / collapsed `TerminalHeaderView`. Pure layout math lives in testable helpers before AppKit wiring.

**Tech Stack:** Swift 5.10, AppKit, XcodeGen (`project.yml` auto-includes `Sources/`), macOS 14.0+ (`MACOSX_DEPLOYMENT_TARGET`), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-19-two-column-window-chrome-design.md`

## Locked product choices (from review)

- ⌘B from collapsed: **restore last active left pane**; if none recorded, open **First Mate / navigator**.
- First Mate ↔ §6 navigator; Files/Changes ↔ `WorktreeSidePanelViewController`; Theme independent.
- Glass: `#available(macOS 26, *)` prefer newest sidebar-appropriate material if present; else `NSVisualEffectView` `.sidebar` + `.behindWindow` (works on 14+).
- Build/test: always pass `-skipPackagePluginValidation -skipMacroValidation`.

## File structure

| File | Responsibility |
|------|----------------|
| `Sources/UI/Chrome/ChromeLayoutMetrics.swift` | Width clamp, header height, divider hit width constants |
| `Sources/UI/Chrome/ChromeLayoutState.swift` | Collapse + width + last pane pure state |
| `Sources/UI/Chrome/SidebarHeaderView.swift` | Traffic-light host area + tool icons |
| `Sources/UI/Chrome/TerminalHeaderView.swift` | Title; collapsed hosts lights + icons + expand |
| `Sources/UI/Chrome/ChromeDividerView.swift` | Drag handle |
| `Sources/UI/Chrome/WindowChromeController.swift` | Two-column shell, slots, glass, collapse animation |
| `Sources/UI/Chrome/WorktreeNavigatorRowView.swift` | Two-line worktree item (rounded selection) |
| `Sources/Core/Config.swift` | `sidebarWidth` |
| `Sources/UI/Dashboard/DashboardViewController.swift` | Stop owning column chrome; feed slots; new rows; **retire `ViewMode` as layout** |
| `Sources/App/MainWindowController.swift` | Embed chrome; remove accessory; title updates; ⌘B; **wire NORMAL/INSERT off chrome collapse** |
| `Sources/UI/TitleBar/TitleBarView.swift` | Delete or gut after migration |
| `Sources/App/Region.swift` | Retarget `titlebar` → chrome headers |
| `Tests/ChromeLayoutMetricsTests.swift` | Clamp / defaults |
| `Tests/ChromeLayoutStateTests.swift` | Collapse / last-pane restore |
| `Tests/ConfigTests.swift` | `sidebar_width` round-trip |
| `UITests/Pages/TitleBarPage.swift` → `ChromeHeaderPage.swift` | New accessibility ids |

---

### Task 1: Config `sidebarWidth` + clamp helper

**Files:**
- Modify: `Sources/Core/Config.swift`
- Create: `Sources/UI/Chrome/ChromeLayoutMetrics.swift`
- Modify: `Tests/ConfigTests.swift`
- Create: `Tests/ChromeLayoutMetricsTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/ConfigTests.swift`:

```swift
func testSidebarWidthDefault() {
    let config = Config()
    XCTAssertEqual(config.sidebarWidth, 300)
}

func testDecodeSidebarWidth() throws {
    let json = #"{"sidebar_width": 280}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(Config.self, from: json)
    XCTAssertEqual(config.sidebarWidth, 280)
}

func testDecodeMissingSidebarWidth_UsesDefault() throws {
    let config = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
    XCTAssertEqual(config.sidebarWidth, 300)
}

func testEncodeDecodeSidebarWidthRoundtrip() throws {
    var original = Config()
    original.sidebarWidth = 264
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    XCTAssertEqual(decoded.sidebarWidth, 264)
}
```

Create `Tests/ChromeLayoutMetricsTests.swift`:

```swift
import XCTest
@testable import seahelm

final class ChromeLayoutMetricsTests: XCTestCase {
    func testClampSidebarWidth() {
        XCTAssertEqual(ChromeLayoutMetrics.clampWidth(100, windowWidth: 1000), 200)
        XCTAssertEqual(ChromeLayoutMetrics.clampWidth(300, windowWidth: 1000), 300)
        XCTAssertEqual(ChromeLayoutMetrics.clampWidth(900, windowWidth: 1000), 500)
    }
}
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  test -only-testing:seahelmTests/ChromeLayoutMetricsTests \
       -only-testing:seahelmTests/ConfigTests/testSidebarWidthDefault 2>&1 | tail -20
```

Expected: compile fail — `sidebarWidth` / `ChromeLayoutMetrics` missing.

- [ ] **Step 3: Implement**

`Sources/UI/Chrome/ChromeLayoutMetrics.swift`:

```swift
import Foundation

enum ChromeLayoutMetrics {
    static let defaultSidebarWidth: CGFloat = 300
    static let minSidebarWidth: CGFloat = 200
    static let headerHeight: CGFloat = 40
    static let dividerVisualWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 8

    static func clampWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let maxW = max(minSidebarWidth, windowWidth * 0.5)
        return min(max(width, minSidebarWidth), maxW)
    }
}
```

In `Config.swift`: add `var sidebarWidth: CGFloat` (default 300), CodingKey `sidebar_width`, `decodeIfPresent` with default 300, encode in `encode(to:)`.

- [ ] **Step 4: Run tests — expect PASS**

Same command as Step 2.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Config.swift Sources/UI/Chrome/ChromeLayoutMetrics.swift \
  Tests/ConfigTests.swift Tests/ChromeLayoutMetricsTests.swift
git commit -m "feat: add sidebarWidth config and chrome width clamp"
```

---

### Task 2: Pure collapse / last-pane state

**Files:**
- Create: `Sources/UI/Chrome/ChromeLayoutState.swift`
- Create: `Tests/ChromeLayoutStateTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import seahelm

final class ChromeLayoutStateTests: XCTestCase {
    func testToggleCollapseRemembersLastPane() {
        var s = ChromeLayoutState(width: 300, collapsed: false, activePane: .firstMate)
        s.setActivePane(.files)
        s.toggleCollapsed()
        XCTAssertTrue(s.isCollapsed)
        s.toggleCollapsed()
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.activePane, .files)
    }

    func testExpandFromCollapsedWithNoPaneDefaultsToFirstMate() {
        var s = ChromeLayoutState(width: 300, collapsed: true, activePane: nil)
        s.toggleCollapsed()
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.activePane, .firstMate)
    }

    func testSelectSamePaneWhenExpandedCollapses() {
        var s = ChromeLayoutState(width: 300, collapsed: false, activePane: .files)
        s.selectPane(.files) // re-click active → collapse (today's toggleSide)
        XCTAssertTrue(s.isCollapsed)
        XCTAssertEqual(s.activePane, .files)
    }

    func testSelectDifferentPaneExpandsAndSwitches() {
        var s = ChromeLayoutState(width: 300, collapsed: false, activePane: .files)
        s.selectPane(.changes)
        XCTAssertFalse(s.isCollapsed)
        XCTAssertEqual(s.activePane, .changes)
    }
}
```

Define `ChromeLeftPane` as `.firstMate | .files | .changes` in the same file (chrome-owned; map to existing dashboard APIs at wiring time).

- [ ] **Step 2: Run — expect FAIL** (type missing)

- [ ] **Step 3: Implement minimal `ChromeLayoutState`**

```swift
enum ChromeLeftPane: Equatable {
    case firstMate, files, changes
}

struct ChromeLayoutState: Equatable {
    var width: CGFloat
    private(set) var isCollapsed: Bool
    private(set) var activePane: ChromeLeftPane?

    init(width: CGFloat, collapsed: Bool, activePane: ChromeLeftPane?) {
        self.width = width
        self.isCollapsed = collapsed
        self.activePane = activePane
    }

    /// Icon click: same pane while expanded → collapse; otherwise select + expand.
    mutating func selectPane(_ pane: ChromeLeftPane) {
        if !isCollapsed, activePane == pane {
            isCollapsed = true
            return
        }
        activePane = pane
        isCollapsed = false
    }

    mutating func setActivePane(_ pane: ChromeLeftPane) {
        activePane = pane
        isCollapsed = false
    }

    mutating func toggleCollapsed() {
        if isCollapsed {
            isCollapsed = false
            if activePane == nil { activePane = .firstMate }
        } else {
            isCollapsed = true
        }
    }
}
```
- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Chrome/ChromeLayoutState.swift Tests/ChromeLayoutStateTests.swift
git commit -m "feat: add chrome collapse and last-pane state"
```

---

### Task 3: Header views (icons + title)

**Files:**
- Create: `Sources/UI/Chrome/SidebarHeaderView.swift`
- Create: `Sources/UI/Chrome/TerminalHeaderView.swift`
- Reuse icon button pattern from `Sources/UI/TitleBar/TitleBarView.swift` (`TitleBarIconButton` — move to `Sources/UI/Chrome/ChromeIconButton.swift` if needed, or keep shared)

**Delegate (single protocol used by both headers):**

```swift
protocol ChromeHeaderDelegate: AnyObject {
    func chromeDidToggleTheme()
    func chromeDidSelectPane(_ pane: ChromeLeftPane)
    func chromeDidToggleSidebar()
}
```

- [ ] **Step 1:** Extract/copy `TitleBarIconButton` → `ChromeIconButton` (same SF Symbols: theme, sailboat/First Mate, folder/files, diff/changes, `sidebar.left`).

- [ ] **Step 2:** `SidebarHeaderView` — H stack: leading `trafficLightSlot` (empty `NSView` host for button reposition), trailing icon cluster + sidebar toggle. Accessibility: `chrome.sidebarHeader`, `chrome.icon.theme`, `chrome.icon.firstMate`, `chrome.icon.files`, `chrome.icon.changes`, `chrome.icon.sidebar`.

- [ ] **Step 3:** `TerminalHeaderView` — modes `.expanded` / `.collapsed`:
  - Expanded: title label only (`Repo · pane`).
  - Collapsed: trafficLightSlot + icon cluster + title + expand button.
  - API: `setTitle(repo:pane:)`, `setCollapsed(_:)`, `setActivePane(_:)`, `setWorktreeContextEnabled(_:)`.

- [ ] **Step 3b:** `SidebarHeaderView` must expose the same `setActivePane(_:)` (accent tint like today’s `setActiveTool`) and `setWorktreeContextEnabled(_:)` — when `false`, Files/Changes at 0.3 alpha + disabled; First Mate stays enabled. Both headers share one implementation path (helper or shared icon cluster view) so expanded/collapsed never diverge.

- [ ] **Step 4:** Unit-test title clamp helper:

```swift
func testTerminalTitleFormat() {
    XCTAssertEqual(TerminalHeaderView.formatTitle(repo: "seahelm", pane: "main"), "seahelm · main")
}
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Chrome/
git commit -m "feat: add sidebar and terminal chrome headers"
```

---

### Task 4: Divider + `WindowChromeController` shell

**Files:**
- Create: `Sources/UI/Chrome/ChromeDividerView.swift`
- Create: `Sources/UI/Chrome/WindowChromeController.swift`

- [ ] **Step 1:** `ChromeDividerView` — draws 1px line; hit area `dividerHitWidth`; mouse drag calls `onDrag(deltaX:)`.

- [ ] **Step 2:** `WindowChromeController` layout:

```
view
├── sidebarColumn (NSVisualEffectView later)
│   ├── sidebarHeader
│   └── sidebarContentHost
├── divider
└── terminalColumn (opaque)
    ├── terminalHeader
    └── terminalContentHost
```

Public API:

```swift
func setSidebarContent(_ view: NSView)
func setTerminalContent(_ view: NSView)
func applyState(_ state: ChromeLayoutState, animated: Bool)
var onStateChange: ((ChromeLayoutState) -> Void)?
weak var headerDelegate: ChromeHeaderDelegate?
func updateTerminalTitle(repo: String, pane: String)
func trafficLightHostView(collapsed: Bool) -> NSView  // for MainWindowController
```

Dragging updates `state.width` via clamp against `view.bounds.width`, fires `onStateChange`.

- [ ] **Step 3:** Collapse: set sidebar column width constraint to 0 / hide; switch `terminalHeader.setCollapsed(true)`; move icon visibility per spec.

- Collapse animation: if `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (or `NSAnimationContext` current), apply width change with `duration = 0` / no animator.

- [ ] **Step 4:** Build app target compiles (no MainWindow wire yet if possible — or stub).

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build 2>&1 | tail -30
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UI/Chrome/
git commit -m "feat: add WindowChromeController shell and divider"
```

---

### Task 5: Wire MainWindowController — remove spanning title bar

**Files:**
- Modify: `Sources/App/MainWindowController.swift` (`setupNativeTitleBar`, `positionStandardWindowButtons`, `contentContainer` embed, `updateTitleBar`)
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift` (expose content hosts; stop applying left-column width as window chrome)

- [ ] **Step 1:** In `windowDidLoad` / content setup: create `WindowChromeController`, add as child VC filling `contentContainer` (above status bar). Pass initial `ChromeLayoutState(width: config.sidebarWidth, collapsed: false, activePane: .firstMate)`.

- [ ] **Step 2:** Embed dashboard: chrome `setSidebarContent(dashboard.navigatorHostView)` and `setTerminalContent(dashboard.terminalHostView)`. Refactor Dashboard so overview+side panel live in `navigatorHostView`, focus panel in `terminalHostView`, **without** Dashboard owning the outer column width/collapse constraints (delete or no-op `leftColumnWidth*` chrome role — keep internal pane swap).

- [ ] **Step 3:** Remove `titleBarAccessory` registration (`setupNativeTitleBar` accessory path). Keep `fullSizeContentView`. Reposition traffic lights into `chrome.trafficLightHostView(collapsed:)`.

- [ ] **Step 4:** `onStateChange` → update `config.sidebarWidth` + `saveConfig()` when width changes; ignore collapse for width persistence.

- [ ] **Step 5:** Build + launch smoke (`./run.sh` or xcodebuild). Confirm no accessory bar; two columns visible.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/MainWindowController.swift Sources/UI/Dashboard/DashboardViewController.swift
git commit -m "feat: embed WindowChromeController; remove titlebar accessory"
```

---

### Task 5b: Retire `ViewMode` as layout / collapse (single source of truth)

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift` (`ViewMode`, `setViewMode`, `toggleLeftColumnCollapse`, `toggleSidebarDefaultDashboard`, `onViewModeChanged`, `onEnterTerminal`)
- Modify: `Sources/App/MainWindowController.swift` (`navigateBack`, keyboard mode NORMAL/INSERT sync off `onViewModeChanged`)

**Why:** Spec §4 — chrome `isSidebarCollapsed` is the only layout collapse signal. Leaving Dashboard `ViewMode.split/terminal` + `toggleLeftColumnCollapse` active creates two competing systems once outer column constraints move to chrome.

- [ ] **Step 1:** Inventory callers of `setViewMode`, `viewMode`, `onViewModeChanged`, `toggleLeftColumnCollapse`, `toggleSidebarDefaultDashboard`, `navigateBack`, `onEnterTerminal` (`rg` in `Sources/` + `Tests/`).

- [ ] **Step 2:** Make chrome collapse the SSOT:
  - ⌘B / sidebar button → only `ChromeLayoutState.toggleCollapsed()` + `applyState`.
  - Pane icons → `selectPane` (re-click active collapses; otherwise expand + switch) then mount First Mate / Files / Changes content inside the sidebar slot.
  - Delete or thin-shim `toggleLeftColumnCollapse` so it forwards to chrome (no local width constraints).
  - `ViewMode`: either remove, or keep as a **deprecated alias** where `.terminal == chrome.isCollapsed` and `.split == !collapsed` for one release — update `onViewModeChanged` to fire from chrome state changes only.

- [ ] **Step 3:** Keyboard mode: NORMAL/INSERT (and status-bar hints) subscribe to chrome collapse + focus region, **not** to Dashboard inventing a separate terminal-only layout mode. `navigateBack` / `onEnterTerminal` must not re-collapse via the old Dashboard path.

- [ ] **Step 4:** Unit/UI: collapsing via ⌘B does not leave Dashboard thinking `viewMode == .split` with a zero-width column of its own.

- [ ] **Step 5: Commit**

```bash
git commit -am "refactor: chrome collapse is SSOT; retire ViewMode layout meaning"
```

---

### Task 6: Migrate header actions + ⌘B

**Files:**
- Modify: `Sources/App/MainWindowController.swift` (TitleBarDelegate → ChromeHeaderDelegate)
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift` (pane toggles only — content swap)
- Modify: keyboard routing at `MainWindowController` `case .toggleSidebar` (~`:1320`)

- [ ] **Step 1:** Implement `ChromeHeaderDelegate` on `MainWindowController`:
  - theme → existing theme toggle
  - pane icons → `chromeState.selectPane(.firstMate|.files|.changes)` then `applyState` (re-click active pane collapses — do **not** only call `setActivePane`)
  - after state applies: mount navigator or side-panel content when expanded; both headers `setActivePane` / tint from `chromeState.activePane`
  - toggle sidebar → `chromeState.toggleCollapsed()` + `applyState` + traffic light move

- [ ] **Step 2:** On worktree selection change, call `sidebarHeader.setWorktreeContextEnabled(hasSelection)` and `terminalHeader.setWorktreeContextEnabled(hasSelection)` (Files/Changes disabled at 0.3 when none selected).

- [ ] **Step 3:** Add/verify View menu item **Toggle Sidebar** key equivalent ⌘B if missing. `.toggleSidebar` handler must use Task 5b chrome path only. `navigateBack` toggles chrome collapse (directly or via ViewMode shim that reads `isCollapsed`) — never the old Dashboard width path.

- [ ] **Step 4:** Manual: ⌘B collapse shows lights+icons in terminal header; ⌘B again restores last pane; re-click First Mate while open collapses; Files/Changes greyed with no selection.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: route chrome header actions and ⌘B collapse"
```
---

### Task 7: Glass sidebar material

**Files:**
- Modify: `Sources/UI/Chrome/WindowChromeController.swift`
- Optionally reuse `WindowStyling.glassBackgroundConfig` patterns from `MainWindowController.swift`

- [ ] **Step 1:** Wrap `sidebarColumn` in `NSVisualEffectView`:
  - `blendingMode = .behindWindow`
  - material: if `#available(macOS 26.0, *)` use best available sidebar/glass material (check SDK); else `.sidebar`
  - `state = .active` when key window

- [ ] **Step 2:** Terminal column: solid `SemanticColors.panel2` / opaque layer — no vibrancy.

- [ ] **Step 3:** Ensure overview’s solid `DashboardOverviewView` background doesn’t fully opaque-block vibrancy — set overview root background clear / remove solid fill so glass shows through list area (row highlights stay translucent white overlays).

- [ ] **Step 4:** Visual check on macOS 14+ and 26 if available.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: apply vibrancy glass to chrome sidebar"
```

---

### Task 8: Worktree navigator row anatomy

**Files:**
- Create: `Sources/UI/Chrome/WorktreeNavigatorRowView.swift` (or replace `DashboardOverviewView.RowView` in place)
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift` (`DashboardOverviewView.update` / `RowView` ~`:2450+`)
- Test: `Tests/WorktreeNavigatorGroupingTests.swift` (optional pure grouping helper extract)

**Row layout (exact):**

```
●  current pane title                         time
   git diff                                   N panes
```

Group header = repo name only. **Repo grouping already exists** in `DashboardOverviewView.update` (~`:2280`) — do not reimplement; only restyle rows + headers. Selected = rounded rect fill, no left accent bar required. Idle expander: only preserve if already on this overview path; do not invent a new one.

- [ ] **Step 1:** Rewrite `RowView` to two-line layout; drop repo tag from line 1 (repo is group header). Keep status dot, title, time, git attributed string, pane count.

- [ ] **Step 2:** Keep composer + ORDERS zone.

- [ ] **Step 3:** Manual select/highlight check.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat: restyle worktree navigator rows under repo groups"
```

---

### Task 9: Terminal title + delete tab strip

**Files:**
- Modify: `Sources/App/MainWindowController.swift` (`updateTitleBar`, `refreshWorktreeTabs`, `refreshFocusedWorktreeCapsule`)
- Modify/Delete: `Sources/UI/TitleBar/TitleBarView.swift`
- Modify: tests that assert on worktree tabs (`Tests/TitleBarWorktreeNavTests.swift`, etc.)

- [ ] **Step 1:** Replace capsule/tab refresh with:

```swift
func updateChromeTitle() {
    // repo from selected sailor project; pane from focused leaf label / WorktreeTitleResolver
    windowChrome?.updateTerminalTitle(repo: repo, pane: paneTitle)
}
```

Call from former `updateTitleBar` sites; delete `refreshWorktreeTabs` body / callers.

- [ ] **Step 2:** Remove `TitleBarView` from window; delete file once no references (or leave empty deprecated type one commit, delete next).

- [ ] **Step 3:** Update/remove `TitleBarWorktreeNavTests` — replace with chrome title formatting tests.

- [ ] **Step 4:** Run unit tests:

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation test 2>&1 | tail -40
```

- [ ] **Step 5: Commit**

```bash
git commit -am "feat: drive terminal header title; remove title-bar tabs"
```

---

### Task 10: Keyboard `titlebar` region retarget

**Files:**
- Modify: `Sources/App/Region.swift`
- Modify: any `RegionFocusController` host wiring in `MainWindowController` / Dashboard

- [ ] **Step 1:** Map `Region.titlebar` focus to chrome header icon strip (sidebar header when expanded, terminal header when collapsed). Do not leave focus targeting removed accessory views.

- [ ] **Step 2:** Smoke Tab-cycle: panes → sidebar → titlebar(header) → helm → panes.

- [ ] **Step 3: Commit**

```bash
git commit -am "fix: retarget titlebar region to chrome headers"
```

---

### Task 11: UITest page objects + critical UI coverage

**Files:**
- Create/Rename: `UITests/Pages/ChromeHeaderPage.swift`
- Update callers of `TitleBarPage`
- Add UI test for ⌘B collapse + First Mate ↔ Files switch if harness allows

Accessibility ids (stable):

- `chrome.sidebarHeader`, `chrome.terminalHeader`
- `chrome.icon.*` as above
- `chrome.divider`
- `chrome.worktreeRow.<id>`

- [ ] **Step 1:** Update page object; fix compile of UITests.

- [ ] **Step 2:** Add `ChromeCollapseUITests` (or extend existing) — launch, ⌘B, assert terminal header icons exist / sidebar width gone.

- [ ] **Step 3:** Run filtered UI tests if environment supports:

```bash
./run_ui_tests.sh ChromeCollapseUITests
```

- [ ] **Step 4: Commit**

```bash
git commit -am "test: update chrome accessibility page objects and collapse UI test"
```

---

### Task 12: Cleanup + docs touch

**Files:**
- Delete dead TitleBar helpers / unused constants
- Optionally note in `docs/ui-spec.md` that layout is two-column chrome (brief; only if already maintained)

- [ ] **Step 1:** `rg TitleBarView|titleBarAccessory|refreshWorktreeTabs` — zero hits (except docs/history).

- [ ] **Step 2:** Full unit test suite green.

- [ ] **Step 3: Commit**

```bash
git commit -am "chore: remove dead title-bar chrome code"
```

---

## Verification checklist (human)

- [ ] No full-width title bar
- [ ] Drag divider; width survives relaunch
- [ ] ⌘B collapse: lights + icons in terminal header; title visible
- [ ] ⌘B expand restores last pane (or First Mate)
- [ ] First Mate shows grouped list; Files/Changes show side panel
- [ ] Re-click active pane icon collapses sidebar
- [ ] Files/Changes disabled (0.3) when no worktree selected
- [ ] Glass sidebar vs opaque terminal
- [ ] Worktree rows: two lines under repo group headers

## Execution notes

- Prefer small commits per task.
- Dashboard is large — prefer extracting hosts over a big-bang rewrite of `DashboardViewController.swift`.
- Do not introduce `NSSplitView`.
- Do not redesign StatusBar or right panels.
