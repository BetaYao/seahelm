import Foundation

struct ReleaseInfo {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
    let publishedAt: Date
}

protocol UpdateCheckerDelegate: AnyObject {
    func updateChecker(_ checker: UpdateChecker, didFindRelease release: ReleaseInfo)
}

/// Checks GitHub Releases API for new versions of seahelm.
class UpdateChecker {
    static let repositoryOwner = "BetaYao"
    static let repositoryName = "seahelm"

    #if arch(arm64)
    static let assetSuffix = "arm64.zip"
    #else
    static let assetSuffix = "x86_64.zip"
    #endif

    weak var delegate: UpdateCheckerDelegate?

    let currentVersion: String
    var skippedVersion: String?

    private var timer: Timer?
    private var rateLimitResetDate: Date?

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// For testing: inject a known version.
    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    func startPolling(intervalHours: Int) {
        let interval = TimeInterval(intervalHours * 3600)
        Task { await checkAndNotify() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.checkAndNotify() }
        }
    }

    /// Manual check (e.g. from menu item). Returns nil if already up to date.
    func checkNow() async throws -> ReleaseInfo? {
        // Respect rate limit
        if let resetDate = rateLimitResetDate, Date() < resetDate {
            throw UpdateError.rateLimited(retryAfter: resetDate)
        }

        let releasesLatestEndpoint = URL(string: "https://api.github.com/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/releases/latest")!
        var request = URLRequest(url: releasesLatestEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check rate limit headers
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 403,
               let remaining = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
               remaining == "0",
               let resetStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let resetTimestamp = TimeInterval(resetStr) {
                rateLimitResetDate = Date(timeIntervalSince1970: resetTimestamp)
                throw UpdateError.rateLimited(retryAfter: rateLimitResetDate!)
            }

            guard httpResponse.statusCode == 200 else {
                throw UpdateError.networkError(underlying: NSError(
                    domain: "HTTP", code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"]
                ))
            }
        }

        return try parseRelease(from: data)
    }

    // MARK: - Parsing

    func parseRelease(from data: Data) throws -> ReleaseInfo? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.networkError(underlying: NSError(domain: "JSON", code: 0))
        }

        guard let tagName = json["tag_name"] as? String else {
            throw UpdateError.versionParseError("missing tag_name")
        }

        guard let remoteVersion = SemVer(tagName) else {
            throw UpdateError.versionParseError(tagName)
        }

        guard let currentSemVer = SemVer(currentVersion) else {
            throw UpdateError.versionParseError(currentVersion)
        }

        // Not newer
        guard remoteVersion > currentSemVer else { return nil }

        // Find matching asset
        guard let assets = json["assets"] as? [[String: Any]] else {
            throw UpdateError.noMatchingAsset
        }

        guard let matchingAsset = assets.first(where: {
            ($0["name"] as? String)?.hasSuffix(Self.assetSuffix) == true
        }),
              let downloadURLString = matchingAsset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            throw UpdateError.noMatchingAsset
        }

        let releaseNotes = json["body"] as? String ?? ""

        var publishedAt = Date()
        if let dateStr = json["published_at"] as? String {
            let formatter = ISO8601DateFormatter()
            publishedAt = formatter.date(from: dateStr) ?? Date()
        }

        return ReleaseInfo(
            version: remoteVersion.string,
            downloadURL: downloadURL,
            releaseNotes: releaseNotes,
            publishedAt: publishedAt
        )
    }

    // MARK: - Private

    private func checkAndNotify() async {
        guard let release = try? await checkNow() else { return }
        if let skipped = skippedVersion, release.version == skipped { return }
        await MainActor.run {
            delegate?.updateChecker(self, didFindRelease: release)
        }
    }
}
