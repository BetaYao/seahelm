import Foundation
import Security

/// The result of a successful pairing: who tapped Start, and where.
struct TelegramPairingResult: Equatable {
    /// Telegram user id as a string — what `allowed_users` stores.
    let userId: String
    /// `@username`, or a first name, or the id: what to show in Settings.
    let displayName: String
    /// The chat the `/start` arrived in. In a private chat this equals the
    /// user id, but reading it off the message rather than assuming means a
    /// pairing done from a group still names a chat notifications can reach.
    let chatId: String
}

/// A one-time code that turns "whoever taps Start" into the bot's owner.
///
/// The allowlist is the only thing between a stranger and the fleet, and it
/// used to be typed by hand: find @userinfobot, ask it for your numeric id,
/// copy the digits across, and separately work out what a chat id is. Pairing
/// replaces all of that with a code the user carries *to* the bot — whoever
/// sends it back is, by construction, the person holding this Mac, and the
/// message they send carries both ids for free.
///
/// The code rides in a `t.me/<bot>?start=<code>` deep link, so its alphabet is
/// what Telegram accepts in a start payload (`A-Z a-z 0-9 _ -`) and its length
/// stays far inside the 64-character limit. Ambiguous glyphs are left out so
/// the same code can be read off the screen and typed by hand — the fallback
/// when the QR is on the wrong side of the room.
enum TelegramPairingCode {
    /// Crockford-ish: no `0`/`O`, no `1`/`I`/`L`. 31 symbols left, which is not
    /// a power of two, so the draw below rejects rather than folds — a plain
    /// `% 31` would make the first eight letters a ninth more likely than the
    /// rest, and there is no reason to hand that away.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let length = 8

    static func generate() -> String {
        // The largest multiple of the alphabet that fits in a byte; anything
        // at or above it is discarded so every symbol is equally likely.
        let ceiling = UInt8(256 - (256 % alphabet.count))
        var picked = ""
        picked.reserveCapacity(length)
        while picked.count < length {
            var bytes = [UInt8](repeating: 0, count: length)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess)
            for byte in bytes where byte < ceiling && picked.count < length {
                picked.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return picked
    }

    /// Uppercased, with the separators people insert when copying by eye
    /// (spaces, dashes) dropped. Anything outside the alphabet is dropped too,
    /// so a code pasted with stray punctuation still matches.
    static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { alphabet.contains($0) })
    }

    static func isValidFormat(_ raw: String) -> Bool {
        normalize(raw).count == length
    }

    /// Constant-time compare, so a code cannot be recovered a character at a
    /// time by timing the replies. Cheap here and the habit is worth keeping.
    static func matches(_ expected: String, _ candidate: String) -> Bool {
        let a = Array(normalize(expected).utf8)
        let b = Array(normalize(candidate).utf8)
        guard a.count == length, b.count == length else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// The payload of a `/start` command, or nil when the text is not one.
    ///
    /// Telegram delivers a deep link's payload as an ordinary argument —
    /// tapping `t.me/foo_bot?start=ABC` sends the literal text `/start ABC` —
    /// so there is nothing to unwrap. The bot-mention suffix (`/start@foo_bot`,
    /// how a group disambiguates between bots) is stripped by the caller
    /// before this sees it. Returns an empty string for a bare `/start`, which
    /// is a real case: it is what the Start button sends with no deep link.
    static func startPayload(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/start" || trimmed.hasPrefix("/start ") else { return nil }
        return String(trimmed.dropFirst("/start".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The deep link to put behind a QR code. `username` is the bot's, without
    /// the leading `@`.
    static func deepLink(botUsername: String, code: String) -> String {
        "https://t.me/\(botUsername)?start=\(normalize(code))"
    }
}

/// The armed half: one live code, with an expiry, good for exactly one pairing.
///
/// Armed only while the setup wizard is on screen waiting. A code that lived
/// forever would be a second, quieter allowlist — anyone who found the bot and
/// guessed eight characters would be in — so it dies on use and on a timer.
final class TelegramPairingSession {
    /// Long enough to walk to a phone and unlock it, short enough that leaving
    /// Settings open over lunch does not leave the door open with it.
    static let defaultTTL: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var currentCode: String
    private var expiry: Date
    private var consumed = false
    private let ttl: TimeInterval

    init(ttl: TimeInterval = TelegramPairingSession.defaultTTL,
         code: String = TelegramPairingCode.generate(),
         now: Date = Date()) {
        self.ttl = ttl
        self.currentCode = code
        self.expiry = now.addingTimeInterval(ttl)
    }

    var code: String {
        lock.lock(); defer { lock.unlock() }
        return currentCode
    }

    var expiresAt: Date {
        lock.lock(); defer { lock.unlock() }
        return expiry
    }

    func isExpired(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return consumed || now >= expiry
    }

    /// New code, new clock. The old one stops working immediately.
    @discardableResult
    func refresh(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        currentCode = TelegramPairingCode.generate()
        expiry = now.addingTimeInterval(ttl)
        consumed = false
        return currentCode
    }

    /// Verify and spend in one step. A second caller with the same code —
    /// someone forwarding the link, a retry — gets false, so pairing cannot be
    /// replayed into a second allowlist entry.
    func claim(_ candidate: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !consumed, now < expiry else { return false }
        guard TelegramPairingCode.matches(currentCode, candidate) else { return false }
        consumed = true
        return true
    }
}
