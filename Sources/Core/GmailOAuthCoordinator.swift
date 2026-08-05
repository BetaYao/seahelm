import AppKit
import Foundation
import Network

/// Owns one short-lived OAuth transaction. It accepts only a localhost callback,
/// verifies the PKCE state before exchanging the code, then stores credentials
/// in Keychain. Nothing from this flow is persisted in Config.
final class GmailOAuthCoordinator {
    enum Error: LocalizedError {
        case listener(String), invalidTokenResponse, tokenExchange(Int, String), missingRefreshToken

        var errorDescription: String? {
            switch self {
            case .listener(let message): return message
            case .invalidTokenResponse: return "Google returned an invalid token response."
            case .tokenExchange(let status, let reason): return "Google rejected the OAuth token exchange (HTTP \(status)): \(reason)"
            case .missingRefreshToken: return "Google did not return a refresh token. Revoke Seahelm access and connect again."
            }
        }
    }

    private let credentialStore: GmailOAuthCredentialStoring
    private var listener: NWListener?
    private var request: GmailOAuthAuthorization.Request?
    private var accountEmail: String?
    private var completion: ((Result<Void, Swift.Error>) -> Void)?
    private var handlingCallback = false

    init(credentialStore: GmailOAuthCredentialStoring = GmailOAuthCredentialStore()) {
        self.credentialStore = credentialStore
    }

    func connect(accountEmail: String, completion: @escaping (Result<Void, Swift.Error>) -> Void) {
        guard GmailMailConfig.isEmail(accountEmail) else {
            completion(.failure(GmailMailConfigError.invalidAccount)); return
        }
        guard !GmailOAuthAuthorization.clientID.isEmpty, !GmailOAuthAuthorization.clientSecret.isEmpty else {
            completion(.failure(Error.listener("Gmail OAuth client configuration is missing."))); return
        }
        self.accountEmail = GmailMailConfig.normalizeEmail(accountEmail)
        self.completion = completion
        startListener()
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        completion = nil
        request = nil
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.receiveCallback(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port else { self.finish(.failure(Error.listener("OAuth callback port unavailable"))); return }
                    let redirect = URL(string: "http://127.0.0.1:\(port)/callback")!
                    let request = GmailOAuthAuthorization.makeRequest(redirectURI: redirect)
                    self.request = request
                    NSWorkspace.shared.open(request.url)
                case .failed(let error): self.finish(.failure(Error.listener(error.localizedDescription)))
                default: break
                }
            }
            listener.start(queue: .main)
        } catch { finish(.failure(error)) }
    }

    private func receiveCallback(_ connection: NWConnection) {
        guard !handlingCallback else { connection.cancel(); return }
        handlingCallback = true
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self, let data, let raw = String(data: data, encoding: .utf8), let first = raw.split(separator: "\n").first else { return }
            let target = first.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let callback = URL(string: "http://127.0.0.1\(target)")
            let result = callback.map { GmailOAuthAuthorization.authorizationCode(from: $0, expectedState: self.request?.state ?? "") }
            let succeeded: Bool
            if case .some(.success) = result { succeeded = true } else { succeeded = false }
            connection.send(content: GmailOAuthCallbackPage.httpResponse(succeeded: succeeded), completion: .contentProcessed { _ in connection.cancel() })
            guard let result, case .success(let code) = result else { self.finish(.failure(GmailOAuthAuthorization.CallbackError.invalidCallback)); return }
            self.exchange(code: code)
        }
    }

    private func exchange(code: String) {
        guard let request, let accountEmail else { return }
        var urlRequest = URLRequest(url: GmailOAuthAuthorization.tokenEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let redirect = request.url.queryValue(named: "redirect_uri") ?? ""
        urlRequest.httpBody = form(["code": code, "client_id": GmailOAuthAuthorization.clientID,
                                    "client_secret": GmailOAuthAuthorization.clientSecret,
                                    "code_verifier": request.codeVerifier, "grant_type": "authorization_code", "redirect_uri": redirect]).data(using: .utf8)
        URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.finish(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let reason = data.flatMap { try? JSONDecoder().decode(TokenError.self, from: $0).error_description } ?? "unknown_error"
                self.finish(.failure(Error.tokenExchange(status, reason))); return
            }
            guard let data, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else { self.finish(.failure(Error.invalidTokenResponse)); return }
            guard let refresh = token.refresh_token, !refresh.isEmpty else { self.finish(.failure(Error.missingRefreshToken)); return }
            do { try self.credentialStore.save(.init(accessToken: token.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(token.expires_in)), accountEmail: accountEmail); self.finish(.success(())) } catch { self.finish(.failure(error)) }
        }.resume()
    }

    private func finish(_ result: Result<Void, Swift.Error>) {
        listener?.cancel(); listener = nil; request = nil
        let completion = self.completion; self.completion = nil
        DispatchQueue.main.async { completion?(result) }
    }

    private func form(_ values: [String: String]) -> String {
        values.map { key, value in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }

    private struct TokenResponse: Decodable { let access_token: String; let refresh_token: String?; let expires_in: TimeInterval }
    private struct TokenError: Decodable { let error_description: String? }
}

enum GmailMailConfigError: LocalizedError { case invalidAccount; var errorDescription: String? { "Enter a valid Gmail address." } }

private extension URL {
    func queryValue(named name: String) -> String? { URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value }
}
