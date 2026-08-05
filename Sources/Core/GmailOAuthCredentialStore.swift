import Foundation
import Security

/// The persistent OAuth material for one Gmail account. Never encode this into
/// Config, logs, or an audit entry.
struct GmailOAuthCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

protocol GmailOAuthCredentialStoring {
    func load(accountEmail: String) throws -> GmailOAuthCredentials?
    func save(_ credentials: GmailOAuthCredentials, accountEmail: String) throws
    func remove(accountEmail: String) throws
}

enum GmailOAuthCredentialStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): return "Keychain error: \(status)"
        case .invalidStoredData: return "Stored Gmail credentials are invalid."
        }
    }
}

final class GmailOAuthCredentialStore: GmailOAuthCredentialStoring {
    private let service = "com.seahelm.gmail-mail.oauth"

    func load(accountEmail: String) throws -> GmailOAuthCredentials? {
        var query = baseQuery(accountEmail: accountEmail)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw GmailOAuthCredentialStoreError.unexpectedStatus(status)
        }
        guard let credentials = try? JSONDecoder().decode(GmailOAuthCredentials.self, from: data) else {
            throw GmailOAuthCredentialStoreError.invalidStoredData
        }
        return credentials
    }

    func save(_ credentials: GmailOAuthCredentials, accountEmail: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = baseQuery(accountEmail: accountEmail)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw GmailOAuthCredentialStoreError.unexpectedStatus(add) }
        } else if update != errSecSuccess {
            throw GmailOAuthCredentialStoreError.unexpectedStatus(update)
        }
    }

    func remove(accountEmail: String) throws {
        let status = SecItemDelete(baseQuery(accountEmail: accountEmail) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GmailOAuthCredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(accountEmail: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: GmailMailConfig.normalizeEmail(accountEmail),
        ]
    }
}
