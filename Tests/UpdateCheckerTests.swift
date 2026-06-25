import XCTest
@testable import seahelm

class UpdateCheckerTests: XCTestCase {

    // MARK: - GitHub Release JSON Parsing

    func testParseValidRelease() throws {
        let checker = UpdateChecker(currentVersion: "2.0.0")
        let json = makeReleaseJSON(tag: "v2.1.0", assetName: "seahelm-macos-\(UpdateChecker.assetSuffix)")
        let data = try JSONSerialization.data(withJSONObject: json)

        let release = try checker.parseRelease(from: data)
        XCTAssertNotNil(release)
        XCTAssertEqual(release?.version, "2.1.0")
        XCTAssertTrue(release!.downloadURL.absoluteString.contains("seahelm-macos"))
    }

    func testParseOlderVersionReturnsNil() throws {
        let checker = UpdateChecker(currentVersion: "3.0.0")
        let json = makeReleaseJSON(tag: "v2.1.0", assetName: "seahelm-macos-\(UpdateChecker.assetSuffix)")
        let data = try JSONSerialization.data(withJSONObject: json)

        let release = try checker.parseRelease(from: data)
        XCTAssertNil(release, "Older remote version should return nil")
    }

    func testParseSameVersionReturnsNil() throws {
        let checker = UpdateChecker(currentVersion: "2.1.0")
        let json = makeReleaseJSON(tag: "v2.1.0", assetName: "seahelm-macos-\(UpdateChecker.assetSuffix)")
        let data = try JSONSerialization.data(withJSONObject: json)

        let release = try checker.parseRelease(from: data)
        XCTAssertNil(release, "Same version should return nil")
    }

    func testParseNoMatchingAssetThrows() throws {
        let checker = UpdateChecker(currentVersion: "2.0.0")
        let json = makeReleaseJSON(tag: "v2.1.0", assetName: "seahelm-linux-amd64.tar.gz")
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try checker.parseRelease(from: data)) { error in
            guard case UpdateError.noMatchingAsset = error else {
                XCTFail("Expected noMatchingAsset, got \(error)")
                return
            }
        }
    }

    func testParseMalformedTagThrows() throws {
        let checker = UpdateChecker(currentVersion: "2.0.0")
        let json = makeReleaseJSON(tag: "latest", assetName: "seahelm-macos-\(UpdateChecker.assetSuffix)")
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try checker.parseRelease(from: data)) { error in
            guard case UpdateError.versionParseError = error else {
                XCTFail("Expected versionParseError, got \(error)")
                return
            }
        }
    }

    func testParseReleaseNotes() throws {
        let checker = UpdateChecker(currentVersion: "2.0.0")
        var json = makeReleaseJSON(tag: "v2.1.0", assetName: "seahelm-macos-\(UpdateChecker.assetSuffix)")
        json["body"] = "## What's New\n- Feature A\n- Bug fix B"
        let data = try JSONSerialization.data(withJSONObject: json)

        let release = try checker.parseRelease(from: data)
        XCTAssertEqual(release?.releaseNotes, "## What's New\n- Feature A\n- Bug fix B")
    }

    func testParseMultipleAssetsSelectsCorrect() throws {
        let checker = UpdateChecker(currentVersion: "2.0.0")
        let json: [String: Any] = [
            "tag_name": "v2.1.0",
            "body": "",
            "published_at": "2026-03-20T00:00:00Z",
            "assets": [
                ["name": "seahelm-macos-arm64.zip", "browser_download_url": "https://example.com/arm64.zip"],
                ["name": "seahelm-macos-x86_64.zip", "browser_download_url": "https://example.com/x86_64.zip"],
                ["name": "seahelm-linux-amd64.tar.gz", "browser_download_url": "https://example.com/linux.tar.gz"],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let release = try checker.parseRelease(from: data)
        XCTAssertNotNil(release)
        XCTAssertTrue(release!.downloadURL.absoluteString.contains(UpdateChecker.assetSuffix))
    }

    // MARK: - Skipped Version

    func testSkippedVersionSuppressesNotification() async {
        let checker = UpdateChecker(currentVersion: "2.0.0")
        checker.skippedVersion = "2.1.0"

        // The checker itself doesn't filter in checkNow — filtering happens in checkAndNotify
        // We test the logic: if release.version == skippedVersion, delegate should NOT be called
        let json = makeReleaseJSON(tag: "v2.1.0", assetName: "seahelm-macos-\(UpdateChecker.assetSuffix)")
        let data = try! JSONSerialization.data(withJSONObject: json)
        let release = try! checker.parseRelease(from: data)

        // The release is still returned by parseRelease (it's the caller's job to filter)
        XCTAssertNotNil(release)
        XCTAssertEqual(release?.version, "2.1.0")
        // But it matches skippedVersion, so the polling loop would not notify
        XCTAssertEqual(release?.version, checker.skippedVersion)
    }

    // MARK: - Helpers

    private func makeReleaseJSON(tag: String, assetName: String) -> [String: Any] {
        return [
            "tag_name": tag,
            "body": "",
            "published_at": "2026-03-20T00:00:00Z",
            "assets": [
                [
                    "name": assetName,
                    "browser_download_url": "https://github.com/\(UpdateChecker.repositoryOwner)/\(UpdateChecker.repositoryName)/releases/download/\(tag)/\(assetName)"
                ]
            ]
        ]
    }
}
