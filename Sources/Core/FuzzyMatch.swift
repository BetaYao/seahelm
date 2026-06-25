import Foundation

enum FuzzyMatch {
    /// Score a candidate string against a query using fuzzy matching.
    /// Returns nil if no match, or a score (higher = better match).
    /// Prefers: exact prefix > word boundary matches > consecutive chars > scattered chars.
    static func score(query: String, candidate: String) -> Int? {
        let q = query.lowercased()
        let c = candidate.lowercased()

        guard !q.isEmpty else { return 1 } // Empty query matches everything

        var queryIdx = q.startIndex
        var candidateIdx = c.startIndex
        var score = 0
        var consecutive = 0
        var lastMatchIdx: String.Index?

        while queryIdx < q.endIndex && candidateIdx < c.endIndex {
            if q[queryIdx] == c[candidateIdx] {
                score += 1

                // Bonus for consecutive matches
                if let last = lastMatchIdx, c.index(after: last) == candidateIdx {
                    consecutive += 1
                    score += consecutive * 2
                } else {
                    consecutive = 0
                }

                // Bonus for match at start
                if candidateIdx == c.startIndex {
                    score += 10
                }

                // Bonus for match after separator (/, -, _)
                if candidateIdx > c.startIndex {
                    let prev = c[c.index(before: candidateIdx)]
                    if prev == "/" || prev == "-" || prev == "_" || prev == " " {
                        score += 5
                    }
                }

                lastMatchIdx = candidateIdx
                queryIdx = q.index(after: queryIdx)
            }
            candidateIdx = c.index(after: candidateIdx)
        }

        // All query chars must be found
        guard queryIdx == q.endIndex else { return nil }

        // Bonus for shorter candidates (tighter match)
        score += max(0, 50 - candidate.count)

        return score
    }

    /// Filter and rank items by fuzzy matching against a query.
    static func filter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        guard !query.isEmpty else { return items }

        return items
            .compactMap { item -> (T, Int)? in
                guard let s = score(query: query, candidate: key(item)) else { return nil }
                return (item, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
