import Foundation
import Security

struct PairingCodeStore: Equatable {
    var code: String?

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        // Map each byte into 0...9 without bias that matters at this size.
        return bytes.map { String($0 % 10) }.joined()
    }

    static func normalize(_ raw: String) -> String {
        String(raw.filter(\.isNumber))
    }

    static func isValidFormat(_ code: String) -> Bool {
        let n = normalize(code)
        return n.count == 8 && n.allSatisfy(\.isNumber)
    }

    mutating func ensureCode() -> String {
        if let code, Self.isValidFormat(code) { return Self.normalize(code) }
        let next = Self.generate()
        code = next
        return next
    }

    @discardableResult
    mutating func refresh() -> String {
        let next = Self.generate()
        code = next
        return next
    }

    func verify(_ raw: String) -> Bool {
        guard let code, Self.isValidFormat(code) else { return false }
        let expected = Array(Self.normalize(code).utf8)
        let got = Array(Self.normalize(raw).utf8)
        guard expected.count == got.count, got.count == 8 else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, got) { diff |= a ^ b }
        return diff == 0
    }
}
