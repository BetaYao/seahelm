import XCTest
@testable import seahelm

final class MergedPRLookupTests: XCTestCase {

    private var tempDir: URL?

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    /// Closed-but-unmerged PRs are not a record of anything reaching the base,
    /// and the newest merge has to come first — the Changes list anchors on the
    /// first head the branch contains.
    func testMergedHeadsDropUnmergedAndPutTheNewestMergeFirst() throws {
        let prs = try decodePRs([
            (number: 10, sha: "aaa", mergedAt: "2026-09-01T10:00:00Z"),
            (number: 11, sha: "bbb", mergedAt: nil),
            (number: 12, sha: "ccc", mergedAt: "2026-09-16T08:56:23Z"),
        ])

        XCTAssertEqual(MergedPRLookup.mergedHeads(prs), [
            MergedPRHead(number: 12, headSHA: "ccc"),
            MergedPRHead(number: 10, headSHA: "aaa"),
        ])
    }

    /// Only a GitHub origin is worth asking about, and the token sources are
    /// subprocesses — a repo without one must not touch them.
    func testRepoWithoutAGitHubOriginResolvesNoToken() throws {
        let repo = try makeRepo(origin: nil)
        let lookup = MergedPRLookup()
        var tokenRequests = 0
        lookup.resolveToken = { _ in tokenRequests += 1; return "" }

        XCTAssertEqual(lookup.mergedPRs(worktreePath: repo, branch: "feat", baseBranch: "main"), [])
        XCTAssertEqual(tokenRequests, 0)
    }

    /// Without a token nothing is requested, and the miss is cached, so the
    /// panel's next reload does not resolve the token all over again.
    func testMissingTokenIsAskedForOnceAndTheMissIsCached() throws {
        let repo = try makeRepo(origin: "git@github.com:example/project.git")
        let lookup = MergedPRLookup()
        var tokenRequests = 0
        lookup.resolveToken = { _ in tokenRequests += 1; return "" }

        XCTAssertEqual(lookup.mergedPRs(worktreePath: repo, branch: "feat", baseBranch: "main"), [])
        XCTAssertEqual(lookup.mergedPRs(worktreePath: repo, branch: "feat", baseBranch: "main"), [])
        XCTAssertEqual(tokenRequests, 1)
    }

    // TMP-LIVE-BEGIN
    func testTmpLive() {
        let lookup = MergedPRLookup()
        lookup.resolveToken = { MainWindowController.resolveGitHubToken(repoPath: $0) }
        for path in ["/Volumes/openbeta/workspace/teamclaw-worktrees/task/pai-hang-bang",
                     "/Volumes/openbeta/workspace/seahelm"] {
            let start = Date()
            let branch = GitDiff.branchChangedFiles(worktreePath: path, recordedBase: nil, mergedPRs: lookup.mergedPRs)
            let first = Date().timeIntervalSince(start)
            let again = Date()
            _ = GitDiff.branchChangedFiles(worktreePath: path, recordedBase: nil, mergedPRs: lookup.mergedPRs)
            print("LIVE \((path as NSString).lastPathComponent) first=\(String(format: "%.2f", first))s cached=\(String(format: "%.2f", Date().timeIntervalSince(again)))s basis=\(branch.basis) subtitle=\(ChangesSummary.subtitle(for: branch)) sections=\(ChangesSummary.sections(for: branch).map(\.title))")
        }
    }
    // TMP-LIVE-END

    // MARK: - helpers

    private func decodePRs(_ specs: [(number: Int, sha: String, mergedAt: String?)]) throws -> [GitHubPR] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "github-pr-list", withExtension: "json"))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let template = try XCTUnwrap(list.first)
        let edited: [[String: Any]] = try specs.map { spec in
            var pr = template
            pr["number"] = spec.number
            pr["merged_at"] = spec.mergedAt ?? NSNull()
            var head = try XCTUnwrap(pr["head"] as? [String: Any])
            head["sha"] = spec.sha
            pr["head"] = head
            return pr
        }
        return try JSONDecoder().decode([GitHubPR].self, from: JSONSerialization.data(withJSONObject: edited))
    }

    private func makeRepo(origin: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-merged-pr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        git(["init", "-q", "-b", "main"], in: dir.path)
        if let origin {
            git(["remote", "add", "origin", origin], in: dir.path)
        }
        return dir.path
    }

    private func git(_ args: [String], in directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        try? process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
    }
}
