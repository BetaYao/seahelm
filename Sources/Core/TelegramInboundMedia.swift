import Foundation

/// Pure helpers for turning Telegram photos/documents into order text the
/// command executor can hand a pane — escaped paths, plus any caption.
enum TelegramInboundMedia {
    /// Bot API downloads top out at 20 MB; refuse anything larger locally too.
    static let maxBytes = 20 * 1_024 * 1_024

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    ]

    /// The largest size Telegram attached — prefer `fileSize`, else area.
    static func preferredPhoto(_ sizes: [TelegramPhotoSize]) -> TelegramPhotoSize? {
        sizes.max { a, b in
            let left = a.fileSize ?? (a.width * a.height)
            let right = b.fileSize ?? (b.width * b.height)
            return left < right
        }
    }

    /// Whether a document is an image we should download (mime or extension).
    static func isImageDocument(_ document: TelegramDocument) -> Bool {
        if let mime = document.mimeType?.lowercased(), mime.hasPrefix("image/") {
            return true
        }
        guard let name = document.fileName else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// Caption first (the instruction), then escaped paths — so a note like
    /// "fix this" lands ahead of the file the agent should open. Paths alone
    /// when there is no caption; caption alone when download failed.
    static func composeOrderText(paths: [URL], caption: String?) -> String {
        let note = caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pathLine = paths.map { ShellEscape.backslash($0.path) }.joined(separator: " ")
        switch (pathLine.isEmpty, note.isEmpty) {
        case (true, true): return ""
        case (true, false): return note
        case (false, true): return pathLine
        case (false, false): return note + "\n" + pathLine
        }
    }

    /// Suggested on-disk name from a Telegram `file_path` or document name.
    static func fileName(telegramPath: String?, documentName: String?, fallback: String = "image.jpg") -> String {
        if let documentName, !documentName.isEmpty {
            return (documentName as NSString).lastPathComponent
        }
        if let telegramPath, !telegramPath.isEmpty {
            let base = (telegramPath as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return fallback
    }
}

/// Writes downloaded Telegram media under the caches directory.
final class TelegramMediaStore {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seahelm/telegram-media", isDirectory: true)
    }

    init(root: URL = TelegramMediaStore.defaultRoot) {
        self.root = root
    }

    /// Persist `data` under a per-message directory. Returns the written URL.
    func save(data: Data, fileName: String, messageId: Int) throws -> URL {
        guard data.count <= TelegramInboundMedia.maxBytes else {
            throw TelegramMediaStoreError.tooLarge
        }
        let safe = Self.sanitizedFileName(fileName)
        let dir = root.appendingPathComponent(String(messageId), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Strip path separators and keep a usable basename.
    static func sanitizedFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "image.jpg" : base
    }
}

enum TelegramMediaStoreError: Error {
    case tooLarge
}
