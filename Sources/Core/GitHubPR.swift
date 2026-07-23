import Foundation

// MARK: - PR 列表 + 详情

struct GitHubPR: Codable {
    let number: Int
    let title: String
    let body: String?
    let state: String           // "open", "closed", "merged"
    let draft: Bool
    let htmlURL: String
    let diffURL: String?
    let patchURL: String?

    let head: GitHubBranchRef
    let base: GitHubBranchRef

    let user: GitHubUser
    let labels: [GitHubLabel]?
    let assignees: [GitHubUser]?

    let createdAt: String
    let updatedAt: String
    let closedAt: String?
    let mergedAt: String?

    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let comments: Int
    let reviewComments: Int
    let commits: Int

    let mergeable: Bool?           // 可能为 null（还在计算）

    enum CodingKeys: String, CodingKey {
        case number, title, body, state, draft
        case htmlURL = "html_url"
        case diffURL = "diff_url"
        case patchURL = "patch_url"
        case head, base, user, labels, assignees
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case closedAt = "closed_at"
        case mergedAt = "merged_at"
        case additions, deletions
        case changedFiles = "changed_files"
        case comments
        case reviewComments = "review_comments"
        case commits, mergeable
    }
}

// MARK: - 分支引用

struct GitHubBranchRef: Codable {
    let label: String           // "user:branch-name"
    let ref: String
    let sha: String
    let repo: GitHubRepo?
}

// MARK: - 仓库

struct GitHubRepo: Codable {
    let id: Int
    let fullName: String        // "owner/repo"
    let name: String
    let owner: GitHubUser
    let `private`: Bool
    let htmlURL: String
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case id, name, owner, `private`
        case fullName = "full_name"
        case htmlURL = "html_url"
        case defaultBranch = "default_branch"
    }
}

// MARK: - 用户

struct GitHubUser: Codable {
    let login: String
    let id: Int
    let avatarURL: String?
    let type: String?           // "User", "Bot"

    enum CodingKeys: String, CodingKey {
        case login, id, type
        case avatarURL = "avatar_url"
    }
}

// MARK: - 标签

struct GitHubLabel: Codable {
    let name: String
    let color: String           // hex without #
    let description: String?
}

// MARK: - PR 变更文件

struct GitHubPRFile: Codable {
    let filename: String
    let status: String          // "added", "modified", "deleted", "renamed"
    let additions: Int
    let deletions: Int
    let changes: Int
    let patch: String?          // unified diff 文本
    let previousFilename: String?
    let contentsURL: String?
    let rawURL: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, changes
        case patch
        case previousFilename = "previous_filename"
        case contentsURL = "contents_url"
        case rawURL = "raw_url"
    }
}

// MARK: - Review Comment

struct GitHubReviewComment: Codable {
    let id: Int
    let body: String
    let path: String?
    let position: Int?          // diff 中位置（已废弃，但 GitHub 仍然返回）
    let line: Int?              // 实际行号
    let commitID: String
    let user: GitHubUser
    let createdAt: String
    let updatedAt: String
    let pullRequestReviewID: Int?

    enum CodingKeys: String, CodingKey {
        case id, body, path, position, line, user
        case commitID = "commit_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case pullRequestReviewID = "pull_request_review_id"
    }
}

// MARK: - Review 提交 body

struct GitHubSubmitReviewBody: Encodable {
    let body: String
    let event: String           // "APPROVE", "COMMENT", "REQUEST_CHANGES"
    let comments: [GitHubInlineComment]?

    struct GitHubInlineComment: Encodable {
        let path: String
        let body: String
        let line: Int           // 行号
    }
}

// MARK: - 列表查询参数

struct GitHubPRListParams {
    var state: String = "open"      // "open", "closed", "all"
    var head: String?               // 源分支 "user:ref-name"
    var base: String?               // 目标分支名
    var sort: String = "updated"    // "created", "updated", "popularity", "long-running"
    var direction: String = "desc"
    var perPage: Int = 30
    var page: Int = 1
}
