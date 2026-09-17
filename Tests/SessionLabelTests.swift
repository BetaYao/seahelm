import XCTest
@testable import seahelm

final class SessionLabelTests: XCTestCase {

    /// AppKit has no `resolvedColor(for:)`: a dynamic NSColor answers for
    /// whichever appearance is current while it is read.
    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor? {
        var out: NSColor?
        appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) }
        return out
    }

    /// `WorktreeLabelStore` persists the raw value, so these ids are a storage
    /// format: renaming one drops the label off every row already wearing it.
    func testStoredIdsAreStable() {
        XCTAssertEqual(
            SessionLabel.allCases.map(\.rawValue),
            ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"]
        )
    }

    func testUnknownStoredIdIsIgnored() {
        XCTAssertNil(SessionLabel(rawValue: "chartreuse"))
        XCTAssertNil(SessionLabel(rawValue: ""))
        XCTAssertEqual(SessionLabel(rawValue: "teal"), .teal)
    }

    func testEveryLabelHasADistinctTitleAndAResolvableColor() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        var titles: Set<String> = []
        for label in SessionLabel.allCases {
            XCTAssertFalse(label.title.isEmpty, "\(label.rawValue) needs a menu title")
            titles.insert(label.title)
            XCTAssertNotNil(resolved(label.color, in: dark), "\(label.rawValue) must resolve in dark")
            XCTAssertNotNil(resolved(label.color, in: light), "\(label.rawValue) must resolve in light")
        }
        XCTAssertEqual(titles.count, SessionLabel.allCases.count, "titles must be distinct")
    }

    /// Dark and light carry different weights of the same hue — the dark-theme
    /// colour washes out on a white list background.
    func testDarkAndLightVariantsDiffer() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        for label in SessionLabel.allCases {
            let inDark = try XCTUnwrap(resolved(label.color, in: dark))
            let inLight = try XCTUnwrap(resolved(label.color, in: light))
            XCTAssertNotEqual(inDark, inLight, "\(label.rawValue) should not use one colour for both themes")
        }
    }

    /// The island is near-black in light mode too, so it takes the dark
    /// variant whichever appearance is current.
    func testDarkSurfaceColorIgnoresAppearance() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        for label in SessionLabel.allCases {
            let themed = try XCTUnwrap(resolved(label.color, in: dark))
            XCTAssertEqual(resolved(label.darkSurfaceColor, in: light), themed, label.rawValue)
            XCTAssertEqual(resolved(label.darkSurfaceColor, in: dark), themed, label.rawValue)
        }
    }

    /// Every hue is its own: two rows wearing different labels must not look
    /// identical at a glance.
    func testLabelsAreVisuallyDistinctInDarkTheme() throws {
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var seen: [NSColor] = []
        for label in SessionLabel.allCases {
            let color = try XCTUnwrap(resolved(label.color, in: dark))
            XCTAssertFalse(seen.contains(color), "\(label.rawValue) repeats another label's colour")
            seen.append(color)
        }
    }
}
