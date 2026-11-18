import XCTest
@testable import seahelm

final class IslandWarningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testAnsweringCoreSaysNothing() {
        XCTAssertNil(IslandWarning.current(coreUnreachableSince: nil, controlChannel: .listening, now: now))
    }

    /// The launch, or a restart: a few seconds of silence are not news.
    func testBriefSilenceIsWithinGrace() {
        let since = now.addingTimeInterval(-(IslandWarning.coreGrace - 1))
        XCTAssertNil(IslandWarning.core(unreachableSince: since, now: now))
    }

    func testSilentCoreIsSaid() {
        let w = IslandWarning.core(unreachableSince: now.addingTimeInterval(-30), now: now)
        XCTAssertEqual(w?.badge, "CORE")
    }

    func testCoreOutranksTheControlChannel() {
        let w = IslandWarning.current(coreUnreachableSince: now.addingTimeInterval(-30), controlChannel: .standby, now: now)
        XCTAssertEqual(w?.badge, "CORE")
        XCTAssertEqual(IslandWarning.current(coreUnreachableSince: nil, controlChannel: .standby, now: now)?.badge, "CTRL")
        XCTAssertNil(IslandWarning.current(coreUnreachableSince: nil, controlChannel: nil, now: now))
    }

    func testSilentGatewayIsSaidAfterItsGrace() {
        XCTAssertNil(IslandWarning.gateway(unreachableSince: nil, now: now))
        XCTAssertNil(IslandWarning.gateway(unreachableSince: now.addingTimeInterval(-(IslandWarning.gatewayGrace - 1)), now: now))
        XCTAssertEqual(IslandWarning.gateway(unreachableSince: now.addingTimeInterval(-30), now: now)?.badge, "GW")
    }

    func testGatewaySitsBetweenCoreAndControlChannel() {
        let long = now.addingTimeInterval(-30)
        XCTAssertEqual(IslandWarning.current(coreUnreachableSince: long, gatewayUnreachableSince: long, controlChannel: .standby, now: now)?.badge, "CORE")
        XCTAssertEqual(IslandWarning.current(coreUnreachableSince: nil, gatewayUnreachableSince: long, controlChannel: .standby, now: now)?.badge, "GW")
    }

    func testGatewayEnsureUsesItsOwnInterval() {
        let since = now.addingTimeInterval(-10)
        XCTAssertFalse(CoreLink.shouldEnsure(unreachableSince: since, lastEnsure: now.addingTimeInterval(-5), now: now, interval: 15))
        XCTAssertTrue(CoreLink.shouldEnsure(unreachableSince: since, lastEnsure: now.addingTimeInterval(-15), now: now, interval: 15))
    }

    func testEnsureIsRetriedButNotHammered() {
        let since = now.addingTimeInterval(-10)
        XCTAssertFalse(CoreLink.shouldEnsure(unreachableSince: nil, lastEnsure: nil, now: now))
        XCTAssertFalse(CoreLink.shouldEnsure(unreachableSince: now.addingTimeInterval(-2), lastEnsure: nil, now: now))
        XCTAssertTrue(CoreLink.shouldEnsure(unreachableSince: since, lastEnsure: nil, now: now))
        XCTAssertFalse(CoreLink.shouldEnsure(unreachableSince: since, lastEnsure: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(CoreLink.shouldEnsure(unreachableSince: since, lastEnsure: now.addingTimeInterval(-CoreLink.ensureInterval), now: now))
    }
}
