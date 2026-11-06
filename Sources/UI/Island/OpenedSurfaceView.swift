import SwiftUI

/// Expanded island: First Mate's conversation and durable card rows share one
/// timeline, with the same composer underneath. Status notifications are not
/// mirrored here.
struct OpenedSurfaceView: View {
    @Bindable var model: IslandModel
    @FocusState private var commandFocused: Bool
    @State private var menuItems: [(name: String, desc: String)] = []
    @State private var menuSel = 0
    @State private var menuTrigger: Character = "/"
    @State private var menuToken = ""
    /// Assistant rows opened past their first lines.
    @State private var expanded: Set<String> = []
    @State private var expandedTimelineRuns: Set<String> = []
    @State private var cachedItems: [ConversationItem] = []
    @State private var cachedDisplayRows: [TimelineDisplayRow] = []
    @State private var layoutTracker = TimelineLayoutTracker()
    @State private var highlightedCardID: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                // The root's header band already spans the hardware notch.
                Color.clear.frame(height: 6)

                VStack(alignment: .leading, spacing: 10) {
                    titleRow(using: proxy)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: TimelineChromeKey.self,
                                                   value: TimelineChromeValue(titleHeight: geo.size.height))
                        })
                    if let warning = model.warning {
                        warningBanner(warning.message)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: TimelineChromeKey.self,
                                                       value: TimelineChromeValue(warningHeight: geo.size.height))
                            })
                    }
                    timeline
                    composer
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: TimelineChromeKey.self,
                                                   value: TimelineChromeValue(composerHeight: geo.size.height))
                        })
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .frame(width: model.openedWidth)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.orders)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.warning)
            .onAppear {
                rebuildTimeline()
                consumePrefill()
                consumeFocusRequest()
                performRequestedScroll(using: proxy)
            }
            .onChange(of: model.timelineRevision) { rebuildTimeline() }
            .onChange(of: model.isFilteringTimeline) { rebuildDisplayRows() }
            .onChange(of: model.pendingCommandPrefill) { consumePrefill() }
            .onChange(of: model.pendingCommandFocus) { consumeFocusRequest() }
            .onChange(of: model.timelineScrollRequest) { performRequestedScroll(using: proxy) }
            .onPreferenceChange(TimelineChromeKey.self) { value in
                let warningHeight = model.warning == nil ? 0 : value.warningHeight + 10
                model.measuredTimelineChromeHeight = 6 + value.titleHeight + warningHeight
                    + (model.warning == nil ? 20 : 30) + value.composerHeight + 14
            }
        }
    }

    /// The control channel is the island's supply line. With it down, the rows
    /// below are the last thing seahelm heard rather than the current state —
    /// say so, instead of letting a stale-but-plausible list stand.
    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Timeline

    private var maxTimelineHeight: CGFloat {
        max(IslandModel.minimumTimelineHeight,
            model.maxOpenedContentHeight - model.measuredTimelineChromeHeight)
    }

    private func titleRow(using proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Text("⎈").font(.system(size: 13)).foregroundStyle(IslandStyle.accent)
            Text("First Mate")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Circle().fill(toneColor).frame(width: 6, height: 6)
            Text(model.mateActivity)
                .font(.system(size: 11))
                .foregroundStyle(toneColor)
            Spacer(minLength: 0)
            if model.mateBusy {
                pill(model.language.stop, systemImage: "stop.fill", tint: .white.opacity(0.75)) { model.onInterruptFirstMate?() }
            }
            if model.shouldShowTimelineFilter {
                filterPill {
                    let turningOn = !model.isFilteringTimeline
                    let anchor = nearestCardID(in: cachedItems, filtering: turningOn)
                        ?? nearestCardID(in: cachedItems, filtering: model.isFilteringTimeline)
                    let viewportHeight = layoutTracker.viewportHeight
                    let oldCenter = anchor.flatMap { layoutTracker.cardCenters[$0] } ?? viewportHeight / 2
                    let anchorY = min(max(oldCenter / max(viewportHeight, 1), 0.08), 0.92)
                    model.toggleTimelineFilter()
                    if let anchor {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("card:\(anchor)", anchor: UnitPoint(x: 0.5, y: anchorY))
                        }
                    }
                }
            }
        }
    }

    private func filterPill(action: @escaping () -> Void) -> some View {
        let tint: Color = model.isFilteringTimeline ? IslandStyle.accent : .yellow
        return HStack(spacing: 4) {
            Image(systemName: model.isFilteringTimeline ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 9, weight: .bold))
            Text(model.language.todoCount(model.pendingCardCount))
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(model.isFilteringTimeline ? Color.black.opacity(0.88) : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(model.isFilteringTimeline ? 0.95 : 0.14)))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .accessibilityIdentifier("island.timeline.filter")
    }

    private func nearestCardID(in items: [ConversationItem], filtering: Bool) -> String? {
        let liveCards = Dictionary(model.orders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let cards = items.compactMap { item -> (String, CGFloat)? in
            guard case let .card(entry) = item.kind else { return nil }
            if filtering, entry.effectiveState(liveCard: liveCards[entry.id]) != .pending { return nil }
            guard let center = layoutTracker.cardCenters[entry.id] else { return nil }
            return (entry.id, center)
        }
        return cards.min { lhs, rhs in
            abs(lhs.1 - layoutTracker.viewportHeight / 2) < abs(rhs.1 - layoutTracker.viewportHeight / 2)
        }?.0
    }

    private var toneColor: Color {
        switch model.mateTone {
        case .quiet: return .white.opacity(0.4)
        case .watching: return IslandStyle.accent
        case .working: return .green
        case .wantsYou: return .yellow
        }
    }

    private func pill(_ title: String, systemImage: String?, tint: Color, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(title).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .contentShape(Capsule())
        // onTapGesture, not Button: a Button in a non-activating panel swallows
        // the first click for key acquisition.
        .onTapGesture(perform: action)
    }

    /// First Mate's column: everything it says sits right of the event icons.
    private static let gutter: CGFloat = 26

    private var timeline: some View {
        let items = cachedItems
        let displayRows = cachedDisplayRows
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 7) {
                if items.isEmpty {
                    Text(model.mateRunning ? model.language.nothingSaidYet : model.language.firstMateOff)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.vertical, 8)
                }
                ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, displayRow in
                    timelineRow(displayRow)
                        .padding(.top, index > 0 && displayRow.startsSection ? 12 : 0)
                }
                Color.clear.frame(height: 1).id("timeline-bottom")
            }
            .padding(.vertical, 4)
            .background(GeometryReader { geo in
                Color.clear.preference(key: TimelineLayoutKey.self,
                                       value: TimelineLayoutValue(contentHeight: geo.size.height))
            })
        }
        .coordinateSpace(name: "island.timeline")
        .overlay(GeometryReader { geo in
            Color.clear.preference(key: TimelineLayoutKey.self,
                                   value: TimelineLayoutValue(viewportHeight: geo.size.height))
        })
        .frame(height: model.cachedListHeight > 0
               ? min(model.cachedListHeight, maxTimelineHeight)
               : min(180, maxTimelineHeight))
        .onPreferenceChange(TimelineLayoutKey.self) { value in
            if value.contentHeight > 0, model.cachedListHeight != value.contentHeight {
                model.cachedListHeight = value.contentHeight
            }
            layoutTracker.record(value)
        }
    }

    private func rebuildTimeline() {
        cachedItems = ConversationItem.items(from: model.mateMessages, liveCards: model.orders,
                                             sourceLabels: model.liveCardSourceLabels)
        rebuildDisplayRows()
    }

    private func rebuildDisplayRows() {
        cachedDisplayRows = Self.timelineRows(from: cachedItems, filtering: model.isFilteringTimeline,
                                              liveCards: model.orders)
    }

    @ViewBuilder
    private func timelineRow(_ displayRow: TimelineDisplayRow) -> some View {
        switch displayRow.kind {
        case .item(let item):
            timelineItem(item)
        case .collapsedMessages(let items):
            VStack(alignment: .leading, spacing: 6) {
                collapsedToggle(displayRow.id,
                                title: model.language.hiddenMessages(items.reduce(0) { $0 + $1.messageCount }),
                                expanded: expandedTimelineRuns.contains(displayRow.id))
                if expandedTimelineRuns.contains(displayRow.id) {
                    ForEach(items, id: \.scrollID) { timelineItem($0) }
                }
            }
        case .moreSuggestions(let items):
            VStack(alignment: .leading, spacing: 6) {
                collapsedToggle(displayRow.id,
                                title: model.language.moreSuggestions(items.count),
                                expanded: expandedTimelineRuns.contains(displayRow.id))
                if expandedTimelineRuns.contains(displayRow.id) {
                    ForEach(items, id: \.scrollID) { timelineItem($0) }
                }
            }
        }
    }

    private func collapsedToggle(_ id: String, title: String, expanded isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Text(isExpanded ? "···" : title)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
            if isExpanded {
                Text(model.language.collapse)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
            }
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded { expandedTimelineRuns.remove(id) }
                else { expandedTimelineRuns.insert(id) }
            }
        }
        .accessibilityIdentifier("island.timeline.expand.\(id)")
    }

    @ViewBuilder
    private func timelineItem(_ item: ConversationItem) -> some View {
        row(item)
            .id(item.scrollID)
            .background {
                if case let .card(entry) = item.kind {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TimelineLayoutKey.self,
                            value: TimelineLayoutValue(cardCenters: [entry.id: geo.frame(in: .named("island.timeline")).midY])
                        )
                    }
                }
            }
            .background {
                if case let .card(entry) = item.kind, highlightedCardID == entry.id {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(IslandStyle.accent.opacity(0.08))
                }
            }
            .overlay {
                if case let .card(entry) = item.kind, highlightedCardID == entry.id {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(IslandStyle.accent.opacity(0.8), lineWidth: 1.5)
                }
            }
    }

    private func performRequestedScroll(using proxy: ScrollViewProxy) {
        let target = model.timelineScrollTarget ?? "timeline-bottom"
        let cardID = model.consumeTimelineHighlightCardID()
        highlightedCardID = cardID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            proxy.scrollTo(target, anchor: target == "timeline-bottom" ? .bottom : .center)
        }
        guard let cardID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlightedCardID == cardID { highlightedCardID = nil }
        }
    }

    static func timelineRows(from items: [ConversationItem], filtering: Bool,
                             liveCards: [Card]) -> [TimelineDisplayRow] {
        let liveByID = Dictionary(liveCards.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let active = items.filter { item in
            guard case let .card(entry) = item.kind, entry.cardKind == Card.Kind.suggestion.rawValue else { return true }
            return entry.effectiveState(liveCard: liveByID[entry.id]) == .pending
        }
        let suggestions = active.filter {
            if case let .card(entry) = $0.kind { return entry.cardKind == Card.Kind.suggestion.rawValue }
            return false
        }
        let recentSuggestionIDs = Set(suggestions.suffix(3).compactMap { item -> String? in
            guard case let .card(entry) = item.kind else { return nil }
            return entry.id
        })
        let olderSuggestions = suggestions.filter {
            guard case let .card(entry) = $0.kind else { return false }
            return !recentSuggestionIDs.contains(entry.id)
        }
        let olderIDs = Set(olderSuggestions.map(\.scrollID))

        var result: [TimelineDisplayRow] = []
        var hidden: [ConversationItem] = []
        var didInsertMoreSuggestions = false
        func flushHidden() {
            guard !hidden.isEmpty else { return }
            let rows = hidden
            let id = "messages:\(rows.first!.scrollID)"
            result.append(TimelineDisplayRow(id: id, kind: .collapsedMessages(rows)))
            hidden.removeAll()
        }

        for item in active {
            if olderIDs.contains(item.scrollID) {
                flushHidden()
                if !didInsertMoreSuggestions {
                    let id = "suggestions:\(olderSuggestions.first?.scrollID ?? item.scrollID)"
                    result.append(TimelineDisplayRow(id: id, kind: .moreSuggestions(olderSuggestions)))
                    didInsertMoreSuggestions = true
                }
                continue
            }

            let visible: Bool
            if !filtering {
                visible = true
            } else if case let .card(entry) = item.kind {
                visible = entry.effectiveState(liveCard: liveByID[entry.id]) == .pending
            } else {
                visible = false
            }

            if visible {
                flushHidden()
                result.append(TimelineDisplayRow(id: item.scrollID, kind: .item(item)))
            } else {
                hidden.append(item)
            }
        }
        flushHidden()
        return result
    }

    static func startsSection(_ item: ConversationItem) -> Bool {
        switch item.kind {
        case .event, .user, .brief, .card: return true
        default: return false
        }
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineSpacing(2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(IslandStyle.accent.opacity(0.2)))
                    .textSelection(.enabled)
            }
        case .assistant(let text, let tools):
            let open = expanded.contains(item.scrollID)
            let long = Self.isLongReply(text)
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.markdown(open ? text : Self.preview(text)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineSpacing(2.5)
                    .lineLimit(open ? nil : Self.replyPreviewLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if long || tools != nil {
                    HStack(spacing: 8) {
                        if long {
                            HStack(spacing: 3) {
                                Text(open ? model.language.less : model.language.more)
                                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if open { expanded.remove(item.scrollID) } else { expanded.insert(item.scrollID) }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                        if let tools {
                            Text(tools)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.28))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.leading, Self.gutter)
        case .thinking(let text):
            Text(text)
                .font(.system(size: 11).italic())
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
                .padding(.leading, Self.gutter)
        case .tools(let summary):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                Text(summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .padding(.leading, Self.gutter)
        case .note(let text):
            Text(text == "Stopped with an error" ? model.language.stoppedWithError : text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
                .padding(.leading, Self.gutter)
        case .brief(let text):
            // The core's own block, with its own icon: full width, like an event.
            briefRow(text)
        case .decision(let options):
            decisionRow(options)
                .padding(.leading, Self.gutter)
                .padding(.top, 2)
        case .event(let headline, let full, let style):
            eventHeader(id: item.scrollID, ts: item.ts, headline: headline, full: full, style: style)
        case .card(let entry):
            cardTimelineRow(entry)
        }
    }

    @ViewBuilder
    private func cardTimelineRow(_ entry: CardTimelineEntry) -> some View {
        let liveCard = model.orders.first { $0.id == entry.id }
        let state = entry.effectiveState(liveCard: liveCard)
        if state == .pending, let liveCard {
            let worktreeName = WorktreeRef.name(branch: liveCard.branch, path: liveCard.worktreePath)
            WaitingCardView(
                order: liveCard,
                language: model.language,
                sourceLabel: entry.sourceLabel.isEmpty
                    ? (model.liveCardSourceLabels[entry.id]
                        ?? (liveCard.paneSessionKey == FirstMatePane.sessionName
                            || liveCard.isFirstMates ? "First Mate"
                            : (worktreeName.isEmpty ? liveCard.project : worktreeName)))
                    : entry.sourceLabel,
                onOption: { optionText in model.onOptionTapped?(liveCard, optionText) },
                onDismiss: { model.onDismissOrder?(liveCard) },
                onReveal: { model.revealCard(liveCard) }
            )
        } else {
            Text(Self.cardSummary(entry, state: state, isChinese: model.language.isChinese))
                .font(.system(size: 10.5, weight: state == .answered ? .medium : .regular))
                .foregroundStyle(state == .answered ? .white.opacity(0.68) : .white.opacity(0.36))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, Self.gutter)
                .padding(.vertical, 2)
                .accessibilityIdentifier("island.timeline.card.\(entry.id).\(state.rawValue)")
        }
    }

    static func cardSummary(_ entry: CardTimelineEntry, state: CardTimelineState? = nil,
                            now: Date = Date(), isChinese: Bool = false) -> String {
        let finalState = state ?? entry.state
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = time(entry.updatedAt, now: now)
        switch finalState {
        case .answered:
            let option = entry.option ?? (isChinese ? "已选择" : "answered")
            let result: String
            if let via = entry.via, !via.isEmpty {
                let channel = via.lowercased() == "telegram" ? "Telegram" : via
                result = isChinese ? "✓ 在 \(channel) 选择了「\(option)」：\(text)"
                    : "✓ Chose \(option) on \(channel): \(text)"
            } else {
                result = isChinese ? "✓ 你选择了「\(option)」：\(text)" : "✓ You chose \(option): \(text)"
            }
            return stamp.isEmpty ? result : "\(result) · \(stamp)"
        case .pending, .dismissed, .expired, .gone:
            let source = entry.sourceLabel.isEmpty ? "First Mate" : entry.sourceLabel
            let status: String
            switch finalState {
            case .dismissed: status = isChinese ? "已忽略" : "dismissed"
            case .expired: status = isChinese ? "已过期" : "expired"
            case .gone, .pending: status = isChinese ? "已结束" : "no longer waiting"
            case .answered: status = ""
            }
            let result = isChinese ? "· \(source)：\(text)（\(status)）" : "· \(source): \(text) (\(status))"
            return stamp.isEmpty ? result : "\(result) · \(stamp)"
        }
    }

    /// An event as the header of what First Mate did about it: an icon in its
    /// colour, what happened, when. The text seahelm sent sits behind a tap.
    @ViewBuilder
    private func eventHeader(id: String, ts: Date, headline: String, full: String,
                             style: FirstMateEventText.Style) -> some View {
        let open = expanded.contains(id)
        let look = Self.look(style)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: look.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(look.color)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(look.color.opacity(0.16)))
                Text(headline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(Self.time(ts))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.25))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if open { expanded.remove(id) } else { expanded.insert(id) }
                }
            }
            if open {
                Text(full)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
                    .padding(.leading, Self.gutter)
            }
        }
    }

    static func look(_ style: FirstMateEventText.Style) -> (symbol: String, color: Color) {
        switch style {
        case .ciFailed: return ("xmark", Color(red: 1, green: 0.42, blue: 0.42))
        case .merged: return ("arrow.triangle.merge", Color(red: 0.69, green: 0.55, blue: 1))
        case .scheduled: return ("clock", IslandStyle.accent)
        case .outcome: return ("checkmark", Color(red: 0.4, green: 0.85, blue: 0.55))
        case .other: return ("bolt.fill", .yellow.opacity(0.85))
        }
    }

    /// "14:05" today, "Nov 4" before.
    static func time(_ date: Date, now: Date = Date()) -> String {
        guard date > .distantPast else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d"
        return f.string(from: date)
    }

    /// A folded reply: its blank lines dropped, so the preview lines carry words.
    static func preview(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    /// How many lines of a reply show before "More".
    static let replyPreviewLines = 3
    /// Cards use the same folded length as replies, but expand in their own row.
    static let cardPreviewLines = 3

    static func cardMessageNeedsExpansion(_ text: String) -> Bool {
        isLongReply(text)
    }

    /// Whether a reply runs past its preview lines (an estimate: its non-blank
    /// lines, or enough characters to wrap past them).
    static func isLongReply(_ text: String) -> Bool {
        let p = preview(text)
        return p.split(separator: "\n").count > replyPreviewLines || p.count > 160 || p.count != text.count
    }

    /// First Mate's suggestion card for these options, while it still waits.
    private func waitingCard(for options: [String]) -> Card? {
        model.orders.first { $0.paneSessionKey == FirstMatePane.sessionName && $0.options == options }
    }

    /// The choices First Mate put to the user: buttons while its card waits,
    /// quiet chips once it has been answered or dismissed.
    @ViewBuilder
    private func decisionRow(_ options: [String]) -> some View {
        let card = waitingCard(for: options)
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let live = card != nil
                let primary = live && index == 0
                Text(option)
                    .font(.system(size: 11, weight: primary ? .semibold : .medium))
                    .foregroundStyle(primary ? Color.black.opacity(0.85) : .white.opacity(live ? 0.9 : 0.38))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    // Waiting: filled, the first one in the accent. Answered: an
                    // outline, so it reads as what was offered, not a control.
                    .background(Capsule().fill(primary ? IslandStyle.accent : Color.white.opacity(live ? 0.12 : 0)))
                    .overlay(Capsule().stroke(Color.white.opacity(live ? 0 : 0.12), lineWidth: 1))
                    .contentShape(Capsule())
                    .onTapGesture {
                        guard let card else { return }
                        model.onOptionTapped?(card, card.labels.indices.contains(index) ? card.labels[index] : option)
                    }
            }
            Spacer(minLength: 0)
        }
    }

    /// The daily brief (seahelm-core's, no turn behind it): its title in
    /// the accent, each section a line of its own.
    @ViewBuilder
    private func briefRow(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "sun.horizon.fill").font(.system(size: 9)).foregroundStyle(IslandStyle.accent)
                Text(lines.first ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    /// First Mate's input: Enter sends (an IME composition commits first — the
    /// field's own Return handling), a `/command` runs as one, a failed send
    /// keeps the text for another go.
    private var composer: some View {
        VStack(spacing: 6) {
            if !menuItems.isEmpty {
                menuList.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let reply = model.commandReply {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: reply.isError ? "exclamationmark.circle.fill" : "text.alignleft")
                        .font(.system(size: 10))
                        .foregroundStyle(reply.isError ? Color.orange : Color.white.opacity(0.5))
                    ScrollView {
                        Text(Self.markdown(reply.text))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .onTapGesture { model.commandReply = nil }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            }
            if let error = model.sendError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(error).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    Text(model.language.retry)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(IslandStyle.accent)
                        .onTapGesture { send() }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                TextField(model.language.composerPlaceholder, text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($commandFocused)
                    .onChange(of: model.draft) { refreshMenu(for: model.draft) }
                    .onKeyPress(.upArrow) { moveMenuSelection(-1) }
                    .onKeyPress(.downArrow) { moveMenuSelection(1) }
                    .onKeyPress(.tab) { acceptMenuSelection() }
                    .onKeyPress(.escape) {
                        guard !menuItems.isEmpty else { return .ignored }
                        withAnimation(.easeInOut(duration: 0.15)) { menuItems = [] }
                        return .handled
                    }
                    .onSubmit {
                        // Menu open: Enter completes the token instead of sending.
                        if acceptMenuSelection() == .handled { return }
                        send()
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fieldBackground(focused: commandFocused))
            .contentShape(Rectangle())
            .onTapGesture { commandFocused = true }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: menuItems.map(\.name))
    }

    /// An agent's reply in its own inline markdown (bold, code, links), line
    /// breaks kept; as plain text when it does not parse.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func send() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if model.onSendToFirstMate?(text) == true {
            model.draft = ""
            model.sendError = nil
            model.didSendMessage()
        } else {
            model.sendError = text.hasPrefix("/") ? model.language.commandFailed : model.language.sendFailed
        }
    }

    private func fieldBackground(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(focused ? IslandStyle.accent.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
            )
    }

    private func consumePrefill() {
        guard let prefill = model.pendingCommandPrefill else { return }
        model.draft = prefill
        model.pendingCommandPrefill = nil
        DispatchQueue.main.async { commandFocused = true }
    }

    private func consumeFocusRequest() {
        guard model.pendingCommandFocus else { return }
        model.pendingCommandFocus = false
        DispatchQueue.main.async { commandFocused = true }
    }

    private var menuList: some View {
        VStack(spacing: 1) {
            ForEach(Array(menuItems.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Text(String(menuTrigger))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow.opacity(0.9))
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(item.desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(index == menuSel ? 0.14 : 0))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    menuSel = index
                    _ = acceptMenuSelection()
                }
                .onHover { inside in
                    if inside { menuSel = index }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - `/ @ #` autocomplete (mirrors the cockpit composer's semantics)

    /// Trailing `/@#`-token of the input, if any.
    private func trailingToken(_ text: String) -> (trigger: Character, query: String, token: String)? {
        var token = ""
        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let ch = text[prev]
            if ch == " " { break }
            token = String(ch) + token
            idx = prev
        }
        guard let first = token.first, "/@#".contains(first) else { return nil }
        return (first, String(token.dropFirst()).lowercased(), token)
    }

    private func refreshMenu(for text: String) {
        guard let (trigger, query, token) = trailingToken(text),
              let items = model.commandMenuProvider?(trigger, query),
              !items.isEmpty else {
            menuItems = []
            menuSel = 0
            return
        }
        menuTrigger = trigger
        menuToken = token
        menuItems = Array(items.prefix(6))
        menuSel = min(menuSel, menuItems.count - 1)
    }

    private func moveMenuSelection(_ delta: Int) -> KeyPress.Result {
        guard !menuItems.isEmpty else { return .ignored }
        menuSel = max(0, min(menuItems.count - 1, menuSel + delta))
        return .handled
    }

    @discardableResult
    private func acceptMenuSelection() -> KeyPress.Result {
        guard menuItems.indices.contains(menuSel),
              let (trigger, _, token) = trailingToken(model.draft) else { return .ignored }
        let name = menuItems[menuSel].name
        model.draft = String(model.draft.dropLast(token.count)) + String(trigger) + name + " "
        menuItems = []
        menuSel = 0
        return .handled
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Seahelm")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            // Quota rides the title row: every provider's windows at once,
            // rather than the closed pill's one-at-a-time rotation.
            ForEach(model.usageReadouts) { readout in
                UsageReadoutView(logoName: readout.logoName, segments: readout.segments)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.usageReadouts)
    }

}

struct TimelineDisplayRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case item(ConversationItem)
        case collapsedMessages([ConversationItem])
        case moreSuggestions([ConversationItem])
    }

    let id: String
    let kind: Kind

    var startsSection: Bool {
        guard case let .item(item) = kind else { return false }
        return OpenedSurfaceView.startsSection(item)
    }
}

private struct TimelineLayoutValue: Equatable {
    var cardCenters: [String: CGFloat] = [:]
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0
}

private struct TimelineLayoutKey: PreferenceKey {
    static var defaultValue = TimelineLayoutValue()
    static func reduce(value: inout TimelineLayoutValue, nextValue: () -> TimelineLayoutValue) {
        let next = nextValue()
        value.cardCenters.merge(next.cardCenters, uniquingKeysWith: { _, new in new })
        if next.viewportHeight > 0 { value.viewportHeight = next.viewportHeight }
        if next.contentHeight > 0 { value.contentHeight = next.contentHeight }
    }
}

/// Updated by scrolling preferences without invalidating OpenedSurfaceView.
/// Positions are only read by the filter-toggle action.
private final class TimelineLayoutTracker {
    var cardCenters: [String: CGFloat] = [:]
    var viewportHeight: CGFloat = 0
    private var lastRecordedAt: TimeInterval = 0

    func record(_ value: TimelineLayoutValue) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRecordedAt >= 0.1 else { return }
        lastRecordedAt = now
        if value.viewportHeight > 0 { viewportHeight = value.viewportHeight }
        if !value.cardCenters.isEmpty { cardCenters = value.cardCenters }
    }
}

