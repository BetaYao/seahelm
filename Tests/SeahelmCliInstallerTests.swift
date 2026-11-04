import XCTest
@testable import seahelm

final class SeahelmCliInstallerTests: XCTestCase {
    private var dir: URL!
    private var source: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("seahelm-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        source = dir.appendingPathComponent("bundled-seahelm")
        try? Data("#!/bin/sh\necho v1\n".utf8).write(to: source)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testInstallsTheBundledProgramExecutable() throws {
        let bin = dir.appendingPathComponent("bin")
        XCTAssertTrue(SeahelmCliInstaller.ensureInstalled(binDirectory: bin, from: source))
        let installed = bin.appendingPathComponent("seahelm")
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: source))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    func testSameBytesAreNotRewritten() {
        let bin = dir.appendingPathComponent("bin")
        XCTAssertTrue(SeahelmCliInstaller.ensureInstalled(binDirectory: bin, from: source))
        XCTAssertFalse(SeahelmCliInstaller.ensureInstalled(binDirectory: bin, from: source))
    }

    /// The Python script an older seahelm wrote is replaced.
    func testReplacesWhatIsThere() throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n# seahelm-cli v11\n".utf8).write(to: bin.appendingPathComponent("seahelm"))
        XCTAssertTrue(SeahelmCliInstaller.ensureInstalled(binDirectory: bin, from: source))
        XCTAssertEqual(try Data(contentsOf: bin.appendingPathComponent("seahelm")), try Data(contentsOf: source))
    }

    func testNothingBundledInstallsNothing() {
        let bin = dir.appendingPathComponent("bin")
        XCTAssertFalse(SeahelmCliInstaller.ensureInstalled(binDirectory: bin, from: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("seahelm").path))
    }
}
