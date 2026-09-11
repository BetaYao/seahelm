import XCTest
@testable import seahelm

/// Dropped images attached through an agent's own image paste. The key press
/// itself needs a live surface and is checked by hand.
final class AgentImagePasteTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("seahelm.test.imagepaste.\(UUID().uuidString)"))
        pasteboard.clearContents()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-imagepaste-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private static func bitmap() throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.setColor(.red, atX: 0, y: 0)
        return rep
    }

    /// Let queued main-queue work (the delayed clipboard restore) run.
    private func settle(_ seconds: TimeInterval) {
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { settled.fulfill() }
        wait(for: [settled], timeout: seconds + 2)
    }

    // MARK: - Which drops attach

    func testOnlyClaudeCodeAttachesImages() {
        XCTAssertTrue(AgentImagePaste.supports(.claudeCode))
        XCTAssertFalse(AgentImagePaste.supports(.codex))
        XCTAssertFalse(AgentImagePaste.supports(nil))
    }

    func testImageFilesAreRecognisedByType() {
        for name in ["shot.png", "photo.JPG", "live.heic", "anim.gif", "pic.webp"] {
            XCTAssertTrue(AgentImagePaste.isImage(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["spec.pdf", "page.html", "notes.txt", "Makefile"] {
            XCTAssertFalse(AgentImagePaste.isImage(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }

    // MARK: - PNG bytes

    func testPNGFileIsAttachedAsIs() throws {
        let png = directory.appendingPathComponent("shot.png")
        let bytes = try XCTUnwrap(Self.bitmap().representation(using: .png, properties: [:]))
        try bytes.write(to: png)
        XCTAssertEqual(AgentImagePaste.pngData(for: png), bytes)
    }

    func testJPEGFileIsReencodedAsPNG() throws {
        let jpeg = directory.appendingPathComponent("photo.jpg")
        try XCTUnwrap(Self.bitmap().representation(using: .jpeg, properties: [:])).write(to: jpeg)
        let data = try XCTUnwrap(AgentImagePaste.pngData(for: jpeg))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testUndecodableImageFileIsNotAttached() throws {
        let broken = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        XCTAssertNil(AgentImagePaste.pngData(for: broken))
    }

    // MARK: - Clipboard sequence

    func testPastesEachImageInTurnThenRestoresTheClipboard() {
        pasteboard.setString("user's clipboard", forType: .string)
        let images = [Data([1, 2, 3]), Data([4, 5, 6])]
        var onClipboardAtPress: [Data?] = []
        let finished = expectation(description: "sequence finished")
        AgentImagePaste.paste(
            images: images, pasteboard: pasteboard, interval: 0.01, restoreAfter: 0.05,
            pressPasteKey: { onClipboardAtPress.append(self.pasteboard.data(forType: .png)) },
            completion: { finished.fulfill() }
        )
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(onClipboardAtPress, images)

        settle(0.3)
        XCTAssertEqual(pasteboard.string(forType: .string), "user's clipboard")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testClipboardCopiedDuringTheSequenceIsKept() {
        pasteboard.setString("old", forType: .string)
        let finished = expectation(description: "sequence finished")
        AgentImagePaste.paste(
            images: [Data([1])], pasteboard: pasteboard, interval: 0.01, restoreAfter: 0.1,
            pressPasteKey: {},
            completion: {
                self.pasteboard.clearContents()
                self.pasteboard.setString("copied meanwhile", forType: .string)
                finished.fulfill()
            }
        )
        wait(for: [finished], timeout: 2)

        settle(0.4)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied meanwhile")
    }

    func testNoImagesLeavesTheClipboardAlone() {
        pasteboard.setString("keep", forType: .string)
        let before = pasteboard.changeCount
        var pressed = false
        var done = false
        AgentImagePaste.paste(images: [], pasteboard: pasteboard, pressPasteKey: { pressed = true }, completion: { done = true })
        XCTAssertTrue(done)
        XCTAssertFalse(pressed)
        XCTAssertEqual(pasteboard.changeCount, before)
    }

    func testSnapshotRestoresEveryType() {
        let custom = NSPasteboard.PasteboardType("com.example.seahelm-test")
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(Data([9]), forType: custom)
        pasteboard.writeObjects([item])

        let saved = AgentImagePaste.snapshot(pasteboard)
        pasteboard.clearContents()
        AgentImagePaste.restore(saved, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
        XCTAssertEqual(pasteboard.data(forType: custom), Data([9]))
    }
}
