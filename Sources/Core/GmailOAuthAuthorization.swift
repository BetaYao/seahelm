import CryptoKit
import Foundation
import Security

/// Public OAuth client metadata. The client ID identifies Seahelm to Google; it
/// is not a client secret and is safe to ship in the desktop app.
enum GmailOAuthAuthorization {
    static var clientID: String { GmailOAuthClientConfiguration.load()?.clientID ?? "" }
    static var clientSecret: String { GmailOAuthClientConfiguration.load()?.clientSecret ?? "" }
    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
    ]

    struct Request: Equatable {
        let url: URL
        let state: String
        let codeVerifier: String
    }

    /// Creates an authorization-code flow with S256 PKCE. The loopback listener
    /// supplies the redirect URI at runtime; client secrets are never used by a
    /// native app.
    static func makeRequest(redirectURI: URL) -> Request {
        let verifier = randomURLSafeString(byteCount: 48)
        let state = randomURLSafeString(byteCount: 24)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return Request(url: components.url!, state: state, codeVerifier: verifier)
    }

    static func authorizationCode(from callbackURL: URL, expectedState: String) -> Result<String, CallbackError> {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return .failure(.invalidCallback)
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == expectedState else { return .failure(.stateMismatch) }
        if let description = values["error_description"], !description.isEmpty { return .failure(.provider(description)) }
        if let error = values["error"], !error.isEmpty { return .failure(.provider(error)) }
        guard let code = values["code"], !code.isEmpty else { return .failure(.missingCode) }
        return .success(code)
    }

    enum CallbackError: Equatable, LocalizedError {
        case invalidCallback
        case stateMismatch
        case missingCode
        case provider(String)

        var errorDescription: String? {
            switch self {
            case .invalidCallback: return "Invalid OAuth callback."
            case .stateMismatch: return "OAuth callback state did not match."
            case .missingCode: return "OAuth callback did not contain an authorization code."
            case .provider(let message): return message
            }
        }
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// OAuth client metadata for the Gmail channel. A machine-local override at
/// ~/.config/seahelm/gmail-oauth-client.json wins when present (handy for
/// testing against a personal Google Cloud OAuth client); otherwise this
/// falls back to the client baked into Info.plist at release-build time (see
/// project.yml / scripts/package_release.sh). Google does not treat a
/// Desktop-app client secret as confidential — it necessarily ships inside
/// every copy of the app — so bundling it is the sanctioned distribution
/// model, not a security shortcut.
struct GmailOAuthClientConfiguration: Codable {
    let clientID: String
    let clientSecret: String

    static let fileURL = Config.configDir.appendingPathComponent("gmail-oauth-client.json")

    static func load() -> GmailOAuthClientConfiguration? {
        fromConfigFile() ?? fromBundle()
    }

    private static func fromConfigFile() -> GmailOAuthClientConfiguration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    private static func fromBundle() -> GmailOAuthClientConfiguration? {
        guard
            let clientID = Bundle.main.object(forInfoDictionaryKey: "GmailOAuthClientID") as? String, !clientID.isEmpty,
            let clientSecret = Bundle.main.object(forInfoDictionaryKey: "GmailOAuthClientSecret") as? String, !clientSecret.isEmpty
        else { return nil }
        return GmailOAuthClientConfiguration(clientID: clientID, clientSecret: clientSecret)
    }
}
