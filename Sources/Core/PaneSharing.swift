import Foundation

/// How long a share link lives. Chosen when the link is copied, changeable
/// after. seahelm-gateway keeps the links and drops any page still open on one
/// the moment it passes (docs/seahelm-gateway-plan.md, `share.*`).
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

    /// A name fit to stand in a `[from <name>]` prefix: one line, no
    /// brackets, short. Nil when nothing is left.
    static func recipientName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.unicodeScalars
            .map { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let name = String(cleaned.prefix(40))
        return name.isEmpty ? nil : name
    }
}

/// What the header's share button copies. `gatewayListening` is false when the
/// link is real but nothing is serving it yet.
struct PaneShareOffer: Equatable {
    var url: String
    var gatewayListening: Bool
    var linkId: String
    var paneSessionKey: String
    var lifetime: ShareLinkLifetime
    var expiresAt: Date?
    /// Who the link is for; nil while anyone who opens it names themselves.
    var recipient: String?
    /// Other live links to the same pane, not counting this one.
    var otherLinks: Int
}

/// The header's share popover, answered by the window that owns the panes.
/// Every call goes to seahelm-gateway over `gateway.sock`, so each completes
/// on the main thread, later; a nil offer means the gateway refused or is not
/// running.
protocol PaneSharing: AnyObject {
    /// A new link to the focused pane.
    func shareFocusedPane(lifetime: ShareLinkLifetime, completion: @escaping (Result<PaneShareOffer, GatewayClient.Failure>) -> Void)
    /// Same link, same URL; the new lifetime counts from now.
    func changeShare(_ offer: PaneShareOffer, lifetime: ShareLinkLifetime, completion: @escaping (PaneShareOffer?) -> Void)
    /// Bind the link to one person, or with nil open it to anyone.
    func changeShare(_ offer: PaneShareOffer, recipient: String?, completion: @escaping (PaneShareOffer?) -> Void)
    func revokeShare(_ offer: PaneShareOffer)
    func revokeAllShares(paneSessionKey: String)
}
