import XCTest
@testable import seahelm

/// What a pane is sent for a drop. File promises need a real source app and are
/// checked by hand.
final class TerminalDropTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("seahelm.test.drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-drop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// Resolve the test pasteboard, writing any image into the test directory.
    private func resolve() -> String? {
        var result: String?
        let resolved = expectation(description: "resolved")
        TerminalDrop.resolveText(from: pasteboard, dropDirectory: { [directory] in directory }) { text in
            result = text
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 2)
        return result
    }

    /// A 2×2 bitmap as TIFF bytes — image data with no file behind it.
    private static func tinyTIFF() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.setColor(.red, atX: 0, y: 0)
        return try XCTUnwrap(rep.tiffRepresentation)
    }

    func testFileURLsBecomeEscapedPathsJoinedWithTrailingSpace() throws {
        let image = directory.appendingPathComponent("a b.png")
        let pdf = directory.appendingPathComponent("c.pdf")
        try Data().write(to: image)
        try Data().write(to: pdf)
        pasteboard.writeObjects([image as NSURL, pdf as NSURL])

        let text = try XCTUnwrap(resolve())
        XCTAssertEqual(text, "\(ShellEscape.backslash(image.path)) \(ShellEscape.backslash(pdf.path)) ")
        XCTAssertTrue(text.contains("a\\ b.png "))
    }

    func testTextIsInsertedVerbatim() {
        pasteboard.setString("echo 'hi' $HOME", forType: .string)
        XCTAssertEqual(resolve(), "echo 'hi' $HOME")
    }

    func testImageDataWithoutAFileIsWrittenAsPNG() throws {
        pasteboard.setData(try Self.tinyTIFF(), forType: .tiff)

        let png = directory.appendingPathComponent("dropped-image.png")
        XCTAssertEqual(resolve(), ShellEscape.backslash(png.path) + " ")
        let bytes = try Data(contentsOf: png)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "image must be written as PNG, not TIFF")
    }

    func testBrowserImageDragPrefersTheImageOverItsAddress() throws {
        pasteboard.setData(try Self.tinyTIFF(), forType: .tiff)
        pasteboard.setString("https://example.com/cat.jpg", forType: .string)

        let png = directory.appendingPathComponent("dropped-image.png")
        XCTAssertEqual(resolve(), ShellEscape.backslash(png.path) + " ")
    }

    func testTextSelectionWithAnImageFlavourKeepsItsText() throws {
        pasteboard.setData(try Self.tinyTIFF(), forType: .tiff)
        pasteboard.setString("hello world", forType: .string)

        XCTAssertEqual(resolve(), "hello world")
    }

    func testEmptyPasteboardIsRefused() {
        XCTAssertFalse(TerminalDrop.canAccept(pasteboard))
    }

    func testFilePasteboardIsAccepted() {
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/x.png") as NSURL])
        XCTAssertTrue(TerminalDrop.canAccept(pasteboard))
    }
}
