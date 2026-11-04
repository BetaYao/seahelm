import XCTest
@testable import seahelm

final class PasteMediaTests: XCTestCase {
    func testComposeOrderTextJoinsCaptionAndPaths() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        XCTAssertEqual(
            PasteMedia.composeOrderText(paths: [url], caption: "  fix this  "),
            "fix this\n\(ShellEscape.backslash(url.path))")
        XCTAssertEqual(
            PasteMedia.composeOrderText(paths: [url], caption: nil),
            ShellEscape.backslash(url.path))
        XCTAssertEqual(
            PasteMedia.composeOrderText(paths: [], caption: "hello"),
            "hello")
        XCTAssertEqual(
            PasteMedia.composeOrderText(paths: [], caption: "  "),
            "")
    }

    func testPeelCachedMediaSeparatesCaptionFromImagePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-tg-peel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("shot.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: image) // minimal jpeg magic

        let composed = PasteMedia.composeOrderText(
            paths: [image], caption: "what is this?")
        let peeled = PasteMedia.peelCachedMedia(
            from: composed, root: root)
        XCTAssertEqual(peeled.urls.map(\.path), [image.standardizedFileURL.path])
        XCTAssertEqual(peeled.prose, "what is this?")

        let pathOnly = PasteMedia.peelCachedMedia(
            from: image.path, root: root)
        XCTAssertEqual(pathOnly.urls.map(\.path), [image.standardizedFileURL.path])
        XCTAssertEqual(pathOnly.prose, "")
    }

    func testPeelCachedMediaAcceptsPasteMediaRootAmongDefaults() throws {
        let pasteRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-paste-peel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: pasteRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pasteRoot) }
        let image = pasteRoot.appendingPathComponent("clip.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        let composed = PasteMedia.composeOrderText(
            paths: [image], caption: "from the dialog")
        let peeled = PasteMedia.peelCachedMedia(
            from: composed, roots: [pasteRoot])
        XCTAssertEqual(peeled.urls.map(\.path), [image.standardizedFileURL.path])
        XCTAssertEqual(peeled.prose, "from the dialog")
    }

    func testPasteMediaStorePersistsUnderCacheRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-paste-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PasteMediaStore(root: root)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = try store.save(data: png, fileName: "shot.png")
        XCTAssertTrue(url.path.hasPrefix(root.path))
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), png)
    }

    func testPasteMediaStoreImportsExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-paste-import-\(UUID().uuidString)", isDirectory: true)
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-paste-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: srcDir)
        }
        let source = srcDir.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: source)
        let store = PasteMediaStore(root: root)
        let imported = try store.importFile(at: source)
        XCTAssertTrue(imported.path.hasPrefix(root.path))
        XCTAssertEqual(try Data(contentsOf: imported), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertNotEqual(imported.path, source.path)
    }

    func testDefaultPeelRootsIncludePasteAndGatewayCaches() {
        let roots = PasteMedia.defaultPeelRoots.map(\.path)
        XCTAssertTrue(roots.contains(PasteMediaStore.defaultRoot.path))
        XCTAssertTrue(roots.contains(PasteMedia.gatewayMediaRoot.path))
    }
}
