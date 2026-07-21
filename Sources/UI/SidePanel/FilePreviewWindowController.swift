import AppKit
import QuickLookUI

/// Floating window that previews a single file with QuickLook, opened from the
/// pane context menu when the terminal selection resolves to an existing file.
///
/// A single shared window is reused across previews: re-invoking Preview just
/// retargets it and brings it forward, so repeated previews don't litter the
/// screen with windows.
final class FilePreviewWindowController: NSWindowController {

    static let shared = FilePreviewWindowController()

    private let previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        super.init(window: window)

        previewView.autostarts = true
        previewView.shouldCloseWithWindow = false
        window.contentView = previewView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Preview the file at `url`, reusing (and re-centering, if first shown) the
    /// shared window.
    func preview(url: URL) {
        guard let window else { return }
        window.title = url.lastPathComponent
        previewView.previewItem = url as NSURL
        previewView.refreshPreviewItem()
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
