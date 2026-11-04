import Foundation

/// Images an order carries as paths: the New-worktree dialog's pastes, and
/// what seahelm-gateway downloads from Telegram. `PaneInput.sendCommand` peels
/// them back out and attaches them to an agent that can take a pasted image.
enum PasteMedia {
    /// Refuse anything larger than this locally.
    static let maxBytes = 20 * 1_024 * 1_024

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    ]

    /// Caption first (the instruction), then escaped paths — so a note like
    /// "fix this" lands ahead of the file the agent should open.
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

    /// seahelm-gateway's Telegram downloads (docs/seahelm-gateway-plan.md).
    static var gatewayMediaRoot: URL {
        Config.configDir.appendingPathComponent("gateway/telegram/media", isDirectory: true)
    }

    /// Cache roots whose image paths may be peeled out of an order.
    static var defaultPeelRoots: [URL] {
        [PasteMediaStore.defaultRoot, gatewayMediaRoot]
    }

    /// Split an order into cached image paths and the remaining prose. Lines
    /// whose every whitespace token is an image under one of `roots` are
    /// peeled; everything else stays as text for the agent.
    static func peelCachedMedia(
        from text: String,
        roots: [URL] = defaultPeelRoots,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (urls: [URL], prose: String) {
        let rootLowers = roots.map { $0.standardizedFileURL.path.lowercased() }
        var urls: [URL] = []
        var proseLines: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !tokens.isEmpty else {
                proseLines.append(line)
                continue
            }
            var lineURLs: [URL] = []
            var allMedia = true
            for token in tokens {
                let path = URL(fileURLWithPath: token).standardizedFileURL.path
                let pathLower = path.lowercased()
                let ext = (path as NSString).pathExtension.lowercased()
                let underCache = rootLowers.contains { pathLower.hasPrefix($0) }
                if underCache, imageExtensions.contains(ext), fileExists(token) || fileExists(path) {
                    lineURLs.append(URL(fileURLWithPath: path))
                } else {
                    allMedia = false
                    break
                }
            }
            if allMedia {
                urls.append(contentsOf: lineURLs)
            } else {
                proseLines.append(line)
            }
        }
        let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (urls, prose)
    }

    static func peelCachedMedia(
        from text: String,
        root: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (urls: [URL], prose: String) {
        peelCachedMedia(from: text, roots: [root], fileExists: fileExists)
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

/// Clipboard / dialog image pastes that must survive until the agent attaches
/// them.
final class PasteMediaStore {
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seahelm/paste-media", isDirectory: true)
    }

    init(root: URL = PasteMediaStore.defaultRoot) {
        self.root = root
    }

    /// Persist raw image bytes under a unique directory.
    func save(data: Data, fileName: String) throws -> URL {
        guard data.count <= PasteMedia.maxBytes else { throw PasteMediaStoreError.tooLarge }
        let safe = PasteMedia.sanitizedFileName(fileName)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Copy an existing image into the paste cache so peel + agent paste see a
    /// stable path under `defaultRoot` (Finder file-url pastes land here).
    func importFile(at source: URL) throws -> URL {
        let data = try Data(contentsOf: source)
        let name = source.lastPathComponent.isEmpty ? "image.png" : source.lastPathComponent
        return try save(data: data, fileName: name)
    }
}

enum PasteMediaStoreError: Error {
    case tooLarge
}
