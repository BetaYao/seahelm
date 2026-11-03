import XCTest
@testable import seahelm

final class SeahelmdLocatorTests: XCTestCase {
    func testBundledAlwaysWinsOverPath() {
        let result = SeahelmdLocator.resolve(bundledPath: "/app/Resources/bin/seahelmd",
                                        pathLookup: { "/opt/homebrew/bin/seahelmd" })
        XCTAssertEqual(result, "/app/Resources/bin/seahelmd")
    }

    func testFallsBackToPathWhenNotBundled() {
        let result = SeahelmdLocator.resolve(bundledPath: nil,
                                        pathLookup: { "/opt/homebrew/bin/seahelmd" })
        XCTAssertEqual(result, "/opt/homebrew/bin/seahelmd")
    }

    func testNilWhenNeitherBundledNorOnPath() {
        let result = SeahelmdLocator.resolve(bundledPath: nil, pathLookup: { nil })
        XCTAssertNil(result)
    }

    func testExecutableIsNeverEmpty() {
        // With no bundled binary in the test host, executable() must still yield a
        // usable token so `/usr/bin/env <token>` resolves on PATH.
        XCTAssertFalse(SeahelmdLocator.executable().isEmpty)
    }

    // MARK: - isSupportedVersion

    func testSeahelmdVersionIsSupported() {
        XCTAssertTrue(SeahelmdLocator.isSupportedVersion("seahelmd 0.0.1"))
        XCTAssertTrue(SeahelmdLocator.isSupportedVersion("  seahelmd 1.2.3\n"))
    }

    /// Another tool on PATH may answer `version` too; it is not the daemon.
    func testAnythingElseIsNot() {
        XCTAssertFalse(SeahelmdLocator.isSupportedVersion("tmux 3.4"))
        XCTAssertFalse(SeahelmdLocator.isSupportedVersion("0.4.2"))
        XCTAssertFalse(SeahelmdLocator.isSupportedVersion("seahelmd"))
        XCTAssertFalse(SeahelmdLocator.isSupportedVersion(""))
    }

    /// The bundled daemon reports a version the app accepts.
    func testBundledDaemonIsSupported() throws {
        guard SeahelmdLocator.isAvailable else { throw XCTSkip("no seahelmd in this build") }
        XCTAssertEqual(SeahelmdLocator.resolveBackend().backend, "seahelmd")
    }
}
