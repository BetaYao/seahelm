import XCTest
@testable import seahelm

final class OpenCodePluginInstallerTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-opencode-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return tmp
    }

    func testInstallsPluginFile() throws {
        let tmp = try makeTempDir()
        XCTAssertTrue(OpenCodePluginInstaller.ensureInstalled(pluginsDirectory: tmp))
        let js = tmp.appendingPathComponent("seahelm-suggest.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: js.path))
        XCTAssertFalse(OpenCodePluginInstaller.ensureInstalled(pluginsDirectory: tmp)) // idempotent
    }

    func testRewritesOurOwnStalePlugin() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let js = tmp.appendingPathComponent("seahelm-suggest.js")
        try "// seahelm-suggest-plugin v1 — stale\nexport const Old = 1\n"
            .write(to: js, atomically: true, encoding: .utf8)

        XCTAssertTrue(OpenCodePluginInstaller.ensureInstalled(pluginsDirectory: tmp))
        let contents = try String(contentsOf: js, encoding: .utf8)
        XCTAssertTrue(contents.contains("seahelm_suggest"))
    }

    /// Users keep their own plugins in this directory — the real one on this
    /// machine holds a symlinked superpowers.js. A same-named file without our
    /// marker is someone else's; clobbering it would delete their work.
    func testLeavesForeignPluginAlone() throws {
        let tmp = try makeTempDir()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let js = tmp.appendingPathComponent("seahelm-suggest.js")
        let foreign = "export const NotOurs = async () => ({})\n"
        try foreign.write(to: js, atomically: true, encoding: .utf8)

        XCTAssertFalse(OpenCodePluginInstaller.ensureInstalled(pluginsDirectory: tmp))
        XCTAssertEqual(try String(contentsOf: js, encoding: .utf8), foreign)
    }

    /// opencode's loader reads `plugins/`, plural — its docs say `plugin/`. A file
    /// in the singular directory is ignored with no error, so this is worth pinning.
    func testInstallsIntoPluralPluginsDirectoryUnderXDGConfigHome() {
        let dir = OpenCodePluginInstaller.pluginsDirectory().path
        XCTAssertTrue(dir.hasSuffix("/opencode/plugins"), "unexpected plugins dir: \(dir)")

        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            XCTAssertTrue(dir.hasPrefix(xdg))
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            XCTAssertEqual(dir, "\(home)/.config/opencode/plugins")
        }
    }

    func testPluginCallsTheInstalledSuggestScriptAndDeclaresTheTool() {
        let js = OpenCodePluginInstaller.pluginContents()
        XCTAssertTrue(js.contains("seahelm_suggest"))
        // The plugin must shell out to the script SeahelmSuggestInstaller writes,
        // not re-implement the socket write and pane-id fallback.
        XCTAssertTrue(js.contains("/.local/bin/seahelm-suggest"))
        // Swift interpolation is \(…), so JS template `${…}` must survive verbatim.
        XCTAssertTrue(js.contains("${SCRIPT} ${options}"))
        XCTAssertFalse(js.contains("u0024"))
    }
}
