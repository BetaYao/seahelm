import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Attaches dropped images to an agent's prompt the way the agent pastes them
/// itself — image on the clipboard, then its paste-image key — so a drop lands
/// as an attachment (Claude Code's `[Image #1]`) instead of a path.
///
/// Only agents whose image paste is known qualify. Claude Code binds
/// `chat:imagePaste` to ctrl+v on macOS and reads the clipboard with
/// `osascript -e 'the clipboard as «class PNGf»'`, so each image goes up as PNG.
/// Shells, other agents and non-image files keep getting paths.
enum AgentImagePaste {
    /// How long the agent gets to read the clipboard before the next image
    /// replaces it. Claude Code shells out to osascript for every paste.
    static let pasteInterval: TimeInterval = 0.8
    /// Extra time after the last image before the user's clipboard comes back.
    static let restoreDelay: TimeInterval = 1.5

    static func supports(_ agent: AgentType?) -> Bool {
        agent == .claudeCode
    }

    /// Whether `url` names an image by its type (png, jpeg, heic, gif, webp…).
    /// PDFs and other documents are not images and stay paths.
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .image) == true
    }

    /// Attach the images among `urls` to `station`'s agent, in order. Decoding
    /// runs off the main thread. `completion` gets, on main, the files that were
    /// not attached (non-images, undecodable images) once the last image has had
    /// its read time, so they can follow as paths.
    static func attach(_ urls: [URL], to station: Station, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var images: [Data] = []
            var notAttached: [URL] = []
            for url in urls {
                if isImage(url), let png = pngData(for: url) {
                    images.append(png)
                } else {
                    notAttached.append(url)
                }
            }
            DispatchQueue.main.async {
                paste(images: images, pressPasteKey: { [weak station] in station?.sendImagePasteKey() }) {
                    completion(notAttached)
                }
            }
        }
    }

    /// PNG bytes for an image file: the file itself when it already is a PNG,
    /// otherwise re-encoded with its orientation applied. Nil when it can't be
    /// decoded.
    static func pngData(for url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if data.starts(with: pngSignature) {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Put each image on `pasteboard` in turn and press the paste key, waiting
    /// `interval` between images, then give the user's clipboard back after
    /// `restoreAfter` — unless they copied something in the meantime. Main
    /// thread. `completion` runs after the last image's read time.
    static func paste(
        images: [Data],
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = pasteInterval,
        restoreAfter: TimeInterval = restoreDelay,
        pressPasteKey: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        guard !images.isEmpty else {
            completion()
            return
        }
        let saved = snapshot(pasteboard)
        var remaining = images[...]
        var ourChangeCount = pasteboard.changeCount
        func pasteNext() {
            guard let image = remaining.popFirst() else {
                completion()
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) {
                    guard pasteboard.changeCount == ourChangeCount else { return }
                    restore(saved, to: pasteboard)
                }
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(image, forType: .png)
            ourChangeCount = pasteboard.changeCount
            pressPasteKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: pasteNext)
        }
        pasteNext()
    }

    /// Every item on `pasteboard`, copied out type by type so it survives
    /// `clearContents`.
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
