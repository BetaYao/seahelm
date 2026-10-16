import CryptoKit
import XCTest
@testable import seahelm

/// Fixture signed by an independent implementation (Python's `hmac`, following
/// core.telegram.org/bots/webapps) with the token below — so this checks the
/// Swift side against the documented algorithm, not against itself.
enum TelegramInitDataFixture {
    static let botToken = "123456:TEST-TOKEN"
    static let authDate = Date(timeIntervalSince1970: 1_800_000_000)
    static let valid = "auth_date=1800000000&query_id=AAE&user=%7B%22id%22%3A8817232020%2C%22first_name%22%3A%22matt%22%2C%22username%22%3A%22matt_c%22%7D&signature=c2lnbmF0dXJl&hash=f91571ce9ca607c55cac230efa945d64411d5e92ef720af16087cbc326f9afbd"
}

final class TelegramInitDataTests: XCTestCase {
    private let fx = TelegramInitDataFixture.self

    func testAValidLaunchNamesItsUser() {
        let result = TelegramInitData.validate(fx.valid, botToken: fx.botToken,
                                               now: fx.authDate.addingTimeInterval(60))
        XCTAssertEqual(result, .success(.init(id: 8817232020, username: "matt_c")))
    }

    /// `signature` is part of what the hash covers; leaving it out (as the
    /// Ed25519 check does) would make every real launch fail.
    func testTheSignatureFieldIsCovered() {
        let stripped = fx.valid.replacingOccurrences(of: "&signature=c2lnbmF0dXJl", with: "")
        XCTAssertEqual(TelegramInitData.validate(stripped, botToken: fx.botToken, now: fx.authDate),
                       .failure(.badSignature))
    }

    func testAnotherBotsTokenIsRefused() {
        XCTAssertEqual(TelegramInitData.validate(fx.valid, botToken: "999:OTHER", now: fx.authDate),
                       .failure(.badSignature))
    }

    func testATamperedUserIsRefused() {
        let forged = fx.valid.replacingOccurrences(of: "8817232020", with: "1234567890")
        XCTAssertEqual(TelegramInitData.validate(forged, botToken: fx.botToken, now: fx.authDate),
                       .failure(.badSignature))
    }

    func testAnOldLaunchIsRefused() {
        XCTAssertEqual(TelegramInitData.validate(fx.valid, botToken: fx.botToken,
                                                 now: fx.authDate.addingTimeInterval(86_401)),
                       .failure(.expired))
    }

    func testNonsenseIsMalformed() {
        XCTAssertEqual(TelegramInitData.validate("", botToken: fx.botToken), .failure(.malformed))
        XCTAssertEqual(TelegramInitData.validate("user=1", botToken: fx.botToken), .failure(.malformed))
        XCTAssertEqual(TelegramInitData.validate("a=1&a=2&hash=00", botToken: fx.botToken), .failure(.malformed))
    }

    // MARK: - Gateway access policy

    private func access(host: String?, allowed: [String] = ["8817232020"]) -> HostGatewayAccess {
        HostGatewayAccess(telegramHost: "tg.seahelm.dev", frontHost: { host },
                          telegram: { TelegramConfig(botToken: TelegramInitDataFixture.botToken, allowedUsers: allowed) })
    }

    func testOnlyTheTelegramHostIsTelegramOnly() {
        XCTAssertTrue(access(host: "tg.seahelm.dev").isTelegramOnly)
        XCTAssertFalse(access(host: "gw.seahelm.dev").isTelegramOnly)
        XCTAssertFalse(access(host: nil).isTelegramOnly, "LAN and localhost carry no tunnel host")
        XCTAssertFalse(HostGatewayAccess(frontHost: { "tg.seahelm.dev" }).isTelegramOnly,
                       "no telegram_host configured, nothing changes")
    }

    func testASignedLaunchMustAlsoBeOnTheAllowlist() {
        XCTAssertNotNil(access(host: "tg.seahelm.dev").telegramUser(initData: fx.valid, now: fx.authDate))
        XCTAssertNotNil(access(host: "tg.seahelm.dev", allowed: ["@matt_c"])
            .telegramUser(initData: fx.valid, now: fx.authDate))
        XCTAssertNil(access(host: "tg.seahelm.dev", allowed: ["42"]).telegramUser(initData: fx.valid, now: fx.authDate))
    }

