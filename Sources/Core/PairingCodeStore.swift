import Foundation
import Security

/// The code a browser enters once to pair with this Mac. It stays until you
/// refresh it, set your own, or revoke every remote — nothing rotates it.
struct PairingCodeStore: Equatable {
    var code: String?

    /// Generated codes are 8 digits. One you set may be longer, never shorter:
    /// with a public gateway URL it is all that stands in front of your panes.
    static let lengths = 8...16

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        // Map each byte into 0...9 without bias that matters at this size.
        return bytes.map { String($0 % 10) }.joined()
    }

    static func normalize(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber })
    }

    static func isValidFormat(_ code: String) -> Bool {
        lengths.contains(normalize(code).count)
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

    /// Replace the code with one you chose. Spaces and dashes are allowed for
    /// reading it back; any other character, or a length outside `lengths`, is
    /// refused rather than quietly dropped. Returns the stored digits.
    mutating func set(_ raw: String) -> String? {
        guard raw.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }),
              Self.isValidFormat(raw) else { return nil }
        let next = Self.normalize(raw)
        code = next
        return next
    }

    func verify(_ raw: String) -> Bool {
        guard let code, Self.isValidFormat(code) else { return false }
        let expected = Array(Self.normalize(code).utf8)
        let got = Array(Self.normalize(raw).utf8)
        guard expected.count == got.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, got) { diff |= a ^ b }
        return diff == 0
    }

    /// Digits in fours, the way the code is shown and typed.
    static func grouped(_ code: String) -> String {
        let digits = Array(normalize(code))
        return stride(from: 0, to: digits.count, by: 4)
            .map { String(digits[$0..<min($0 + 4, digits.count)]) }
            .joined(separator: " ")
    }
}
