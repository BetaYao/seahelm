import Foundation

/// Imports font settings from a Ghostty user config into Seahelm's overlay conf.
enum GhosttyConfigImporter {
    static var seahelmGhosttyConfURL: URL {
        Config.configDir.appendingPathComponent("ghostty.conf")
    }

    /// Candidate Ghostty config paths (Application Support first, then XDG).
    static func candidateSourceURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent(
                "Library/Application Support/com.mitchellh.ghostty/config"),
            home.appendingPathComponent(".config/ghostty/config"),
        ]
    }

    /// First existing Ghostty config among the usual locations.
    static func detectSourceURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        candidateSourceURLs(home: home).first { fileManager.fileExists(atPath: $0.path) }
    }

    struct FontSettings: Equatable {
        var family: String?
        var size: String?
    }

    /// Parse `font-family` / `font-size` from Ghostty conf text.
    static func parseFontSettings(from contents: String) -> FontSettings {
        var family: String?
        var size: String?
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "font-family":
                family = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            case "font-size":
                size = parts[1]
            default:
                break
            }
        }
        return FontSettings(family: family, size: size)
    }

    /// Merge font keys into an existing seahelm ghostty.conf without wiping other lines.
    static func mergeFontSettings(
        into existing: String,
        settings: FontSettings
    ) -> String {
        var lines = existing.components(separatedBy: .newlines)
        func upsert(key: String, value: String?) {
            guard let value, !value.isEmpty else { return }
            let prefix = "\(key) ="
            if let idx = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(key)
                    || $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
            }) {
                lines[idx] = "\(key) = \(value)"
            } else {
                if let last = lines.last, last.isEmpty {
                    lines.removeLast()
                }
                lines.append("\(key) = \(value)")
            }
        }
        upsert(key: "font-family", value: settings.family)
        upsert(key: "font-size", value: settings.size)
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// Import fonts from `source` into Seahelm's ghostty.conf. Returns false if
    /// the source is missing or has no font keys.
    @discardableResult
    static func importFonts(
        from source: URL,
        destination: URL = seahelmGhosttyConfURL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let data = fileManager.contents(atPath: source.path),
              let text = String(data: data, encoding: .utf8) else { return false }
        let settings = parseFontSettings(from: text)
        guard settings.family != nil || settings.size != nil else { return false }

        let existing: String
        if let destData = fileManager.contents(atPath: destination.path),
           let destText = String(data: destData, encoding: .utf8) {
            existing = destText
        } else {
            existing = "# Managed by Seahelm — font import from Ghostty\n"
        }
        let merged = mergeFontSettings(into: existing, settings: settings)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try merged.write(to: destination, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[GhosttyConfigImporter] Failed to write %@: %@", destination.path, "\(error)")
            return false
        }
    }
}
