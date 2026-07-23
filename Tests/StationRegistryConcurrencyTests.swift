import XCTest
@testable import seahelm

/// StationRegistry is read from threads that never touch the main thread: hook
/// events resolve `paneId → station` on the event-sink queue
/// (`ShipLog.handleWebhookEvent`), and control-socket requests resolve stations on
/// one detached thread per connection — while the main thread registers and
/// unregisters stations as panes are created, restored and closed.
///
/// Run with `-enableThreadSanitizer YES` to make the race an outright failure;
/// without the lock TSan reports a Swift.Dictionary read/write data race here.
final class StationRegistryConcurrencyTests: XCTestCase {

    override func tearDown() {
        StationRegistry.shared.removeAll()
        super.tearDown()
    }

    func testConcurrentRegisterAndLookupIsRaceFree() {
        StationRegistry.shared.removeAll()
        let stations: [Station] = (0..<40).map { i in
            let s = Station()
            s.paneSessionKey = "seahelm-test-\(i)"
            return s
        }

        let done = expectation(description: "workers")
        done.expectedFulfillmentCount = 3

        // Pane churn (main-thread role): register/unregister.
        DispatchQueue.global().async {
            for _ in 0..<200 {
                for s in stations { StationRegistry.shared.register(s) }
                for s in stations { StationRegistry.shared.unregister(s.id) }
            }
            done.fulfill()
        }
        // Hook role: resolve a pane by its session name.
        DispatchQueue.global().async {
            for _ in 0..<200 {
                for s in stations { _ = StationRegistry.shared.station(forSessionName: s.paneSessionKey ?? "") }
            }
            done.fulfill()
        }
        // Control-socket role: resolve a pane by station id.
        DispatchQueue.global().async {
            for _ in 0..<200 {
                for s in stations { _ = StationRegistry.shared.station(forId: s.id) }
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 60)
    }
}