private struct TimelineChromeValue: Equatable {
    var titleHeight: CGFloat = 0
    var warningHeight: CGFloat = 0
    var composerHeight: CGFloat = 0
}

private struct TimelineChromeKey: PreferenceKey {
    static var defaultValue = TimelineChromeValue()
    static func reduce(value: inout TimelineChromeValue, nextValue: () -> TimelineChromeValue) {
        let next = nextValue()
        value.titleHeight = max(value.titleHeight, next.titleHeight)
        value.warningHeight = max(value.warningHeight, next.warningHeight)
        value.composerHeight = max(value.composerHeight, next.composerHeight)
    }
}

enum IslandLanguage: String, Equatable {
    case english = "en"
    case chinese = "zh"

    var isChinese: Bool { self == .chinese }

    /// `first_mate_language` is owned by seahelm-core and intentionally stays
    /// a foreign key in the Swift Config model. Read it on startup or when the
    /// app's config-update callback fires, then cache it on IslandModel.
    static func readConfig(at url: URL = Config.configPath) -> IslandLanguage {
        fromConfigData(try? Data(contentsOf: url))
    }

    static func fromConfigData(_ data: Data?) -> IslandLanguage {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["first_mate_language"] as? String else { return .english }
        return value == "zh" ? .chinese : .english
    }

