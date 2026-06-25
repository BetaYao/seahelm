import XCTest
@testable import seahelm

final class BackendResolverTests: XCTestCase {

    // MARK: - resolvePreferredBackend

    func testZmxPreferredAndAvailable() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "zmx", zmxAvailable: true, tmuxAvailable: true)
        XCTAssertEqual(result, "zmx")
    }

    func testZmxPreferredButUnavailableFallsToTmux() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "zmx", zmxAvailable: false, tmuxAvailable: true)
        XCTAssertEqual(result, "tmux")
    }

    func testZmxPreferredBothUnavailableFallsToLocal() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "zmx", zmxAvailable: false, tmuxAvailable: false)
        XCTAssertEqual(result, "local")
    }

    func testTmuxPreferredZmxAvailableUpgradesToZmx() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "tmux", zmxAvailable: true, tmuxAvailable: true)
        XCTAssertEqual(result, "zmx")
    }

    func testTmuxPreferredZmxUnavailableTmuxAvailable() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "tmux", zmxAvailable: false, tmuxAvailable: true)
        XCTAssertEqual(result, "tmux")
    }

    func testTmuxPreferredBothUnavailableFallsToLocal() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "tmux", zmxAvailable: false, tmuxAvailable: false)
        XCTAssertEqual(result, "local")
    }

    func testLocalPreferredZmxAvailableUpgradesToZmx() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "local", zmxAvailable: true, tmuxAvailable: true)
        XCTAssertEqual(result, "zmx")
    }

    func testLocalPreferredZmxUnavailableTmuxAvailableUpgradesToTmux() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "local", zmxAvailable: false, tmuxAvailable: true)
        XCTAssertEqual(result, "tmux")
    }

    func testLocalPreferredBothUnavailableStaysLocal() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "local", zmxAvailable: false, tmuxAvailable: false)
        XCTAssertEqual(result, "local")
    }

    func testUnknownPreferredZmxAvailableDefaultsToZmx() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "unknown", zmxAvailable: true, tmuxAvailable: true)
        XCTAssertEqual(result, "zmx")
    }

    func testUnknownPreferredZmxUnavailableTmuxAvailableDefaultsToTmux() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "unknown", zmxAvailable: false, tmuxAvailable: true)
        XCTAssertEqual(result, "tmux")
    }

    func testUnknownPreferredBothUnavailableDefaultsToLocal() {
        let result = BackendResolver.resolvePreferredBackend(preferred: "unknown", zmxAvailable: false, tmuxAvailable: false)
        XCTAssertEqual(result, "local")
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
