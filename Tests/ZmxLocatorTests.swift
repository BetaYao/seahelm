import XCTest
@testable import seahelm

final class ZmxLocatorTests: XCTestCase {
    func testBundledAlwaysWinsOverPath() {
        let result = ZmxLocator.resolve(bundledPath: "/app/Resources/bin/seahelmd",
                                        pathLookup: { "/opt/homebrew/bin/seahelmd" })
        XCTAssertEqual(result, "/app/Resources/bin/seahelmd")
    }

    func testFallsBackToPathWhenNotBundled() {
        let result = ZmxLocator.resolve(bundledPath: nil,
                                        pathLookup: { "/opt/homebrew/bin/seahelmd" })
        XCTAssertEqual(result, "/opt/homebrew/bin/seahelmd")
    }

    func testNilWhenNeitherBundledNorOnPath() {
        let result = ZmxLocator.resolve(bundledPath: nil, pathLookup: { nil })
        XCTAssertNil(result)
    }

    func testExecutableIsNeverEmpty() {
        // With no bundled binary in the test host, executable() must still yield a
        // usable token so `/usr/bin/env <token>` resolves on PATH.
        XCTAssertFalse(ZmxLocator.executable().isEmpty)
    }

    // MARK: - isSupportedVersion

    func testSeahelmdVersionIsSupported() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("seahelmd 0.0.1"))
        XCTAssertTrue(ZmxLocator.isSupportedVersion("  seahelmd 1.2.3\n"))
    }

    /// A zmx left on PATH answers `version` too; it is not the daemon.
    func testAnythingElseIsNot() {
        XCTAssertFalse(ZmxLocator.isSupportedVersion("zmx 0.8.1"))
        XCTAssertFalse(ZmxLocator.isSupportedVersion("0.4.2"))
        XCTAssertFalse(ZmxLocator.isSupportedVersion("seahelmd"))
        XCTAssertFalse(ZmxLocator.isSupportedVersion(""))
    }

    /// The bundled daemon reports a version the app accepts.
    func testBundledDaemonIsSupported() throws {
        guard ZmxLocator.isAvailable else { throw XCTSkip("no seahelmd in this build") }
        XCTAssertEqual(ZmxLocator.resolveBackend().backend, "zmx")
    }
}
