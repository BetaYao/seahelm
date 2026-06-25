import XCTest
@testable import seahelm

final class FuzzyMatchTests: XCTestCase {

    // MARK: - Basic Matching

    func testEmptyQuery_MatchesEverything() {
        XCTAssertNotNil(FuzzyMatch.score(query: "", candidate: "anything"))
    }

    func testExactMatch() {
        let score = FuzzyMatch.score(query: "main", candidate: "main")
        XCTAssertNotNil(score)
        XCTAssertTrue(score! > 0)
    }

    func testPrefixMatch() {
        let score = FuzzyMatch.score(query: "fea", candidate: "feature-branch")
        XCTAssertNotNil(score)
    }

    func testSubstringMatch() {
        let score = FuzzyMatch.score(query: "branch", candidate: "feature-branch")
        XCTAssertNotNil(score)
    }

    func testNoMatch() {
        let score = FuzzyMatch.score(query: "xyz", candidate: "main")
        XCTAssertNil(score)
    }

    func testCaseInsensitive() {
        let score = FuzzyMatch.score(query: "MAIN", candidate: "main")
        XCTAssertNotNil(score)
    }

    // MARK: - Scoring Priority

    func testPrefixScoresHigherThanMiddle() {
        let prefixScore = FuzzyMatch.score(query: "ma", candidate: "main")!
        let middleScore = FuzzyMatch.score(query: "ma", candidate: "some-main")!
        XCTAssertTrue(prefixScore > middleScore, "Prefix match should score higher")
    }

    func testExactScoresHigherThanPartial() {
        let exactScore = FuzzyMatch.score(query: "main", candidate: "main")!
        let partialScore = FuzzyMatch.score(query: "main", candidate: "main-feature-branch-long")!
        XCTAssertTrue(exactScore > partialScore, "Shorter candidate should score higher")
    }

    func testWordBoundaryBonus() {
        // "fb" should match "feature-branch" better at boundaries
        let boundaryScore = FuzzyMatch.score(query: "fb", candidate: "feature-branch")!
        let scatteredScore = FuzzyMatch.score(query: "fb", candidate: "fooooobranch")!
        XCTAssertTrue(boundaryScore > scatteredScore, "Word boundary match should score higher")
    }

    func testConsecutiveBonus() {
        let consecutiveScore = FuzzyMatch.score(query: "feat", candidate: "feature")!
        let scatteredScore = FuzzyMatch.score(query: "feat", candidate: "f-e-a-t-ure")!
        XCTAssertTrue(consecutiveScore > scatteredScore, "Consecutive match should score higher")
    }

    // MARK: - Filter

    func testFilter_ReturnsAllOnEmptyQuery() {
        let items = ["main", "feature-x", "bugfix-y"]
        let result = FuzzyMatch.filter(items, query: "") { $0 }
        XCTAssertEqual(result.count, 3)
    }

    func testFilter_FiltersNonMatching() {
        let items = ["main", "feature-x", "bugfix-y"]
        let result = FuzzyMatch.filter(items, query: "feat") { $0 }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], "feature-x")
    }

    func testFilter_RankedByScore() {
        let items = ["very-long-feature-name", "feature", "some-feature"]
        let result = FuzzyMatch.filter(items, query: "feature") { $0 }
        // "feature" (exact) should be first
        XCTAssertEqual(result[0], "feature")
    }

    func testFilter_WithKeyExtractor() {
        struct Item {
            let name: String
            let path: String
        }
        let items = [
            Item(name: "main", path: "/a"),
            Item(name: "feature-x", path: "/b"),
        ]
        let result = FuzzyMatch.filter(items, query: "feat") { $0.name }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "feature-x")
    }

    func testFilter_MultiplePartialMatches() {
        let items = ["feature-auth", "feature-api", "bugfix-login", "feature-ui"]
        let result = FuzzyMatch.filter(items, query: "feat") { $0 }
        XCTAssertEqual(result.count, 3)
        // All feature- items should match
        for item in result {
            XCTAssertTrue(item.hasPrefix("feature-"))
        }
    }

    // MARK: - Edge Cases

    func testSingleCharQuery() {
        let score = FuzzyMatch.score(query: "m", candidate: "main")
        XCTAssertNotNil(score)
    }

    func testQueryLongerThanCandidate_NoMatch() {
        let score = FuzzyMatch.score(query: "mainbranch", candidate: "main")
        XCTAssertNil(score)
    }

    func testSpecialCharacters() {
        let score = FuzzyMatch.score(query: "fix/auth", candidate: "bugfix/auth-token")
        XCTAssertNotNil(score)
    }
}
