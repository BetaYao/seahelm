import XCTest

extension XCUIElement {
    /// Wait for element to exist, then click it.
    func waitAndClick(timeout: TimeInterval = 5) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(identifier) not found within \(timeout)s")
        click()
    }

    /// Wait until element no longer exists.
    func waitForNonExistence(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
