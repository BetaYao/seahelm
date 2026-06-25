import XCTest
@testable import seahelm

final class WorktreeCreatorEnvCopyTests: XCTestCase {
    private var src: URL!
    private var dst: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-envcopy-\(UUID().uuidString)", isDirectory: true)
        src = base.appendingPathComponent("src", isDirectory: true)
        dst = base.appendingPathComponent("dst", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
    }

    func testCopiesEnvFilesOnly() throws {
        try "A=1".write(to: src.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "B=2".write(to: src.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try "use nix".write(to: src.appendingPathComponent(".envrc"), atomically: true, encoding: .utf8)
        let nodeModules = src.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "x".write(to: nodeModules.appendingPathComponent("pkg.js"), atomically: true, encoding: .utf8)

        WorktreeCreator.copyEnvironmentFiles(from: src.path, to: dst.path)

        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent(".env")), "A=1")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent(".env.local")), "B=2")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent(".envrc")), "use nix")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("node_modules").path))
    }

    func testNoEnvFilesDoesNotThrow() {
        WorktreeCreator.copyEnvironmentFiles(from: src.path, to: dst.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent(".env").path))
    }
}
