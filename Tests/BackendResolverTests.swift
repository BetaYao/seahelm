import XCTest
@testable import seahelm

final class BackendResolverTests: XCTestCase {

    // MARK: - resolvePreferredBackend

    func testZmxPreferredAndAvailable() {
        XCTAssertEqual(BackendResolver.resolvePreferredBackend(preferred: "zmx", zmxAvailable: true), "zmx")
    }

    func testZmxPreferredButUnavailableFallsToLocal() {
        XCTAssertEqual(BackendResolver.resolvePreferredBackend(preferred: "zmx", zmxAvailable: false), "local")
    }

    func testLocalPreferredZmxAvailableUpgradesToZmx() {
        XCTAssertEqual(BackendResolver.resolvePreferredBackend(preferred: "local", zmxAvailable: true), "zmx")
    }

    func testLocalPreferredZmxUnavailableStaysLocal() {
        XCTAssertEqual(BackendResolver.resolvePreferredBackend(preferred: "local", zmxAvailable: false), "local")
    }

    func testUnknownPreferredZmxAvailableDefaultsToZmx() {
        XCTAssertEqual(BackendResolver.resolvePreferredBackend(preferred: "unknown", zmxAvailable: true), "zmx")
    }

    func testUnknownPreferredZmxUnavailableDefaultsToLocal() {
        XCTAssertEqual(BackendResolver.resolvePreferredBackend(preferred: "unknown", zmxAvailable: false), "local")
    }

    // MARK: - isSupportedZmxVersion

    func test042IsSupported() {
        XCTAssertTrue(BackendResolver.isSupportedZmxVersion("0.4.2"))
    }

    func test050IsSupported() {
        XCTAssertTrue(BackendResolver.isSupportedZmxVersion("0.5.0"))
    }

    func test100IsSupported() {
        XCTAssertTrue(BackendResolver.isSupportedZmxVersion("1.0.0"))
    }

    func test041IsUnsupported() {
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("0.4.1"))
    }

    func test030IsUnsupported() {
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("0.3.0"))
    }

    func testWhitespaceTrimming() {
        XCTAssertTrue(BackendResolver.isSupportedZmxVersion("  0.4.2  "))
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("  0.4.1  "))
    }

    func testVersionWithVPrefix() {
        XCTAssertTrue(BackendResolver.isSupportedZmxVersion("v0.4.2"))
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("v0.4.1"))
    }

    func testVersionEmbeddedInOutput() {
        XCTAssertTrue(BackendResolver.isSupportedZmxVersion("zmx 0.5.0 (build 123)"))
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("zmx 0.4.1 (build 99)"))
    }

    func testInvalidStringReturnsFalse() {
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("not-a-version"))
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion(""))
        XCTAssertFalse(BackendResolver.isSupportedZmxVersion("1.2"))
    }
}
