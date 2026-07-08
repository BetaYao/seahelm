import Foundation

/// Loads per-agent JSON manifests and compiles them. Precedence per id:
/// ~/.config/seahelm/agents/<id>.json (user override) > bundled Manifests/<id>.json.
/// Lookup resolves by manifest id or any alias.
final class ManifestStore {
    static let shared = ManifestStore()

    private var byId: [String: CompiledManifest] = [:]
    private var aliasToId: [String: String] = [:]

    private let userDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent(".config/seahelm/agents", isDirectory: true)
    }()

    init() { reload() }

    /// (Re)load all manifests. User overrides replace bundled entries with the same id.
    func reload() {
        var loaded: [String: CompiledManifest] = [:]

        for url in bundledManifestURLs() {
            if let m = Self.decode(url) { loaded[m.manifest.id] = m }
        }
        for url in userManifestURLs() {
            if let m = Self.decode(url) { loaded[m.manifest.id] = m }  // override wins
        }

        var aliases: [String: String] = [:]
        for (id, cm) in loaded {
            aliases[id] = id
            for a in cm.manifest.aliases { aliases[a.lowercased()] = id }
        }
        byId = loaded
        aliasToId = aliases
    }

    func manifest(for idOrAlias: String) -> CompiledManifest? {
        if let cm = byId[idOrAlias] { return cm }
        if let id = aliasToId[idOrAlias.lowercased()] { return byId[id] }
        return nil
    }

    var all: [CompiledManifest] { Array(byId.values) }

    // MARK: - Sources

    private func bundledManifestURLs() -> [URL] {
        Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Manifests") ?? []
    }

    private func userManifestURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: userDir,
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
    }

    private static func decode(_ url: URL) -> CompiledManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(AgentManifest.self, from: data)
            return CompiledManifest(try manifest.validated())
        } catch {
            NSLog("[ManifestStore] skipping %@: %@", url.lastPathComponent, String(describing: error))
            return nil
        }
    }
}
