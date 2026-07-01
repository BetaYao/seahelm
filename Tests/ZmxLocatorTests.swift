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
}
