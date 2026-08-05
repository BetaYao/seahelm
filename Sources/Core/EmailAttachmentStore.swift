import CryptoKit
import Foundation

struct EmailAttachment: Equatable {
    let filename: String
    let mimeType: String
    let data: Data
}

enum EmailAttachmentStoreError: Error { case unsupported; case tooLarge }

final class EmailAttachmentStore {
    private let root: URL
    private static let allowed: Set<String> = ["application/pdf", "image/png", "image/jpeg", "image/heic", "text/plain", "text/markdown"]
    init(root: URL = Config.configDir.appendingPathComponent("mail-attachments")) { self.root = root }

    func importAttachments(_ attachments: [EmailAttachment], account: String, threadID: String, messageID: String, limit: Int) throws -> [URL] {
        guard attachments.allSatisfy({ Self.allowed.contains($0.mimeType.lowercased()) }) else { throw EmailAttachmentStoreError.unsupported }
        guard attachments.reduce(0, { $0 + $1.data.count }) <= limit else { throw EmailAttachmentStoreError.tooLarge }
        let dir = root.appendingPathComponent(Self.digest(account)).appendingPathComponent(Self.digest(threadID)).appendingPathComponent(Self.digest(messageID))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try attachments.map { attachment in
            let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(extensionFor(attachment.mimeType))
            try attachment.data.write(to: url, options: .atomic)
            return url
        }
    }
    func remove(threadID: String, account: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.digest(account)).appendingPathComponent(Self.digest(threadID))) }
    private func extensionFor(_ type: String) -> String { ["application/pdf":"pdf", "image/png":"png", "image/jpeg":"jpg", "image/heic":"heic", "text/plain":"txt", "text/markdown":"md"][type.lowercased()] ?? "bin" }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
