import AppKit

// Extracted from the former `CommandInputView` when the fleet column's
// composer was removed in favor of the island. `AddWorktreePopoverController`
// is now the only user.

/// Multi-line text view that reports focus changes, draws a placeholder while
/// empty, and intercepts image pastes.
///
/// Unfocus is deferred one turn so a handoff (e.g. to a menu row's mouseDown
/// that re-focuses us) isn't mistaken for a blur.
final class GrowingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onPasteImage: ((URL) -> Void)?

    var placeholder: String = ""
    var placeholderColor: NSColor = .secondaryLabelColor
    var placeholderAccentColor: NSColor = .controlAccentColor
    var placeholderFont: NSFont = .systemFont(ofSize: 12.5)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let pad = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height)
        attributedPlaceholder().draw(at: origin)
    }

    /// Plain placeholder in a calm color, with just the `/ @ #` sigils lifted
    /// into the accent color so the command grammar reads at a glance.
    private func attributedPlaceholder() -> NSAttributedString {
        let str = NSMutableAttributedString(string: placeholder, attributes: [
            .foregroundColor: placeholderColor,
            .font: placeholderFont,
        ])
        let full = str.string as NSString
        for sigil in ["/", "@", "#"] {
            let r = full.range(of: sigil)
            if r.location != NSNotFound {
                str.addAttribute(.foregroundColor, value: placeholderAccentColor, range: r)
            }
        }
        return str
    }

    /// Where image pastes are read from. Only tests swap it.
    var pasteboard: NSPasteboard = .general

    override func paste(_ sender: Any?) {
        if let url = extractImageFromPasteboard() {
            onPasteImage?(url)
            return
        }
        super.pasteAsPlainText(sender)
    }

    /// Stock NSTextView enables Paste only when the clipboard has a type it can
    /// read as text (strings, RTF, file names). A screenshot is bare PNG/TIFF, so
    /// the Paste item stayed disabled and ⌘V never reached `paste(_:)` — image
    /// paste only ever worked for files copied in Finder.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteImage != nil, isEditable, pasteboardMayHoldImage {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    private var pasteboardMayHoldImage: Bool {
        pasteboard.types?.contains(where: {
            $0 == .png || $0 == .tiff || $0 == NSPasteboard.PasteboardType("public.file-url")
        }) == true
    }

    private func extractImageFromPasteboard() -> URL? {
        let pb = pasteboard
        guard pasteboardMayHoldImage else { return nil }

        // File-url pastes (Finder): copy into the peelable paste cache so
        // worktree create → agent attach can find them.
        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           NSImage(contentsOf: url) != nil {
            return try? PasteMediaStore().importFile(at: url)
        }

        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let fileName = "seahelm-paste-\(Int(Date().timeIntervalSince1970)).png"
        return try? PasteMediaStore().save(data: png, fileName: fileName)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let window = self.window else { self.onFocusChange?(false); return }
                if window.firstResponder === self { return }
                self.onFocusChange?(false)
            }
        }
        return ok
    }
}
