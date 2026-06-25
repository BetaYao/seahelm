import Foundation

/// Semantic version (major.minor.patch) with comparison support.
struct SemVer: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parse a version string like "2.1.0" or "v2.1.0".
    init?(_ string: String) {
        let stripped = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = stripped.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        major = parts[0]
        minor = parts[1]
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var description: String { "\(major).\(minor).\(patch)" }
    var string: String { description }
}
