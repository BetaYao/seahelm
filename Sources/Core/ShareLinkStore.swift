import Foundation
import CryptoKit

/// How long a share link lives. Chosen when the link is copied, changeable
/// after, and gone the moment it passes: the gateway drops any page still open
/// on it.
enum ShareLinkLifetime: String, CaseIterable, Codable {
    case hour, day, week, never

    var seconds: TimeInterval? {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .never: return nil
        }
    }

    var label: String {
        switch self {
        case .hour: return "1 hour"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .never: return "Never"
        }
    }

    private static let defaultsKey = "seahelm.shareLinkLifetime"

    /// The lifetime picked last, so the next link starts there. 24 hours until
    /// anything is picked.
    static var lastChosen: ShareLinkLifetime {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .day }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// One link that opens one pane. The token itself is not kept — only its hash —
/// so the file is a list of what is shared, not a list of keys to it.
struct ShareLink: Codable, Equatable {
    let id: String
    let paneSessionKey: String
    /// What the pane was called when it was shared, for the Settings list.
    var label: String
    let tokenHash: String
    let createdAt: Date
    var expiresAt: Date?

    func isLive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }

    enum CodingKeys: String, CodingKey {
        case id, label
        case paneSessionKey = "pane_session_key"
        case tokenHash = "token_hash"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

/// Why a share token was turned away. The page words its message by it.
enum ShareLinkCheck: Equatable {
    case valid(id: String)
    case expired
    /// Never minted, revoked, or minted for another pane — the page cannot tell
    /// them apart and neither should it.
    case invalid
}

protocol ShareLinkVerifying: AnyObject {
    func check(token: String, paneSessionKey: String, now: Date) -> ShareLinkCheck
    func isLive(id: String, now: Date) -> Bool
}

/// Every share link this Mac has handed out and not yet revoked or outlived.
/// Kept in its own file beside config.json, so a config write cannot drop it
/// and revoking one does not wait on the config's save.
final class ShareLinkStore: ShareLinkVerifying {
    private let fileURL: URL?
    private let lock = NSLock()
    private var links: [ShareLink]
    /// After any mint, revoke or expiry change, on the caller's thread.
    var onChange: (() -> Void)?

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/seahelm/share-links.json")
    }

    /// `fileURL` nil keeps it in memory, for tests.
    init(fileURL: URL? = ShareLinkStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            links = (try? decoder.decode([ShareLink].self, from: data)) ?? []
        } else {
            links = []
        }
    }

    /// A new link for `paneSessionKey`. Returns the token, which exists nowhere
    /// else once the caller has put it in the URL.
    func mint(paneSessionKey: String, label: String, lifetime: ShareLinkLifetime,
              now: Date = Date()) -> (link: ShareLink, token: String) {
        let token = PairingCrypto.base64url(Self.randomBytes(32))
        let link = ShareLink(
            id: PairingCrypto.base64url(Self.randomBytes(9)),
            paneSessionKey: paneSessionKey,
            label: label,
            tokenHash: Self.hash(token),
            createdAt: now,
            expiresAt: lifetime.seconds.map { now.addingTimeInterval($0) })
        mutate { $0.append(link) }
        return (link, token)
    }

    /// Restart the clock: the new lifetime counts from now, not from creation.
    @discardableResult
    func setLifetime(id: String, _ lifetime: ShareLinkLifetime, now: Date = Date()) -> ShareLink? {
        var updated: ShareLink?
        mutate { links in
            guard let i = links.firstIndex(where: { $0.id == id }) else { return }
            links[i].expiresAt = lifetime.seconds.map { now.addingTimeInterval($0) }
            updated = links[i]
        }
        return updated
    }

    func revoke(id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }

    /// Every link to one pane, or with nil every link there is.
    func revokeAll(paneSessionKey: String? = nil) {
        mutate { links in
            links.removeAll { paneSessionKey == nil || $0.paneSessionKey == paneSessionKey }
        }
    }

    /// Links still open, newest first. Expired ones are dropped from the file
    /// on the way.
    func active(now: Date = Date()) -> [ShareLink] {
        lock.lock()
        let live = links.filter { $0.isLive(at: now) }
        let pruned = live.count != links.count
        if pruned { links = live; save() }
        lock.unlock()
        return live.sorted { $0.createdAt > $1.createdAt }
    }

    func check(token: String, paneSessionKey: String, now: Date = Date()) -> ShareLinkCheck {
        guard !token.isEmpty else { return .invalid }
        let hashed = Self.hash(token)
        lock.lock()
        let link = links.first { Self.constantTimeEqual($0.tokenHash, hashed) }
        lock.unlock()
        guard let link, link.paneSessionKey == paneSessionKey else { return .invalid }
        return link.isLive(at: now) ? .valid(id: link.id) : .expired
    }

    func isLive(id: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return links.first { $0.id == id }?.isLive(at: now) ?? false
    }

    // MARK: - Private

    private func mutate(_ change: (inout [ShareLink]) -> Void) {
        lock.lock()
        change(&links)
        save()
        let notify = onChange
        lock.unlock()
        notify?()
    }

    /// Must run while `lock` is held.
    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(links) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        // Holds what is shared with whom: this user's eyes only, like the socket.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }
}
