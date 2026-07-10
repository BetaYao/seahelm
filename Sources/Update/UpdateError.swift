import Foundation

enum UpdateError: Error, LocalizedError {
    case networkError(underlying: Error)
    case extractionFailed
    case signatureInvalid
    case noMatchingAsset
    case invalidAppPath
    case versionParseError(String)
    case rateLimited(retryAfter: Date)

    var errorDescription: String? {
        switch self {
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .extractionFailed: return "Extraction failed"
        case .signatureInvalid: return "Signature verification failed"
        case .noMatchingAsset: return "No matching installer found"
        case .invalidAppPath: return "Invalid app path"
        case .versionParseError(let v): return "Failed to parse version: \(v)"
        case .rateLimited: return "Too many requests, try again later"
        }
    }
}
