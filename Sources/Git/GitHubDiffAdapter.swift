import Foundation

/// 把 GitHub API 返回的 patch 文本转成 DiffReviewView 可用的 `GitDiffSnapshot`。
enum GitHubDiffAdapter {

    /// 从 GitHubPRFile 列表生成快照。
    /// - 每个文件有 patch 就用 parseDiff 解析
    /// - 没有 patch（比如二进制文件/超大文件）就兜底一个空 diff
    static func snapshot(from prFiles: [GitHubPRFile], stage: GitChangeStage = .unstaged) -> GitDiffSnapshot {
        var diffFiles: [DiffFile] = []
        var changedFiles: [GitChangedFile] = []

        for file in prFiles {
            let fileStatus = status(from: file.status)
            changedFiles.append(GitChangedFile(
                path: file.filename,
                oldPath: file.previousFilename,
                status: fileStatus,
                stage: stage
            ))

            if let patch = file.patch {
                let parsed = GitDiff.parseDiff(patch, stage: stage)
                diffFiles.append(contentsOf: parsed)
            } else {
                // 没有 patch（二进制或超大文件），用空 hunk 兜底
                diffFiles.append(DiffFile(
                    path: file.filename,
                    oldPath: file.previousFilename,
                    status: fileStatus,
                    stage: stage,
                    additions: file.additions,
                    deletions: file.deletions,
                    hunks: []
                ))
            }
        }

        return GitDiffSnapshot(changedFiles: changedFiles, files: diffFiles)
    }

    private static func status(from ghStatus: String) -> DiffFile.FileStatus {
        switch ghStatus {
        case "added":      return .added
        case "modified":   return .modified
        case "deleted":    return .deleted
        case "renamed":    return .renamed
        default:           return .unknown
        }
    }
}
