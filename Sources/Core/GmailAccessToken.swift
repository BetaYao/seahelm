import Foundation

/// Hands out a usable access token, exchanging the stored refresh token
/// whenever the current one is spent.
///
/// Google's access tokens last an hour. Without this the channel worked until
/// the first expiry and then stopped for good — the poller reads a 401 as
/// `authorizationExpired` and calls `stopLocked()`, so the only recovery was
/// re-running the whole consent flow by hand. The refresh token was already
/// being stored at connect time; nothing ever spent it.
protocol GmailAccessTokenProviding: AnyObject {
    func token(forceRefresh: Bool, completion: @escaping (Result<String, GmailMailClientError>) -> Void)
}

extension Result where Failure == GmailMailClientError {
    /// The error of a failed result, for call sites that have already matched
    /// the success case and only need to forward the reason.
    var failureError: GmailMailClientError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

final class GmailAccessTokenProvider: GmailAccessTokenProviding {
    /// Refresh this long before the recorded expiry, so a request that is
    /// already in flight when the hour turns doesn't land on a dead token.
    private static let renewalMargin: TimeInterval = 120

    private let accountEmail: String
    private let credentials: GmailOAuthCredentialStoring
    private let session: URLSession
    private let queue = DispatchQueue(label: "seahelm.gmail-access-token")
    /// Completions waiting on the exchange currently in flight. Coalesced so a
    /// poll and a send arriving together spend the refresh token once — Google
    /// may rotate it, which would strand whichever request lost the race.
    private var waiting: [(Result<String, GmailMailClientError>) -> Void] = []
    private var refreshing = false

    init(accountEmail: String, credentials: GmailOAuthCredentialStoring = GmailOAuthCredentialStore(),
         session: URLSession = .shared) {
        self.accountEmail = GmailMailConfig.normalizeEmail(accountEmail)
        self.credentials = credentials
        self.session = session
    }

    func token(forceRefresh: Bool = false, completion: @escaping (Result<String, GmailMailClientError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let stored = (try? self.credentials.load(accountEmail: self.accountEmail)) ?? nil else {
                completion(.failure(.authorizationExpired)); return
            }
            let fresh = stored.expiresAt.timeIntervalSinceNow > Self.renewalMargin
            if !forceRefresh, fresh, !stored.accessToken.isEmpty {
                completion(.success(stored.accessToken)); return
            }
            guard !stored.refreshToken.isEmpty else { completion(.failure(.authorizationExpired)); return }

            self.waiting.append(completion)
            guard !self.refreshing else { return }
            self.refreshing = true
            self.exchange(refreshToken: stored.refreshToken)
        }
    }

    private func exchange(refreshToken: String) {
        var request = URLRequest(url: GmailOAuthAuthorization.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([
            "client_id=\(GmailOAuthAuthorization.clientID)",
            "client_secret=\(GmailOAuthAuthorization.clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&").utf8)

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                let result = self.decode(data: data, response: response, error: error, refreshToken: refreshToken)
                let pending = self.waiting
                self.waiting = []
                self.refreshing = false
                pending.forEach { $0(result) }
            }
        }.resume()
    }

    private func decode(data: Data?, response: URLResponse?, error: Error?,
                        refreshToken: String) -> Result<String, GmailMailClientError> {
        if let error { return .failure(.transport(error.localizedDescription)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A refused refresh token means consent was revoked or expired;
            // nothing but a new consent flow recovers it.
            return .failure(status == 400 || status == 401 ? .authorizationExpired : .transport("HTTP \(status)"))
        }
        guard let data, let token = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !token.access_token.isEmpty else { return .failure(.malformedResponse) }
        // Google usually omits refresh_token on a refresh; keep the one we have.
        try? credentials.save(.init(accessToken: token.access_token,
                                    refreshToken: token.refresh_token ?? refreshToken,
                                    expiresAt: Date().addingTimeInterval(token.expires_in)),
                              accountEmail: accountEmail)
        return .success(token.access_token)
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
    }
}
