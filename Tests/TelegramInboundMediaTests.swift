import XCTest
@testable import seahelm

final class TelegramInboundMediaTests: XCTestCase {

    func testPreferredPhotoPicksLargestByFileSize() {
        let sizes = [
            TelegramPhotoSize(fileId: "small", width: 90, height: 90, fileSize: 1_000),
            TelegramPhotoSize(fileId: "large", width: 800, height: 600, fileSize: 80_000),
            TelegramPhotoSize(fileId: "medium", width: 320, height: 240, fileSize: 20_000),
        ]
        XCTAssertEqual(TelegramInboundMedia.preferredPhoto(sizes)?.fileId, "large")
    }

    func testPreferredPhotoFallsBackToAreaWhenSizeMissing() {
        let sizes = [
            TelegramPhotoSize(fileId: "tiny", width: 10, height: 10, fileSize: nil),
            TelegramPhotoSize(fileId: "big", width: 100, height: 100, fileSize: nil),
        ]
        XCTAssertEqual(TelegramInboundMedia.preferredPhoto(sizes)?.fileId, "big")
    }

    func testComposeOrderTextJoinsCaptionAndPaths() {
        let url = URL(fileURLWithPath: "/tmp/shot.png")
        XCTAssertEqual(
            TelegramInboundMedia.composeOrderText(paths: [url], caption: "  fix this  "),
            "fix this\n\(ShellEscape.backslash(url.path))")
        XCTAssertEqual(
            TelegramInboundMedia.composeOrderText(paths: [url], caption: nil),
            ShellEscape.backslash(url.path))
        XCTAssertEqual(
            TelegramInboundMedia.composeOrderText(paths: [], caption: "hello"),
            "hello")
        XCTAssertEqual(
            TelegramInboundMedia.composeOrderText(paths: [], caption: "  "),
            "")
    }

    func testImageDocumentDetection() {
        XCTAssertTrue(TelegramInboundMedia.isImageDocument(
            TelegramDocument(fileId: "1", fileName: "a.PNG", mimeType: nil, fileSize: 10)))
        XCTAssertTrue(TelegramInboundMedia.isImageDocument(
            TelegramDocument(fileId: "1", fileName: "x.bin", mimeType: "image/jpeg", fileSize: 10)))
        XCTAssertFalse(TelegramInboundMedia.isImageDocument(
            TelegramDocument(fileId: "1", fileName: "notes.pdf", mimeType: "application/pdf", fileSize: 10)))
    }

    func testMediaStoreWritesUnderMessageDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-tg-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramMediaStore(root: root)
        let data = Data("png-bytes".utf8)
        let url = try store.save(data: data, fileName: "photo.jpg", messageId: 42)
        XCTAssertTrue(url.path.contains("/42/"))
        XCTAssertEqual(url.lastPathComponent, "photo.jpg")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testMediaStoreRejectsOversizedPayload() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-tg-media-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TelegramMediaStore(root: root)
        let huge = Data(count: TelegramInboundMedia.maxBytes + 1)
        XCTAssertThrowsError(try store.save(data: huge, fileName: "big.jpg", messageId: 1))
    }

    func testPhotoMessageDecodesFromBotAPIJSON() throws {
        let json = """
        {"update_id":1,"message":{"message_id":9,"from":{"id":42,"is_bot":false,"first_name":"Matt"},
         "chat":{"id":42,"type":"private"},"date":1757000000,
         "photo":[
           {"file_id":"s","file_unique_id":"u1","width":90,"height":90,"file_size":100},
           {"file_id":"L","file_unique_id":"u2","width":800,"height":600,"file_size":9000}
         ],
         "caption":"look here"}}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let update = try decoder.decode(TelegramUpdate.self, from: json)
        let message = try XCTUnwrap(update.payload)
        XCTAssertEqual(message.caption, "look here")
        XCTAssertEqual(message.photo?.count, 2)
        XCTAssertEqual(TelegramInboundMedia.preferredPhoto(message.photo ?? [])?.fileId, "L")
        XCTAssertEqual(message.body, "look here")
    }

    func testPrivatePhotoOnlyPathIsAnOrder() {
        let chat = TelegramChat(id: 42, type: "private", title: nil, username: nil)
        let from = TelegramUser(id: 42, isBot: false, firstName: "Matt", username: "matt_c")
        let message = TelegramMessage(
            messageId: 1, date: 1, chat: chat, from: from, senderChat: nil,
            text: nil, caption: nil,
            photo: [TelegramPhotoSize(fileId: "L", width: 100, height: 100, fileSize: 10)])
        let path = "/tmp/shot.png"
        let body = TelegramInboundMedia.composeOrderText(
            paths: [URL(fileURLWithPath: path)], caption: nil)
        let cmd = TelegramChannel.command(
            in: message, body: body,
            config: TelegramConfig(allowedUsers: ["42"]),
            botUsername: nil)
        XCTAssertEqual(cmd?.body, ShellEscape.backslash(path))
    }

    func testGroupBarePhotoPathIsNotAnOrder() {
        let chat = TelegramChat(id: -100, type: "supergroup", title: "Team", username: nil)
        let from = TelegramUser(id: 42, isBot: false, firstName: "Matt", username: "matt_c")
        let message = TelegramMessage(
            messageId: 1, date: 1, chat: chat, from: from, senderChat: nil,
            text: nil, caption: nil,
            photo: [TelegramPhotoSize(fileId: "L", width: 100, height: 100, fileSize: 10)])
        let body = TelegramInboundMedia.composeOrderText(
            paths: [URL(fileURLWithPath: "/tmp/shot.png")], caption: nil)
        XCTAssertNil(TelegramChannel.command(
            in: message, body: body,
            config: TelegramConfig(allowedUsers: ["42"]),
            botUsername: "seahelm_bot"))
    }

    func testPathLookingBodyIsNotASlashCommand() {
        XCTAssertFalse(TelegramChannel.isSlashCommand("/tmp/shot.png"))
        XCTAssertFalse(TelegramChannel.isSlashCommand("/Users/me/img.jpg"))
        XCTAssertTrue(TelegramChannel.isSlashCommand("/status"))
        XCTAssertTrue(TelegramChannel.isSlashCommand("/go #3"))
        XCTAssertTrue(TelegramChannel.isSlashCommand("/status@seahelm_bot"))
    }

    func testPeelCachedMediaSeparatesCaptionFromImagePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-tg-peel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("shot.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: image) // minimal jpeg magic

        let composed = TelegramInboundMedia.composeOrderText(
            paths: [image], caption: "what is this?")
        let peeled = TelegramInboundMedia.peelCachedMedia(
            from: composed, root: root)
        XCTAssertEqual(peeled.urls.map(\.path), [image.standardizedFileURL.path])
        XCTAssertEqual(peeled.prose, "what is this?")

        let pathOnly = TelegramInboundMedia.peelCachedMedia(
            from: image.path, root: root)
        XCTAssertEqual(pathOnly.urls.map(\.path), [image.standardizedFileURL.path])
        XCTAssertEqual(pathOnly.prose, "")
    }
}
