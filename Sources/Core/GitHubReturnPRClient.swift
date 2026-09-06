import Foundation

/// `WorktreeReturnPRClient` over the REST client, made synchronous: the return
/// runner works through its steps on a background queue and blocks on each.
struct GitHubReturnPRClient: WorktreeReturnPRClient {
    let service: GitHubPRService
    let owner: String

    func createPR(title: String, body: String, head: String, base: String) throws -> String {
        try Self.awaitSync {
            try await service.createPR(title: title, body: body, head: "\(owner):\(head)", base: base).htmlURL
        }
    }

    /// URL of the open PR for `branch`, if there is one. Nil on any error: a
    /// failed lookup must not stop a return — at worst it opens a second PR,
    /// which GitHub itself refuses.
    func openPRURL(branch: String) -> String? {
        (try? Self.awaitSync { try await service.findOpenPR(head: "\(owner):\(branch)")?.htmlURL }) ?? nil
    }

    /// Blocks the calling (background) thread on an async call.
    static func awaitSync<T>(_ op: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(GitHubAPIError.serverError(statusCode: 0, message: "no result"))
        Task {
            do { result = .success(try await op()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}
