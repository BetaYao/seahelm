import AppKit

/// The menu bar. Every item is something the app does today, and the key
/// shown is the one that does it — several shortcuts are handled first by
/// `SeahelmWindow` / `GlobalKeymap` (split, focus, ⌘B, ⌘P, ⌘J, ⌃Tab), so
/// those items are where the user finds them.
enum MenuBuilder {
    static func buildMainMenu(target: AnyObject? = nil) -> NSMenu {
        let mainMenu = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, toTarget: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            if toTarget { i.target = target }
            return i
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem()
            top.submenu = m
            mainMenu.addItem(top)
            return m
        }
        let sep = { NSMenuItem.separator() }

        // App
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        _ = menu("Seahelm", [
            item("About Seahelm", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toTarget: false),
            item("Check for Updates...", #selector(MainWindowController.checkForUpdates), "u"),
            sep(),
            item("Settings...", #selector(MainWindowController.showSettings), ","),
            item("Pair Remote Clients...", #selector(MainWindowController.showPairing)),
            sep(),
            services,
            sep(),
            item("Hide Seahelm", #selector(NSApplication.hide(_:)), "h", toTarget: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toTarget: false),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), toTarget: false),
            sep(),
            item("Quit Seahelm", #selector(NSApplication.terminate(_:)), "q", toTarget: false),
        ])

        // File: what goes into the fleet, and closing what is focused.
        _ = menu("File", [
            item("New Worktree...", #selector(MainWindowController.showNewBranchDialog), "n"),
            item("Add Project...", #selector(MainWindowController.addProject), "o"),
            sep(),
            item("Close Pane", #selector(MainWindowController.closePaneOrTab), "w"),
            sep(),
            item("Clean Orphan Sessions", #selector(MainWindowController.cleanOrphanSessions)),
        ])

        // Edit (standard; the responder chain answers these)
        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z", toTarget: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], toTarget: false),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x", toTarget: false),
            item("Copy", #selector(NSText.copy(_:)), "c", toTarget: false),
            item("Paste", #selector(NSText.paste(_:)), "v", toTarget: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", toTarget: false),
        ])

        // View: the left column and the window's look.
        _ = menu("View", [
            item("Toggle Sidebar", #selector(MainWindowController.toggleChromeCollapsed), "b"),
            item("Fleet", #selector(MainWindowController.showFleetPane)),
            item("Files", #selector(MainWindowController.showFilesPane)),
            item("Changes", #selector(MainWindowController.showChangesPane)),
            sep(),
            item("Toggle Light/Dark", #selector(MainWindowController.toggleThemeFromMenu)),
            sep(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], toTarget: false),
        ])

        // Pane: the focused worktree's split tree.
        _ = menu("Pane", [
            item("Split Horizontally", #selector(MainWindowController.splitHorizontal), "d"),
            item("Split Vertically", #selector(MainWindowController.splitVertical), "d", [.command, .shift]),
            sep(),
            item("Zoom Pane", #selector(MainWindowController.toggleZoomFocusedPane), "\r", [.command, .shift]),
            item("Reset Split Sizes", #selector(MainWindowController.resetSplitRatioFromMenu), "=", [.command, .control]),
            sep(),
            item("Close Pane", #selector(MainWindowController.closePaneOrTab)),
        ])

        // Fleet: moving around it and talking to it. The island's command bar
        // runs seahelm-core's command language (/new, /status, /go, /show).
        _ = menu("Fleet", [
            item("Command Bar", #selector(MainWindowController.toggleCommandPaletteFromMenu), "p"),
            item("First Mate", #selector(MainWindowController.toggleFirstMate), "j"),
            item("Status", #selector(MainWindowController.showFleetStatus)),
            sep(),
            item("Next Worktree", #selector(MainWindowController.selectNextWorktree), "\t", .control),
            item("Previous Worktree", #selector(MainWindowController.selectPreviousWorktree), "\t", [.control, .shift]),
        ])

        // Window (standard)
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.miniaturize(_:)), "m", toTarget: false),
            item("Zoom", #selector(NSWindow.zoom(_:)), toTarget: false),
            sep(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), toTarget: false),
        ])
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = menu("Help", [
            item("Keyboard Shortcuts", #selector(MainWindowController.showKeyboardShortcuts)),
            sep(),
            item("Seahelm Documentation", #selector(MainWindowController.openDocumentation)),
            item("Report an Issue...", #selector(MainWindowController.reportIssue)),
        ])
        NSApp.helpMenu = helpMenu

        return mainMenu
    }
}
