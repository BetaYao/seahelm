import AppKit

/// Finder / clipboard / editor actions for a worktree directory, shared by the
/// sidebar context menu and anything else that acts on a worktree path.
enum CabinShellActions {
    /// Editors tried in order for "Open in Editor". First one installed wins —
    /// there is no editor preference in config yet.
    private static let editorBundleIds = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",
        "com.apple.dt.Xcode",
    ]

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Opens the worktree in the first installed editor from `editorBundleIds`.
    /// Returns false when none are installed, so the caller can tell the user.
    @discardableResult
    static func openInEditor(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        for bundleId in editorBundleIds {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { continue }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return false
    }
}
