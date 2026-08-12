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

    override func paste(_ sender: Any?) {
        if let url = Self.extractImageFromPasteboard() {
            onPasteImage?(url)
            return
        }
        super.pasteAsPlainText(sender)
    }

    private static func extractImageFromPasteboard() -> URL? {
        let pb = NSPasteboard.general
        guard pb.types?.contains(where: {
            $0 == .png || $0 == .tiff || $0 == NSPasteboard.PasteboardType("public.file-url")
        }) == true else { return nil }

        if let url = pb.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
           NSImage(contentsOf: url) != nil {
            return url
        }

        guard let image = NSImage(pasteboard: pb) else { return nil }
        guard let rep = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
        let fileName = "seahelm-paste-\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = tmpDir.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
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
