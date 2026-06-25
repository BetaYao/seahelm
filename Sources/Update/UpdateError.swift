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
        case .networkError(let e): return "网络错误: \(e.localizedDescription)"
        case .extractionFailed: return "解压失败"
        case .signatureInvalid: return "签名验证失败"
        case .noMatchingAsset: return "未找到匹配的安装包"
        case .invalidAppPath: return "应用路径无效"
        case .versionParseError(let v): return "版本号解析失败: \(v)"
        case .rateLimited: return "请求过于频繁，稍后再试"
        }
    }
}
