import XCTest
@testable import seahelm

final class ZmxLocatorTests: XCTestCase {
    func testBundledAlwaysWinsOverPath() {
        let result = ZmxLocator.resolve(bundledPath: "/app/Resources/bin/zmx",
                                        pathLookup: { "/opt/homebrew/bin/zmx" })
        XCTAssertEqual(result, "/app/Resources/bin/zmx")
    }

    func testFallsBackToPathWhenNotBundled() {
        let result = ZmxLocator.resolve(bundledPath: nil,
                                        pathLookup: { "/opt/homebrew/bin/zmx" })
        XCTAssertEqual(result, "/opt/homebrew/bin/zmx")
    }

    func testNilWhenNeitherBundledNorOnPath() {
        let result = ZmxLocator.resolve(bundledPath: nil, pathLookup: { nil })
        XCTAssertNil(result)
    }

    func testExecutableFallsBackToLiteralZmx() {
        // With no bundled binary in the test host, executable() must still yield a
        // usable token so `/usr/bin/env <token>` resolves on PATH.
        XCTAssertFalse(ZmxLocator.executable().isEmpty)
    }

    // MARK: - isSupportedVersion

    func test042IsSupported() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("0.4.2"))
    }

    func test050IsSupported() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("0.5.0"))
    }

    func test100IsSupported() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("1.0.0"))
    }

    func test041IsUnsupported() {
        XCTAssertFalse(ZmxLocator.isSupportedVersion("0.4.1"))
    }

    func test030IsUnsupported() {
        XCTAssertFalse(ZmxLocator.isSupportedVersion("0.3.0"))
    }

    func testWhitespaceTrimming() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("  0.4.2  "))
        XCTAssertFalse(ZmxLocator.isSupportedVersion("  0.4.1  "))
    }

    func testVersionWithVPrefix() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("v0.4.2"))
        XCTAssertFalse(ZmxLocator.isSupportedVersion("v0.4.1"))
    }

    func testVersionEmbeddedInOutput() {
        XCTAssertTrue(ZmxLocator.isSupportedVersion("zmx 0.5.0 (build 123)"))
        XCTAssertFalse(ZmxLocator.isSupportedVersion("zmx 0.4.1 (build 99)"))
    }

    func testInvalidStringReturnsFalse() {
        XCTAssertFalse(ZmxLocator.isSupportedVersion("not-a-version"))
        XCTAssertFalse(ZmxLocator.isSupportedVersion(""))
        XCTAssertFalse(ZmxLocator.isSupportedVersion("1.2"))
    }
}
