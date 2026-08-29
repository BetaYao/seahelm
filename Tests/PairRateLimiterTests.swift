import XCTest
@testable import seahelm

final class PairRateLimiterTests: XCTestCase {
    func testAllowsUnderCap() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<4 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertTrue(lim.allow(ip: "1.1.1.1", now: t0))
    }

    func testBlocksAfterCap() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<5 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertFalse(lim.allow(ip: "1.1.1.1", now: t0))
        XCTAssertTrue(lim.allow(ip: "2.2.2.2", now: t0)) // other IP free
    }

    func testWindowExpiryUnlocks() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<5 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertFalse(lim.allow(ip: "1.1.1.1", now: t0))
        XCTAssertTrue(lim.allow(ip: "1.1.1.1", now: t0.addingTimeInterval(61)))
    }

    func testSuccessClearsFailures() {
        let lim = PairRateLimiter(maxFailures: 5, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<4 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        lim.recordSuccess(ip: "1.1.1.1")
        for _ in 0..<4 { lim.recordFailure(ip: "1.1.1.1", now: t0) }
        XCTAssertTrue(lim.allow(ip: "1.1.1.1", now: t0))
    }
}