    var stop: String { isChinese ? "停止" : "Stop" }
    var retry: String { isChinese ? "重试" : "Retry" }
    var more: String { isChinese ? "更多" : "More" }
    var less: String { isChinese ? "收起" : "Less" }
    var collapse: String { isChinese ? "收起" : "Collapse" }
    var composerPlaceholder: String { isChinese ? "问问 First Mate — 输入 / 查看命令" : "Ask First Mate — / for a command" }
    var nothingSaidYet: String { isChinese ? "还没有消息。可以问 First Mate 任何问题，`/命令` 会直接运行。" : "Nothing said yet. Ask First Mate anything — a `/command` runs as one." }
    var firstMateOff: String { isChinese ? "First Mate 尚未启用。可在“设置 ▸ First Mate”中开启。" : "First Mate is off. Turn it on in Settings ▸ First Mate." }
    var commandFailed: String { isChinese ? "命令未能运行。" : "That command did not run." }
    var sendFailed: String { isChinese ? "First Mate 未收到消息——确认它正在运行。" : "First Mate did not get it — is it running?" }
    var stoppedWithError: String { isChinese ? "因错误而停止" : "Stopped with an error" }
    var integration: String { isChinese ? "集成" : "integration" }
    func todoCount(_ count: Int) -> String { isChinese ? "待办 \(count)" : "To-do \(count)" }
    func hiddenMessages(_ count: Int) -> String { isChinese ? "··· \(count) 条消息" : "··· \(count) messages" }
    func moreSuggestions(_ count: Int) -> String { isChinese ? "更多建议（\(count)）" : "More suggestions (\(count))" }
}

