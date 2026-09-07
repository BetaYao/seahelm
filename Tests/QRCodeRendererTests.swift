import XCTest
@testable import seahelm

final class QRCodeRendererTests: XCTestCase {
    func testImageHasDarkAndLightModules() {
        let image = QRCodeRenderer.image(
            for: "https://t.me/SeahelmBot?start=ABCDEFGH",
            points: 168,
            foreground: NSColor(white: 0.06, alpha: 1),
            background: NSColor(white: 0.88, alpha: 1))
        XCTAssertNotNil(image)

        guard let tiff = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return XCTFail("expected a bitmap")
        }

        var dark = 0
        var light = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.2 {
                    dark += 1
                } else if color.redComponent > 0.7 {
                    light += 1
                }
            }
        }

        // A solid black square (the old sourceAtop bug) has light == 0.
        XCTAssertGreaterThan(dark, 1000, "expected dark modules")
        XCTAssertGreaterThan(light, 1000, "expected light quiet zone / modules")
    }

    func testEmptyPayloadReturnsNil() {
        XCTAssertNil(QRCodeRenderer.image(for: "", points: 168))
    }
}
