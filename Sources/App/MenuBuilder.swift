import AppKit

enum MenuBuilder {
    static func buildMainMenu(target: AnyObject? = nil) -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(MainWindowController.showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = target
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        let checkUpdateItem = NSMenuItem(title: "Check for Updates...", action: #selector(MainWindowController.checkForUpdates), keyEquivalent: "u")
        checkUpdateItem.keyEquivalentModifierMask = .command
        checkUpdateItem.target = target
        appMenu.addItem(checkUpdateItem)
        let cleanOrphanSessionsItem = NSMenuItem(title: "Clean Orphan Sessions", action: #selector(MainWindowController.cleanOrphanSessions), keyEquivalent: "")
        cleanOrphanSessionsItem.target = target
        appMenu.addItem(cleanOrphanSessionsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit seahelm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // First Mate menu — opens the Helm cockpit with a slash command prefilled.
        // Aligned with BridgeCommand verbs. Cmd+R is plain; letter chords take
        // Shift to avoid Cmd+C (copy), Cmd+B (sidebar), and Cmd+A (select all).
        let firstMateMenuItem = NSMenuItem()
        let firstMateMenu = NSMenu(title: "First Mate")
        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Task (/task)", #selector(MainWindowController.helmTaskCommand), "t", [.command, .shift]),
            ("Agents (/agents)", #selector(MainWindowController.helmAgentsCommand), "", []),
            ("Order (/order)", #selector(MainWindowController.helmOrderCommand), "o", [.command, .shift]),
            ("Broadcast (/broadcast)", #selector(MainWindowController.helmBroadcastCommand), "b", [.command, .shift]),
            ("Return (/return)", #selector(MainWindowController.helmReturnCommand), "r", .command),
            ("Add Deck (/add)", #selector(MainWindowController.helmAddRepoCommand), "a", [.command, .shift]),
        ]
        for (title, action, key, mods) in commands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            firstMateMenu.addItem(item)
        }
        firstMateMenuItem.submenu = firstMateMenu
        mainMenu.addItem(firstMateMenuItem)

        // Edit menu (standard Cut/Copy/Paste/Undo/Redo)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let splitHItem = NSMenuItem(
            title: "Split Horizontally",
            action: #selector(MainWindowController.splitHorizontal),
            keyEquivalent: "d"
        )
        splitHItem.keyEquivalentModifierMask = .command
        splitHItem.target = target
        viewMenu.addItem(splitHItem)

        let splitVItem = NSMenuItem(
            title: "Split Vertically",
            action: #selector(MainWindowController.splitVertical),
            keyEquivalent: "d"
        )
        splitVItem.keyEquivalentModifierMask = [.command, .shift]
        splitVItem.target = target
        viewMenu.addItem(splitVItem)

        viewMenu.addItem(NSMenuItem.separator())

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(MainWindowController.toggleChromeCollapsed),
            keyEquivalent: "b"
        )
        toggleSidebarItem.keyEquivalentModifierMask = .command
        toggleSidebarItem.target = target
        viewMenu.addItem(toggleSidebarItem)

        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(MainWindowController.closePaneOrTab), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = .command
        closePaneItem.target = target
        viewMenu.addItem(closePaneItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu (standard macOS window management)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(MainWindowController.selectNextTab), keyEquivalent: "}")
        nextTabItem.keyEquivalentModifierMask = .command
        nextTabItem.target = target
        windowMenu.addItem(nextTabItem)
        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(MainWindowController.selectPreviousTab), keyEquivalent: "{")
        prevTabItem.keyEquivalentModifierMask = .command
        prevTabItem.target = target
        windowMenu.addItem(prevTabItem)
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let keyboardShortcutsItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(MainWindowController.showKeyboardShortcuts), keyEquivalent: "")
        keyboardShortcutsItem.target = target
        helpMenu.addItem(keyboardShortcutsItem)
        helpMenu.addItem(NSMenuItem.separator())
        let docsItem = NSMenuItem(title: "seahelm Documentation", action: #selector(MainWindowController.openDocumentation), keyEquivalent: "")
        docsItem.target = target
        helpMenu.addItem(docsItem)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }
}