/// One display item in First Mate's timeline: conversation content or a merged
/// card row. Turn edges are left out — the title row's status says whether it
/// is working.
struct ConversationItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        /// A reply, with the tool calls that led to it folded in ("Bash ×3 ·
        /// Read", nil for none): they are how it got there, not something to
        /// read line by line.
        case assistant(String, tools: String?)
        case thinking(String)
        /// Tool calls with no reply after them yet: the turn is still going.
        case tools(String)
        case note(String)
        /// First Mate's daily brief: a title, then a line per section.
        case brief(String)
        /// Choices First Mate put to the user (its suggestion): drawn as
        /// buttons while the card is still waiting, under the reply they go with.
        case decision([String])
        /// What seahelm itself handed First Mate (`[seahelm event] …`, an
        /// approval's outcome): a section header that reads as what happened,
        /// the whole text behind a tap.
        case event(headline: String, full: String, style: FirstMateEventText.Style)
        case card(CardTimelineEntry)
    }

    let id: UInt64
    let kind: Kind
    let ts: Date
    let scrollID: String
    let messageCount: Int

    init(id: UInt64, kind: Kind, ts: Date = .distantPast, scrollID: String? = nil, messageCount: Int = 1) {
        self.id = id; self.kind = kind; self.ts = ts
        self.scrollID = scrollID ?? "event:\(id)"
        self.messageCount = messageCount
    }

    static func items(from messages: [MessageEvent], liveCards: [Card] = [],
                      sourceLabels: [String: String] = [:]) -> [ConversationItem] {
        let orderedMessages = messages.sorted { $0.seq < $1.seq }
        var cardEntries = CardTimelineEntry.merged(from: orderedMessages)
        let firstMateDecisionOptions = cardEntries
            .filter { $0.sourcePane == FirstMatePane.sessionName || $0.sourceLabel == "First Mate" }
            .map(\.options)
            + liveCards.filter { $0.paneSessionKey == FirstMatePane.sessionName }.map(\.options)
        let rowCardIDs = Set(cardEntries.map(\.id))
        var nextSequence = orderedMessages.map(\.seq).max() ?? 0
        let fallbackCards = liveCards.filter { !rowCardIDs.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        for card in fallbackCards {
            nextSequence &+= 1
            let isFirstMate = card.paneSessionKey == FirstMatePane.sessionName || card.isFirstMates
            let worktreeName = WorktreeRef.name(branch: card.branch, path: card.worktreePath)
            let sourceLabel = isFirstMate ? "First Mate"
                : (sourceLabels[card.id] ?? (worktreeName.isEmpty ? card.project : worktreeName))
            cardEntries.append(CardTimelineEntry(
                id: card.id, sequence: nextSequence, createdAt: card.createdAt, updatedAt: card.createdAt,
                cardKind: card.kind.rawValue, sourcePane: card.paneSessionKey,
                sourceLabel: sourceLabel,
                text: card.message, options: card.options, state: .pending, option: nil, via: nil
            ))
        }
        let entriesByFirstSequence = Dictionary(cardEntries.map { ($0.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        var insertedCardIDs: Set<String> = []
        var out: [ConversationItem] = []
        var run: [(tool: String, count: Int)] = []
        var runId: UInt64 = 0
        var runTs = Date.distantPast
        var summary: String? {
            run.isEmpty ? nil : run.map { $0.count > 1 ? "\($0.tool) ×\($0.count)" : $0.tool }.joined(separator: " · ")
        }
        /// A suggestion is recorded before the reply it closes, so it waits for
        /// that reply and goes under it.
        var held: ConversationItem?
        func flush() {
            if let held { out.append(held) }
            held = nil
        }
        /// Something other than a reply ends the run: its calls led to no
        /// reply of their own, so they are dropped.
        func dropRun() { run = [] }
        for m in orderedMessages {
            let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let item = { (kind: Kind) in ConversationItem(id: m.seq, kind: kind, ts: m.ts) }
            switch m.kind {
            case .card:
                if let entry = entriesByFirstSequence[m.seq], insertedCardIDs.insert(entry.id).inserted {
                    out.append(ConversationItem(id: entry.sequence, kind: .card(entry), ts: entry.createdAt,
                                                scrollID: "card:\(entry.id)"))
                }
                continue
            case .tool:
                guard let tool = m.tool, !tool.isEmpty else { continue }
                if run.isEmpty { runId = m.seq; runTs = m.ts }
                if run.last?.tool == tool { run[run.count - 1].count += 1 } else { run.append((tool, 1)) }
                continue
            case .user where text.hasPrefix("[seahelm"):
                dropRun(); flush()
                let parsed = FirstMateEventText.parse(text)
                out.append(item(.event(headline: parsed.headline, full: text, style: parsed.style)))
            case .user where !text.isEmpty:
                dropRun(); flush(); out.append(item(.user(text)))
            case .assistant where !text.isEmpty:
                out.append(ConversationItem(id: m.seq, kind: .assistant(text, tools: summary), ts: m.ts,
                                            messageCount: 1 + run.reduce(0) { $0 + $1.count }))
                run = []
                flush()
            case .thinking where !text.isEmpty:
                out.append(item(.thinking(text)))
            case .note where !text.isEmpty:
                dropRun(); flush(); out.append(item(.note(text)))
            case .brief where !text.isEmpty:
                dropRun(); flush(); out.append(item(.brief(text)))
            // Notices ("Claude is waiting for your input") say what the title's
            // status already does, once per turn: left out.
            case .decision where !text.isEmpty:
                dropRun(); flush()
                let options = text.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if firstMateDecisionOptions.contains(options) { continue }
                if options.count > 1 { held = item(.decision(options)) } else { out.append(item(.note(text))) }
            case .status where m.status == AgentStatus.error.rawValue:
                dropRun(); flush(); out.append(item(.note("Stopped with an error")))
            default:
                continue
            }
        }
        // Calls with nothing after them: the turn is still under way.
        if let summary {
            out.append(ConversationItem(id: runId, kind: .tools(summary), ts: runTs,
                                        messageCount: run.reduce(0) { $0 + $1.count }))
        }
        flush()
        for entry in cardEntries where !insertedCardIDs.contains(entry.id) {
            out.append(ConversationItem(id: entry.sequence, kind: .card(entry), ts: entry.createdAt,
                                        scrollID: "card:\(entry.id)"))
        }
        return out
    }
}

/// Reads the messages seahelm hands First Mate. Pure.
enum FirstMateEventText {
    /// What kind of thing happened, for the header's icon and colour.
    enum Style: Equatable {
        case ciFailed, merged, scheduled
        /// seahelm telling First Mate how the user answered (an approval).
        case outcome
        case other
    }

    static func parse(_ text: String) -> (headline: String, style: Style) {
        let first = text.components(separatedBy: "\n").first ?? text
        let style: Style
        if first.hasPrefix("[seahelm event] ci.failed") { style = .ciFailed }
        else if first.hasPrefix("[seahelm event] pr.merged") { style = .merged }
        else if first.hasPrefix("[seahelm event] schedule") { style = .scheduled }
        else if first.hasPrefix("[seahelm] ") { style = .outcome }
        else { style = .other }
        return (headline(text), style)
    }

    /// `[seahelm event] pr.merged · rule cleanup-merged` + `PR: #12 …` reads
    /// "PR #12 merged": what happened and to what, not the rule plumbing
    /// (that stays in the full text). Anything else keeps its first line,
    /// without the `[seahelm …]` tag.
    static func headline(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let first = lines.first ?? text
        let tag = "[seahelm event] "
        guard first.hasPrefix(tag) else {
            return first.replacingOccurrences(of: "[seahelm] ", with: "")
        }
        let header = String(first.dropFirst(tag.count))
        let parts = header.components(separatedBy: " · rule ")
        let event = parts.first ?? header
        let rule = parts.count > 1 ? parts[1] : ""
        let number = pr(in: lines)
        let onBranch = branch(in: lines)
        switch event {
        case "ci.failed":
            if let number { return "CI failed · PR #\(number)" }
            return onBranch.map { "CI failed · \($0)" } ?? "CI failed"
        case "pr.merged":
            if let number { return "PR #\(number) merged" }
            return onBranch.map { "PR merged · \($0)" } ?? "PR merged"
        case "schedule":
            return rule.isEmpty ? "Scheduled run" : "Scheduled · \(rule)"
        default:
            return header
        }
    }

    /// `PR: #12 https://… — …`
    private static func pr(in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix("PR: #") }) else { return nil }
        let digits = line.dropFirst("PR: #".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    /// `worktree: /w (branch x)`
    private static func branch(in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix("worktree: ") }),
              let open = line.range(of: "(branch "), line.hasSuffix(")") else { return nil }
        let name = line[open.upperBound..<line.index(before: line.endIndex)]
        return name.isEmpty ? nil : String(name)
    }
}

/// A pending card rendered whole with source, message and live option chips.
private struct WaitingCardView: View {
    let order: Card
    let language: IslandLanguage
    let sourceLabel: String
    let onOption: (String) -> Void
    let onDismiss: () -> Void
    /// Card content tap: jump to the raising pane without resolving the card.
    let onReveal: () -> Void
    @State private var messageExpanded = false

    private var isQuestion: Bool {
        order.isAgentQuestion
    }
    /// An integration round, which belongs to a repo rather than to a pane:
    /// no agent raised it and there is no branch behind it.
    private var isIntegration: Bool {
        order.kind == .report
    }

    private var icon: String {
        if isIntegration { return "arrow.triangle.merge" }
        return isQuestion ? "questionmark.circle.fill" : "lightbulb.fill"
    }

    private var isSuggestion: Bool { order.kind == .suggestion }

    private var optionStyle: IslandCardOptionStyle {
        IslandCardOptionStyle.forKind(order.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isIntegration ? .orange : (isSuggestion ? .white.opacity(0.5) : .yellow))
                    Text(sourceLabel.isEmpty ? order.project : sourceLabel)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSuggestion ? .white.opacity(0.58) : .white.opacity(0.82))
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isSuggestion ? Color.white.opacity(0.055) : IslandStyle.accent.opacity(0.15)))
                        .overlay(Capsule().stroke(isSuggestion ? Color.white.opacity(0.12) : IslandStyle.accent.opacity(0.28), lineWidth: 0.7))
                        .contentShape(Capsule())
                }
                Spacer(minLength: 0)
                // onTapGesture, not Button: SwiftUI Buttons in a non-activating
                // panel swallow the click for key acquisition.
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { onDismiss() })
            }
            if isQuestion, !order.header.isEmpty {
                // The question's tab title in the agent's dialog.
                Text(order.header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, -4)
            }
            if !order.message.isEmpty {
                let needsExpansion = OpenedSurfaceView.cardMessageNeedsExpansion(order.message)
                VStack(alignment: .leading, spacing: 4) {
                    Text(messageExpanded ? order.message : OpenedSurfaceView.preview(order.message))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(isSuggestion ? 0.72 : 0.92))
                        .lineSpacing(1.5)
                        .lineLimit(messageExpanded ? nil : OpenedSurfaceView.cardPreviewLines)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { onReveal() }
                    if needsExpansion {
                        HStack(spacing: 3) {
                            Text(messageExpanded ? language.less : language.more)
                            Image(systemName: messageExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(isSuggestion ? 0.44 : 0.58))
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded {
                            withAnimation(.easeInOut(duration: 0.15)) { messageExpanded.toggle() }
                        })
                    }
                }
            }
            OptionList(options: order.labels,
                       details: order.labels.indices.map { order.detail(forLabelAt: $0) },
                       style: optionStyle,
                       onTap: onOption)
        }
        .padding(12)
        .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onReveal() }
        .opacity(isSuggestion ? 0.84 : 1)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSuggestion ? Color.white.opacity(0.025) : IslandStyle.accent.opacity(0.085))
            .overlay(alignment: .leading) {
                if !isSuggestion {
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                        .fill(IslandStyle.accent)
                        .frame(width: 3)
                }
            }
            .overlay {
                if isSuggestion {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Color.white.opacity(0.16))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(IslandStyle.accent.opacity(0.38), lineWidth: 1)
                }
            }
    }
}

