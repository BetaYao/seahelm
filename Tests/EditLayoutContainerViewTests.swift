import XCTest
@testable import seahelm

final class EditLayoutContainerViewTests: XCTestCase {
    /// Zoom / full screen resizes the container through Auto Layout, which
    /// does not always run `layout()`. The columns must follow the new size on
    /// the frame change itself, not stay at the old one in the corner.
    func testColumnsFollowAFrameChangeWithoutALayoutPass() {
        let edit = EditLayoutContainerView(ratio: 0.5)
        edit.translatesAutoresizingMaskIntoConstraints = true
        edit.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        edit.layoutSubtreeIfNeeded()
        XCTAssertEqual(edit.columnFramesForTesting.left.height, 600)

        edit.setFrameSize(NSSize(width: 2000, height: 1200))

        let (left, right) = edit.columnFramesForTesting
        XCTAssertEqual(left.height, 1200)
        XCTAssertEqual(right.height, 1200)
        XCTAssertEqual(right.maxX, 2000, accuracy: 0.5)
        XCTAssertEqual(left.width, floor((2000 - DividerView.thickness) * 0.5))
    }
}
