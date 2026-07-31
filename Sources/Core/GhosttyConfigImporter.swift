import Foundation

/// Imports font settings from a Ghostty user config into Seahelm's overlay conf,
/// and reads/writes a few high-traffic keys Settings exposes (copy-on-select).
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
        var result = existing
        if let family = settings.family, !family.isEmpty {
            result = upsert(key: "font-family", value: family, into: result)
        }
        if let size = settings.size, !size.isEmpty {
            result = upsert(key: "font-size", value: size, into: result)
        }
        return result
    }

    /// Effective `copy-on-select` for Seahelm panes. Matches the bundled default
    /// (`false`) when the overlay conf omits the key; an explicit overlay value
    /// wins. Ghostty.app's own `~/.config/ghostty` is intentionally ignored —
    /// Seahelm owns the multiplexer behaviour.
    static func copyOnSelectEnabled(
        fileManager: FileManager = .default,
        destination: URL = seahelmGhosttyConfURL
    ) -> Bool {
        guard let data = fileManager.contents(atPath: destination.path),
              let text = String(data: data, encoding: .utf8),
              let value = boolValue(forKey: "copy-on-select", in: text) else {
            return false
        }
        return value
    }

    /// Persist `copy-on-select` into the Seahelm overlay conf (creating the file
    /// if needed). Does not touch Ghostty.app's own config.
    @discardableResult
    static func setCopyOnSelect(
        _ enabled: Bool,
        destination: URL = seahelmGhosttyConfURL,
        fileManager: FileManager = .default
    ) -> Bool {
        let existing: String
        if let data = fileManager.contents(atPath: destination.path),
           let text = String(data: data, encoding: .utf8) {
            existing = text
        } else {
            existing = "# Managed by Seahelm\n"
        }
        let merged = upsert(key: "copy-on-select", value: enabled ? "true" : "false", into: existing)
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

    /// Ensure the overlay conf exists so Finder can reveal it, then return its URL.
    @discardableResult
    static func ensureOverlayConf(
        destination: URL = seahelmGhosttyConfURL,
        fileManager: FileManager = .default
    ) -> URL {
        if !fileManager.fileExists(atPath: destination.path) {
            let starter = """
            # Managed by Seahelm — overrides Resources/ghostty.conf
            # copy-on-select = false
            """
            try? fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? starter.write(to: destination, atomically: true, encoding: .utf8)
        }
        return destination
    }

    /// Parse a boolean Ghostty key (`true`/`false`, case-insensitive). Nil when
    /// the key is absent or not a plain bool (e.g. `copy-on-select = clipboard`).
    static func boolValue(forKey key: String, in contents: String) -> Bool? {
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == key else { continue }
            switch parts[1].lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    /// Upsert `key = value` into conf text without dropping unrelated lines.
    static func upsert(key: String, value: String, into existing: String) -> String {
        var lines = existing.components(separatedBy: .newlines)
        let prefix = "\(key) ="
        if let idx = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix(prefix)
        }) {
            lines[idx] = "\(key) = \(value)"
        } else {
            if let last = lines.last, last.isEmpty {
                lines.removeLast()
            }
            lines.append("\(key) = \(value)")
        }
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