/// Options as full-width rows, top to bottom, each with a numbered badge.
private struct OptionList: View {
    let options: [String]
    /// A line under each option ("" for none), as the agent's dialog shows it.
    var details: [String] = []
    let style: IslandCardOptionStyle
    let onTap: (String) -> Void
    @State private var hoveredIndex: Int?

    var body: some View {
        Group {
            if style == .compactChips {
                IslandFlowLayout(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Text(option)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                            .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
                            .contentShape(Capsule())
                            .highPriorityGesture(TapGesture().onEnded { onTap(option) })
                            .accessibilityIdentifier("island.card.option.chip")
                    }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 18, height: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.white.opacity(0.14))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if details.indices.contains(index), !details[index].isEmpty {
                                    Text(details[index])
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(hoveredIndex == index ? 0.18 : 0.08))
                        )
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded { onTap(option) })
                        .onHover { inside in
                            withAnimation(.easeInOut(duration: 0.12)) {
                                hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A compact row of suggestion chips that wraps without introducing a nested
/// scroll view, so the pointer wheel always belongs to the timeline.
private struct IslandFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let placement = positions(for: subviews, width: width)
        return CGSize(width: min(placement.width, width), height: placement.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = positions(for: subviews, width: bounds.width)
        for (index, point) in placement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func positions(for subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (points, usedWidth, subviews.isEmpty ? 0 : y + rowHeight)
    }
}
