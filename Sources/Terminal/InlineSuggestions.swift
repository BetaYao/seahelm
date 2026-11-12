import AppKit

/// Where an agent's `::seahelm-suggest:: a | b` line sits in a pane's viewport,
/// in grid cells: the marker, and each option of the card the core made of it.
struct SuggestLinePlacement: Equatable {
    struct Span: Equatable {
        let row: Int
        let column: Int
        let width: Int
    }

    let marker: Span
    /// Index for index with the card's options.
    let options: [Span]
}

/// Finds a suggestion card's line on screen. Pure: rows in, cells out.
///
/// The line is only trusted when it says exactly what the card says: every
/// option in order, separated by nothing but `|` and spaces, nothing after the
/// last. An older suggest line still on screen, one whose options differ, or
/// one cut where an option wraps, gets no buttons; the card stays answerable
/// on the island.
enum SuggestLineLocator {
    static let marker = "::seahelm-suggest::"
    /// Agents hard-wrap a long line onto the rows below it.
    static let maxContinuationRows = 3

    static func locate(options: [String], in rows: [String]) -> SuggestLinePlacement? {
        guard !options.isEmpty, !options.contains(where: \.isEmpty) else { return nil }
        // The newest line is the lowest one.
        for row in rows.indices.reversed() {
            guard let range = rows[row].range(of: marker) else { continue }
            if let placement = place(options, row: row, marker: range, rows: rows) { return placement }
        }
        return nil
    }

    private static func place(_ options: [String], row markerRow: Int, marker range: Range<String.Index>,
                              rows: [String]) -> SuggestLinePlacement? {
        let lastRow = min(rows.count - 1, markerRow + maxContinuationRows)
        var row = markerRow
        var cursor = range.upperBound
        var spans: [SuggestLinePlacement.Span] = []
        for (i, option) in options.enumerated() {
            // Between the marker and the first option only spaces; between
            // two options spaces and exactly one `|`, even across a wrap.
            let barsWanted = i == 0 ? 0 : 1
            var seen = 0
            while true {
                let line = rows[row]
                if let hit = line.range(of: option, range: cursor..<line.endIndex),
                   let gap = bars(in: line[cursor..<hit.lowerBound]), seen + gap == barsWanted {
                    spans.append(.init(row: row, column: width(line[..<hit.lowerBound]),
                                       width: width(line[hit])))
                    cursor = hit.upperBound
                    break
                }
                // Not on this row: what is left of it must be separator only,
                // and the option has to start on the next.
                guard let gap = bars(in: line[cursor...]), seen + gap <= barsWanted, row < lastRow else { return nil }
                seen += gap
                row += 1
                cursor = rows[row].startIndex
            }
        }
        // More text after the last option means more options than the card has.
        guard rows[row][cursor...].allSatisfy(\.isWhitespace) else { return nil }
        let line = rows[markerRow]
        return SuggestLinePlacement(
            marker: .init(row: markerRow, column: width(line[..<range.lowerBound]), width: width(line[range])),
            options: spans
        )
    }

    /// How many `|` a stretch of separator holds; nil if it holds anything
    /// but those and spaces.
    private static func bars(in text: Substring) -> Int? {
        guard text.allSatisfy({ $0.isWhitespace || $0 == "|" }) else { return nil }
        return text.filter { $0 == "|" }.count
    }

    static func width<S: StringProtocol>(_ text: S) -> Int {
        text.reduce(0) { $0 + GhosttyNSView.displayWidth(of: $1) }
    }
}

/// Draws each pane's suggestion card onto its `::seahelm-suggest::` line, so
/// the options can be clicked in the terminal itself. The agent's text only
/// says where; what a click does is the core's card, answered the way the
/// island answers it (`CardDeck.answer`), so nothing an agent prints can make
/// a button of its own. Main thread.
final class InlineSuggestions {
    private let deck: CardDeck
    private var timer: Timer?
    /// Stations currently showing buttons.
    private var drawn: Set<String> = []
    /// Scrolling, new output and resizes move the line without any card
    /// changing, so while a card is up its pane is looked at again this often.
    static let refreshInterval: TimeInterval = 0.5

    init(deck: CardDeck) {
        self.deck = deck
    }

    func start() {
        deck.addObserver { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        var wanted: [String: Card] = [:]
        for card in deck.cards where card.kind == .suggestion {
            guard let station = station(for: card) else { continue }
            if let held = wanted[station.id], held.createdAt > card.createdAt { continue }
            wanted[station.id] = card
        }
        for id in drawn where wanted[id] == nil {
            StationRegistry.shared.station(forId: id)?.view?.setSuggestionButtons(nil)
        }
        drawn = []
        for (id, card) in wanted {
            guard let view = StationRegistry.shared.station(forId: id)?.view else { continue }
            drawn.insert(id)
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor,
                  let rows = view.viewportRowTexts(ifContaining: SuggestLineLocator.marker),
                  let placement = SuggestLineLocator.locate(options: card.labels, in: rows) else {
                view.setSuggestionButtons(nil)
                continue
            }
            view.setSuggestionButtons(.init(cardID: card.id, placement: placement)) { [weak self] cardID, index in
                self?.answer(cardID: cardID, index: index)
            }
        }
        if wanted.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private func station(for card: Card) -> Station? {
        if !card.terminalID.isEmpty, let station = StationRegistry.shared.station(forId: card.terminalID) {
            return station
        }
        return card.paneSessionKey.isEmpty ? nil : StationRegistry.shared.station(forSessionName: card.paneSessionKey)
    }

    private func answer(cardID: String, index: Int) {
        guard let card = deck.card(id: cardID), card.labels.indices.contains(index) else { return }
        deck.answer(card, label: card.labels[index])
    }
}
