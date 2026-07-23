import Foundation

/// GitHub REST API v3 客户端，负责 PR 列表/详情/评论的拉取和提交。
///
/// 使用方式：
/// ```
/// let service = GitHubPRService(token: "ghp_xxx", owner: "apple", repo: "swift")
/// let prs = try await service.listPRs()
/// let files = try await service.listPRFiles(number: 42)
/// ```
final class GitHubPRService {
    private let session: URLSession
    private let token: String
    private let owner: String
    private let repo: String
    private let baseURL = "https://api.github.com"

    /// token 可能是空字符串（未登录场景），此时只读接口会返回 401。
    /// 调用方负责检查 token 非空后再调用需要写权限的接口。
    init(token: String, owner: String, repo: String) {
        self.token = token
        self.owner = owner
        self.repo = repo

        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        // GitHub API 需要合理的 UA，否则返回 403
        config.httpAdditionalHeaders = [
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "seahelm/1.0",
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - PR 列表

    /// 获取 PR 列表，分页由调用方通过 params.page 控制。
    func listPRs(params: GitHubPRListParams = .init()) async throws -> [GitHubPR] {
        var components = URLComponents(string: "\(baseURL)/repos/\(owner)/\(repo)/pulls")!
        components.queryItems = [
            URLQueryItem(name: "state", value: params.state),
            URLQueryItem(name: "sort", value: params.sort),
            URLQueryItem(name: "direction", value: params.direction),
            URLQueryItem(name: "per_page", value: String(params.perPage)),
            URLQueryItem(name: "page", value: String(params.page)),
        ]
        if let head = params.head {
            components.queryItems?.append(URLQueryItem(name: "head", value: head))
        }
        if let base = params.base {
            components.queryItems?.append(URLQueryItem(name: "base", value: base))
        }
        return try await get(components.url!)
    }

    // MARK: - PR 详情

    /// 单个 PR 完整信息。
    func getPR(number: Int) async throws -> GitHubPR {
        let url = URL(string: "\(baseURL)/repos/\(owner)/\(repo)/pulls/\(number)")!
        return try await get(url)
    }

    // MARK: - 变更文件

    /// PR 的变更文件列表，每个文件包含 patch unified diff 文本。
    func listPRFiles(number: Int) async throws -> [GitHubPRFile] {
        let url = URL(string: "\(baseURL)/repos/\(owner)/\(repo)/pulls/\(number)/files")!
        return try await get(url)
    }

    // MARK: - Review Comments

    /// 获取 PR 上所有 review comments（行内评论）。
    func listReviewComments(number: Int) async throws -> [GitHubReviewComment] {
        let url = URL(string: "\(baseURL)/repos/\(owner)/\(repo)/pulls/\(number)/comments")!
        return try await get(url)
    }

    /// 对特定文件某行提交 inline comment。
    @discardableResult
    func createReviewComment(
        number: Int,
        body: String,
        commitID: String,
        path: String,
        line: Int
    ) async throws -> GitHubReviewComment {
        let url = URL(string: "\(baseURL)/repos/\(owner)/\(repo)/pulls/\(number)/comments")!
        let payload: [String: Any] = [
            "body": body,
            "commit_id": commitID,
            "path": path,
            "line": line,
        ]
        return try await post(url, body: payload)
    }

    /// 提交 review（approve / comment / request_changes）。
    @discardableResult
    func submitReview(
        number: Int,
        body: String,
        event: String,          // "APPROVE", "COMMENT", "REQUEST_CHANGES"
        comments: [GitHubSubmitReviewBody.GitHubInlineComment]? = nil
    ) async throws -> Any {
        let url = URL(string: "\(baseURL)/repos/\(owner)/\(repo)/pulls/\(number)/reviews")!
        var payload: [String: Any] = [
            "body": body,
            "event": event,
        ]
        if let comments {
            let encoder = JSONEncoder()
            let data = try encoder.encode(comments)
            payload["comments"] = try JSONSerialization.jsonObject(with: data)
        }
        return try await post(url, body: payload)
    }

    // MARK: - Private networking

    private var authHeader: String {
        "Bearer \(token)"
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ url: URL, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// POST 且返回任意 JSON（不指定类型时用）。
    private func post(_ url: URL, body: [String: Any]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }

        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw GitHubAPIError.unauthorized
        case 403:
            // 检查 rate limit
            if let remaining = http.allHeaderFields["X-RateLimit-Remaining"] as? String,
               remaining == "0" {
                let reset = http.allHeaderFields["X-RateLimit-Reset"] as? String ?? ""
                throw GitHubAPIError.rateLimitExceeded(resetAt: reset)
            }
            throw GitHubAPIError.forbidden
        case 404:
            throw GitHubAPIError.notFound
        default:
            let body = (try? JSONDecoder().decode(GitHubErrorBody.self, from: data))
                ?? GitHubErrorBody(message: "Unknown error")
            throw GitHubAPIError.serverError(statusCode: http.statusCode, message: body.message)
        }
    }
}

// MARK: - Errors

enum GitHubAPIError: LocalizedError {
    case unauthorized
    case forbidden
    case notFound
    case rateLimitExceeded(resetAt: String)
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "GitHub token is invalid or expired"
        case .forbidden:
            return "Access to this repository is forbidden"
        case .notFound:
            return "Repository or PR not found"
        case .rateLimitExceeded(let resetAt):
            return "GitHub API rate limit exceeded, resets at \(resetAt)"
        case .serverError(let code, let message):
            return "GitHub API error (\(code)): \(message)"
        }
    }
}

private struct GitHubErrorBody: Decodable {
    let message: String
}
