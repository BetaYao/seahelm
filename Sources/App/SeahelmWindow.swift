import AppKit

/// The app's `NSWindow`.
///
/// Split-pane shortcuts are handled in `performKeyEquivalent`, which AppKit
/// runs *before* menu-item key equivalents — that ordering is the whole reason
/// this subclass exists, so the bindings here win over the menu bar.

class SeahelmWindow: NSWindow {

    // performKeyEquivalent runs BEFORE menu item key equivalents,
    // so split pane shortcuts here take priority over menu bindings.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let mwc = windowController as? MainWindowController else {
            return super.performKeyEquivalent(with: event)
        }

        // Only handle split keybindings when dashboard has an active split container
        let hasSplitContext = mwc.tabCoordinator.dashboardVC?.activeSplitContainer != nil

        // Single source of truth for the window-level chord map (see GlobalKeymap).
        guard let shortcut = GlobalKeymap.resolve(
            chars: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            flags: flags,
            hasSplitContext: hasSplitContext
        ) else {
            return super.performKeyEquivalent(with: event)
        }

        switch shortcut {
        case .splitHorizontal:
            mwc.splitFocusedPane(axis: .horizontal); return true
        case .splitVertical:
            mwc.splitFocusedPane(axis: .vertical); return true
        case .moveFocus(let dir):
            let (axis, positive) = Self.axisPositive(dir)
            mwc.moveFocus(axis, positive: positive); return true
        case .resize(let dir):
            let (axis, delta) = Self.axisDelta(dir)
            mwc.resizeSplit(axis, delta: delta); return true
        case .resetRatio:
            mwc.resetSplitRatio(); return true
        case .nextWorktree:
            mwc.selectAdjacentWorktree(forward: true); return true
        case .prevWorktree:
            mwc.selectAdjacentWorktree(forward: false); return true
        case .toggleSidebar:
            mwc.toggleChromeCollapsed(); return true
        case .commandPalette:
            mwc.toggleCommandPalette(); return true
        }
    }

    /// Map a directional focus move to the (axis, positive) pair `moveFocus` expects.
    static func axisPositive(_ dir: FocusDirection) -> (SplitAxis, Bool) {
        switch dir {
        case .left:  return (.horizontal, false)
        case .right: return (.horizontal, true)
        case .down:  return (.vertical, true)
        case .up:    return (.vertical, false)
        }
    }

    /// Map a directional resize to the (axis, delta) pair `resizeSplit` expects.
    static func axisDelta(_ dir: FocusDirection) -> (SplitAxis, CGFloat) {
        switch dir {
        case .left:  return (.horizontal, -0.05)
        case .right: return (.horizontal, 0.05)
        case .down:  return (.vertical, 0.05)
        case .up:    return (.vertical, -0.05)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Escape: exit spotlight (existing)
            if event.keyCode == 53, WindowStyling.shouldHandleEscShortcut() {
                return
            }
            // Tab / Shift+Tab while the chrome header owns region focus: cycle
            // regions (dashboard's keyDown won't see these — icons are first responder).
            if event.keyCode == 48,
               let mwc = windowController as? MainWindowController,
               mwc.keyboardSubstate.isIdle,
               mwc.regionFocus.current == .titlebar {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.isDisjoint(with: [.command, .control, .option]) {
                    mwc.cycleKeyboardRegion(forward: !flags.contains(.shift))
                    return
                }
            }
        }
        super.sendEvent(event)
    }
}
