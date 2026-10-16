import CryptoKit
import Foundation

/// The signed launch data Telegram hands a Mini App (`Telegram.WebApp.initData`,
/// also in the page URL's fragment as `tgWebAppData`), checked the way
/// https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
/// prescribes.
///
/// Only Telegram and whoever holds the bot token can produce a valid `hash`, so
/// a launch that checks out *is* that Telegram user opening this bot's app —
/// which is what lets the Host Gateway let them in without a pairing code.
enum TelegramInitData {
    struct User: Equatable {
        let id: Int64
        let username: String?
    }

    enum Failure: Error, Equatable {
        case malformed
        case badSignature
        case expired
        case noUser
    }

    /// The user this launch data speaks for, or why it does not.
    ///
    /// `maxAge` bounds how long a captured launch stays usable: `auth_date` is
    /// stamped when the Mini App opened, and a reconnect after that rides the
    /// token the first sign-in returned, so the window only has to cover the
    /// first connect.
    static func validate(_ raw: String, botToken: String, now: Date = Date(),
                         maxAge: TimeInterval = 86_400) -> Result<User, Failure> {
        guard let fields = parse(raw), let hash = fields["hash"], !hash.isEmpty else {
            return .failure(.malformed)
        }
        // Every field but `hash` — `signature` included: only the Ed25519
        // third-party check leaves it out.
        let dataCheckString = fields.filter { $0.key != "hash" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        let secret = HMAC<SHA256>.authenticationCode(
            for: Data(botToken.utf8), using: SymmetricKey(data: Data("WebAppData".utf8)))
        let expected = HMAC<SHA256>.authenticationCode(
            for: Data(dataCheckString.utf8), using: SymmetricKey(data: Data(secret)))
        guard constantTimeEqual(hex(Data(expected)), hash.lowercased()) else {
            return .failure(.badSignature)
        }

        guard let authDate = fields["auth_date"].flatMap(TimeInterval.init) else {
            return .failure(.malformed)
        }
        let age = now.timeIntervalSince1970 - authDate
        // A little slack the other way for a clock that runs behind Telegram's.
        guard age <= maxAge, age >= -300 else { return .failure(.expired) }

        guard let userJSON = fields["user"]?.data(using: .utf8),
              let user = try? JSONSerialization.jsonObject(with: userJSON) as? [String: Any],
              let id = (user["id"] as? NSNumber)?.int64Value else {
            return .failure(.noUser)
        }
        return .success(User(id: id, username: user["username"] as? String))
    }

    /// `key=value&…` with percent-decoded values. A repeated key is malformed:
    /// there is no telling which one the hash covered.
    static func parse(_ raw: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            let key = String(pair[..<eq])
            guard let value = String(pair[pair.index(after: eq)...]).removingPercentEncoding,
                  !key.isEmpty, fields[key] == nil else { return nil }
            fields[key] = value
        }
        return fields.isEmpty ? nil : fields
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
