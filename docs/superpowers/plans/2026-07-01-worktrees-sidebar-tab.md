# Worktrees Sidebar Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating worktree popover with a global "Worktrees" tab in the left sidebar, next to File/Changes.

**Architecture:** Add `SidePanelTab.worktrees` to `WorktreeSidePanelViewController`; it embeds a host-provided card-list view (`worktreesTabView`). `DashboardViewController` provides its existing `leftRightSidebarScroll` (currently popover-only) as that view, exposes `openWorktreesTab()` (populate + select tab + expand column), and deletes the `NSPopover`. `MainWindowController`'s title-bar delegate routes the worktree icon to `openWorktreesTab()`.

**Tech Stack:** Swift 5.10, AppKit, XcodeGen (`project.yml`), macOS 14+.

## Global Constraints

- Tab display name: **Worktrees**.
- Clicking the title-bar worktree icon **expands a collapsed left column and opens the tab** (reuse the expand logic already in `selectLeftPane`).
- The `.worktrees` tab is **global** (all projects' worktrees) — unlike `files`/`changes` which are scoped to the selected worktree.
- Do NOT change card visuals, tap-to-select behavior, idle-collapse, or the `files`/`changes`/`firstMate` tabs.
- `leftRightSidebarScroll` is currently parented ONLY to the popover host (verified) — reparenting it into the sidebar is safe.
- Build/test commands MUST pass `-skipPackagePluginValidation -skipMacroValidation`; SwiftLint failures on `CodeEdit*` packages are pre-existing — ignore them.
- Reference spec: `docs/superpowers/specs/2026-07-01-worktrees-sidebar-tab-design.md`.

---

### Task 1: Add the `.worktrees` sidebar tab

**Files:**
- Modify: `Sources/UI/SidePanel/WorktreeSidePanelViewController.swift` (enum at `:3-7`, add property, `rebuildContent` at `:155-184`)
- Test: `Tests/WorktreeSidePanelWorktreesTabTests.swift`

**Interfaces:**
- Produces:
  - `enum SidePanelTab { case firstMate=0, files=1, changes=2, worktrees=3 }`
  - `WorktreeSidePanelViewController.worktreesTabView: NSView?` — host-provided card list, embedded when the `.worktrees` tab is active.

- [ ] **Step 1: Write the failing tests**

Create `Tests/WorktreeSidePanelWorktreesTabTests.swift`:

```swift
import XCTest
@testable import seahelm

final class WorktreeSidePanelWorktreesTabTests: XCTestCase {
    func testWorktreesTabEmbedsProvidedView() {
        let vc = WorktreeSidePanelViewController(worktreePath: nil, initialTab: .files)
        _ = vc.view  // force loadView
        let stub = NSView()
        vc.worktreesTabView = stub
        vc.selectTab(.worktrees)
        XCTAssertEqual(vc.selectedTabForTesting, .worktrees)
        XCTAssertNotNil(stub.superview, "the provided worktrees view should be embedded")
    }

    func testWorktreesTabWithNoViewShowsPlaceholderNotCrash() {
        let vc = WorktreeSidePanelViewController(worktreePath: nil, initialTab: .files)
        _ = vc.view
        vc.worktreesTabView = nil
        vc.selectTab(.worktrees)   // must not crash
        XCTAssertEqual(vc.selectedTabForTesting, .worktrees)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/WorktreeSidePanelWorktreesTabTests 2>&1 | tail -15`
Expected: FAIL — compile error, `SidePanelTab` has no `.worktrees` / no `worktreesTabView`. (After adding the test file to the project you may need `xcodegen generate` first; if the whole target fails to compile, that is the expected failing state.)

- [ ] **Step 3: Add the enum case**

In `Sources/UI/SidePanel/WorktreeSidePanelViewController.swift`, change:

```swift
enum SidePanelTab: Int {
    case firstMate = 0
    case files = 1
    case changes = 2
}
```
to:
```swift
enum SidePanelTab: Int {
    case firstMate = 0
    case files = 1
    case changes = 2
    case worktrees = 3
}
```

- [ ] **Step 4: Add the `worktreesTabView` property**

In the same file, near the other view properties (e.g. just after `private let contentView = NSView()` around `:21`), add:

```swift
    /// Host-provided view (the cross-project worktree card list) shown for the
    /// `.worktrees` tab. Set by the dashboard, which owns the card data.
    var worktreesTabView: NSView?
```

- [ ] **Step 5: Handle `.worktrees` in `rebuildContent()`**

In `rebuildContent()` (`:155-184`), add a case to the `switch selectedTab` — put it after the `.changes` case:

```swift
        case .worktrees:
            showWorktreesTab()
```

Then add the `showWorktreesTab()` method right after `rebuildContent()`:

```swift
    private func showWorktreesTab() {
        guard let listView = worktreesTabView else {
            showPlaceholder("No worktrees", identifier: "sidePanel.worktreesPlaceholder")
            return
        }
        listView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(listView)
        NSLayoutConstraint.activate([
            listView.topAnchor.constraint(equalTo: contentView.topAnchor),
            listView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
```

(`showPlaceholder(_:identifier:)` already exists at `:326`. `rebuildContent` already clears `contentView.subviews` at the top, so switching away removes the reparented list; the dashboard keeps a strong reference so it is not deallocated.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug -skipPackagePluginValidation -skipMacroValidation test -only-testing:seahelmTests/WorktreeSidePanelWorktreesTabTests 2>&1 | tail -8`
Expected: PASS — "Executed 2 tests, with 0 failures".

- [ ] **Step 7: Commit**

```bash
git add Sources/UI/SidePanel/WorktreeSidePanelViewController.swift Tests/WorktreeSidePanelWorktreesTabTests.swift seahelm.xcodeproj/project.pbxproj
git commit -m "feat: add a .worktrees tab to the left sidebar"
```

---

### Task 2: Provide the card list, add `openWorktreesTab`, delete the popover

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardViewController.swift` (sidePanelVC `:129-130`, `selectLeftPane` `:301-317`, popover `:319-352`, `closeWorktreePopover()` call `:1046`)
- Modify: `Sources/App/MainWindowController.swift` (`titleBarDidToggleWorktreeList` `:1071`)

**Interfaces:**
- Consumes: `WorktreeSidePanelViewController.worktreesTabView` (Task 1), `sidePanelVC.selectTab(.worktrees)`, existing `populateWorktreeCards()` and `leftRightSidebarScroll`.
- Produces: `DashboardViewController.openWorktreesTab()`, `DashboardViewController.expandLeftColumnIfCollapsed()`.

- [ ] **Step 1: Extract the column-expand helper from `selectLeftPane`**

In `DashboardViewController.swift`, `selectLeftPane(_:)` (`:301-317`) ends with an inline expand block. Replace:

```swift
        guard isLeftColumnCollapsed else { return }
        isLeftColumnCollapsed = false
        leftColumnWidthExpanded?.isActive = true
        leftColumnWidthCollapsed?.isActive = false
        animateColumnLayout {
            self.leftColumnContainer.animator().alphaValue = 1
        }
    }
```
with:
```swift
        expandLeftColumnIfCollapsed()
    }

    /// Expand the left column if it is currently collapsed (no-op otherwise).
    func expandLeftColumnIfCollapsed() {
        guard isLeftColumnCollapsed else { return }
        isLeftColumnCollapsed = false
        leftColumnWidthExpanded?.isActive = true
        leftColumnWidthCollapsed?.isActive = false
        animateColumnLayout {
            self.leftColumnContainer.animator().alphaValue = 1
        }
    }
```

- [ ] **Step 2: Add `openWorktreesTab()`**

Add this method to `DashboardViewController` (e.g. right after `selectLeftPane`/`expandLeftColumnIfCollapsed`):

```swift
    /// Open the global Worktrees tab in the left sidebar: refresh the card list,
    /// select the tab, and expand the column if collapsed. Replaces the old
    /// floating worktree popover.
    func openWorktreesTab() {
        populateWorktreeCards()
        sidePanelVC.selectTab(.worktrees)
        expandLeftColumnIfCollapsed()
    }
```

- [ ] **Step 3: Hand the card list to the sidebar**

Find where the dashboard finishes building the left-right layout (the sidebar and `leftRightSidebarScroll` both exist by the time the view is set up). Immediately after `setupLeftRightLayout()` is called in the setup flow (search for `setupLeftRightLayout()` around `:158`), add:

```swift
        sidePanelVC.worktreesTabView = leftRightSidebarScroll
```

(`sidePanelVC` is a lazy property at `:129`; accessing it here is fine. `leftRightSidebarScroll` at `:117` is configured by `setupLeftRightLayout`.)

- [ ] **Step 4: Delete the popover**

Remove the entire `// MARK: - Worktree popover` block (`:319-352`): the `worktreePopover` lazy property, `toggleWorktreePopover(from:)`, and `closeWorktreePopover()`.

Then remove the now-dangling call at `:1046`:
```swift
        // Selecting from the worktree popover dismisses it.
        closeWorktreePopover()
```
(delete both the comment line and the call.)

- [ ] **Step 5: Rewire the title-bar delegate to the sidebar tab**

In `Sources/App/MainWindowController.swift`, change `titleBarDidToggleWorktreeList` (`:1071`):

```swift
    func titleBarDidToggleWorktreeList(from sourceView: NSView) {
        tabCoordinator.dashboardVC?.toggleWorktreePopover(from: sourceView)
    }
```
to:
```swift
    func titleBarDidToggleWorktreeList(from sourceView: NSView) {
        tabCoordinator.dashboardVC?.openWorktreesTab()
    }
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`. (If the compiler flags any remaining reference to `worktreePopover`, `toggleWorktreePopover`, or `closeWorktreePopover`, remove it — there should be none left after Steps 4–5.)

- [ ] **Step 7: Launch-verify the behavior**

Run:
```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/seahelm-*/Build/Products/Debug/seahelm.app | head -1)
"$APP/Contents/MacOS/seahelm" >/tmp/seahelm-wt.log 2>&1 & sleep 5
pgrep -x seahelm >/dev/null && echo ALIVE || echo EXITED
pkill -x seahelm 2>/dev/null; true
```
Expected: `ALIVE`. Then manually (or note for the reviewer): click the title-bar worktree icon → the left column expands and shows the Worktrees tab with the cross-project cards (no floating popover); tapping a card switches the active worktree; switching to File/Changes and back preserves the list.

- [ ] **Step 8: Commit**

```bash
git add Sources/UI/Dashboard/DashboardViewController.swift Sources/App/MainWindowController.swift
git commit -m "feat: open the Worktrees list in the sidebar tab, remove the popover"
```

---

## Self-Review

**Spec coverage:**
- New `.worktrees` sidebar tab → Task 1. ✓
- Card list moves into sidebar, dashboard stays owner (`worktreesTabView` = `leftRightSidebarScroll`) → Task 1 (property) + Task 2 Step 3 (wiring). ✓
- Title-bar icon selects tab + expands column, popover removed → Task 2 Steps 1–5. ✓
- Tap-to-select unchanged → no task needed (existing card behavior; verified in Task 2 Step 7). ✓
- Global tab vs per-worktree scope → inherent (the tab shows the dashboard's global `agents` list). ✓

**Placeholder scan:** No TBD/vague steps; every code step shows the exact before/after. The only manual element is Task 2 Step 7's visual check, which is explicit.

**Type consistency:** `SidePanelTab.worktrees` (Task 1) is used by `sidePanelVC.selectTab(.worktrees)` (Task 2). `worktreesTabView: NSView?` (Task 1) is set from `leftRightSidebarScroll` (Task 2 Step 3). `openWorktreesTab()` / `expandLeftColumnIfCollapsed()` (Task 2) are called from `titleBarDidToggleWorktreeList` (Task 2 Step 5). Consistent.