    func testTheMiniAppURLNamesTheHostWhenNoneIsSet() {
        let access = HostGatewayAccess(frontHost: { "tg.example.com" }, telegram: {
            TelegramConfig(botToken: "t", miniAppURL: "https://TG.example.com/app")
        })
        XCTAssertEqual(access.miniAppHost, "tg.example.com")
        XCTAssertTrue(access.isTelegramOnly)
        let explicit = HostGatewayAccess(telegramHost: "other.example.com", frontHost: { "tg.example.com" },
                                         telegram: { TelegramConfig(miniAppURL: "https://tg.example.com/") })
        XCTAssertFalse(explicit.isTelegramOnly, "an explicit telegram_host wins")
    }

    func testMiniAppURLMustBeHTTPSWithAHost() {
        XCTAssertEqual(TelegramConfig.miniAppURL(from: " https://tg.example.com/ ")?.host, "tg.example.com")
        XCTAssertNil(TelegramConfig.miniAppURL(from: "http://tg.example.com/"))
        XCTAssertNil(TelegramConfig.miniAppURL(from: "tg.example.com"))
        XCTAssertNil(TelegramConfig.miniAppURL(from: ""))
        XCTAssertNil(TelegramConfig.miniAppURL(from: nil))
    }

    func testMiniAppURLRoundTripsThroughConfig() throws {
        let data = try JSONEncoder().encode(TelegramConfig(botToken: "t", miniAppURL: "https://tg.example.com/"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"mini_app_url\""))
        XCTAssertEqual(try JSONDecoder().decode(TelegramConfig.self, from: data).miniAppURL, "https://tg.example.com/")
    }

    /// The tunnel's word for the client is taken only from the tunnel itself
    /// (loopback); from anywhere else the header is anyone's to forge.
    func testRealClientAddressIsTrustedOnlyFromLoopback() {
        let head = "GET /ws HTTP/1.1\r\nHost: tg.example.com\r\nCF-Connecting-IP: 203.0.113.9\r\n\r\n"
        let viaTunnel = HostGatewayServer.frontRequest(head: head, peer: .hostPort(host: "127.0.0.1", port: 50_000))
        XCTAssertEqual(viaTunnel, .init(host: "tg.example.com", clientIP: "203.0.113.9"))
        let direct = HostGatewayServer.frontRequest(head: head, peer: .hostPort(host: "192.168.1.20", port: 50_000))
        XCTAssertEqual(direct.clientIP, "192.168.1.20")
    }

    func testHostHeaderParsing() {
        XCTAssertEqual(HostGatewayServer.hostHeader(head: "GET /ws HTTP/1.1\r\nHost: TG.seahelm.dev\r\n\r\n"),
                       "tg.seahelm.dev")
        XCTAssertEqual(HostGatewayServer.hostHeader(head: "GET /ws HTTP/1.1\r\nhost: 127.0.0.1:2783\r\n\r\n"),
                       "127.0.0.1")
        XCTAssertNil(HostGatewayServer.hostHeader(head: "GET /ws HTTP/1.1\r\n\r\n"))
    }

    /// Signs launch data the documented way — for tests that need it fresh.
    static func sign(user: String, authDate: Int, botToken: String) -> String {
        let fields = ["auth_date": String(authDate), "user": user]
        let dataCheckString = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let secret = HMAC<SHA256>.authenticationCode(for: Data(botToken.utf8),
                                                     using: SymmetricKey(data: Data("WebAppData".utf8)))
        let hash = HMAC<SHA256>.authenticationCode(for: Data(dataCheckString.utf8),
                                                   using: SymmetricKey(data: Data(secret)))
            .map { String(format: "%02x", $0) }.joined()
        let encode = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v }
        return "auth_date=\(authDate)&user=\(encode(user))&hash=\(hash)"
    }
}
