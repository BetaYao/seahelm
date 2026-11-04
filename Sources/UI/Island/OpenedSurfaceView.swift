import SwiftUI

/// Expanded island (docs/superpowers/specs/2026-11-04-first-mate-surfaces-design.md):
/// the usage bar on top, then one of two pages — the cards waiting on the user
/// with an entry to First Mate pinned under them, or First Mate's conversation
/// with its composer. Status notifications are not mirrored here.
struct OpenedSurfaceView: View {
    @Bindable var model: IslandModel
    @FocusState private var commandFocused: Bool
    @State private var menuItems: [(name: String, desc: String)] = []
    @State private var menuSel = 0
    @State private var menuTrigger: Character = "/"
    @State private var menuToken = ""
    /// Assistant rows opened past their first lines.
    @State private var expanded: Set<UInt64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The root's header band already spans the hardware notch; just
            // leave breathing room below it.
            Color.clear.frame(height: 6)

            VStack(alignment: .leading, spacing: 10) {
                header
                if let warning = model.controlChannelWarning {
                    controlChannelBanner(warning)
                }
                switch model.page {
                case .suggestions:
                    suggestionsTitle
                    cardList
                    conversationEntry
                case .conversation:
                    conversationTitle
                    conversation
                    composer
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: model.openedWidth)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.orders)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.page)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.controlChannelWarning)
        .onAppear { consumePrefill(); consumeFocusRequest() }
        .onChange(of: model.pendingCommandPrefill) { consumePrefill() }
        .onChange(of: model.pendingCommandFocus) { consumeFocusRequest() }
    }

    /// The control channel is the island's supply line. With it down, the rows
    /// below are the last thing seahelm heard rather than the current state —
    /// say so, instead of letting a stale-but-plausible list stand.
    private func controlChannelBanner(_ text: String) -> some View {
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

    // MARK: - Suggestions

    private static let maxListHeight: CGFloat = 380

    private var suggestionsTitle: some View {
        HStack(spacing: 8) {
            Text("⎈").font(.system(size: 13)).foregroundStyle(IslandStyle.accent)
            Text("First Mate")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            Text("\(model.orders.count) waiting for you")
                .font(.system(size: 11))
                .foregroundStyle(.yellow.opacity(0.85))
        }
    }

    /// Scrolls inside itself past the cap; the entry under it stays put.
    private var cardList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.orders) { order in
                    SuggestionCard(order: order,
                                   onOption: { optionText in model.onOptionTapped?(order, optionText) },
                                   onDismiss: { model.onDismissOrder?(order) },
                                   onReveal: {
                                       model.onRevealSuggestion?(order)
                                       model.close()
                                   })
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
            })
        }
        .frame(height: model.cachedListHeight > 0 ? min(model.cachedListHeight, Self.maxListHeight) : nil)
        .onPreferenceChange(ListHeightKey.self) { height in
            // Ignore the 0 that fires as this view goes; it would wipe the cache.
            if height > 0 { model.cachedListHeight = height }
        }
    }

    /// Not a field: a way into the conversation. The cards stay where they are.
    private var conversationEntry: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IslandStyle.accent.opacity(0.8))
            Text(model.draft.isEmpty ? "Hand it to First Mate…" : model.draft)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(model.draft.isEmpty ? 0.45 : 0.85))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(fieldBackground(focused: false))
        .contentShape(Rectangle())
        .onTapGesture {
            model.page = .conversation
            DispatchQueue.main.async { commandFocused = true }
        }
    }

    // MARK: - Conversation

    private var conversationTitle: some View {
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
                pill("Stop", systemImage: "stop.fill", tint: .white.opacity(0.75)) { model.onInterruptFirstMate?() }
            }
            if !model.orders.isEmpty {
                pill("Suggestions \(model.orders.count)", systemImage: nil, tint: .yellow) { model.page = .suggestions }
            }
        }
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

    private var conversation: some View {
        let items = ConversationItem.items(from: model.mateMessages)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if items.isEmpty {
                        Text(model.mateRunning ? "Nothing said yet. Ask First Mate anything — a `/command` runs as one."
                                               : "First Mate is off. Turn it on in Settings ▸ First Mate.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.vertical, 8)
                    }
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: Self.maxListHeight * 0.85)
            .onAppear { proxy.scrollTo(items.last?.id, anchor: .bottom) }
            .onChange(of: items.last?.id) { proxy.scrollTo(items.last?.id, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ item: ConversationItem) -> some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(IslandStyle.accent.opacity(0.22)))
                    .textSelection(.enabled)
            }
        case .assistant(let text):
            let open = expanded.contains(item.id)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.markdown(text))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(open ? nil : 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if text.count > 600 || text.split(separator: "\n").count > 10 {
                    Text(open ? "Show less" : "Show more")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandStyle.accent.opacity(0.8))
                        .onTapGesture {
                            if open { expanded.remove(item.id) } else { expanded.insert(item.id) }
                        }
                }
            }
        case .thinking(let text):
            Text(text)
                .font(.system(size: 11).italic())
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(2)
        case .tools(let summary):
            Text("› " + summary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        case .note(let text):
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
        case .event(let headline, let full):
            let open = expanded.contains(item.id)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.yellow.opacity(0.75))
                    Text(headline)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if open {
                    Text(full)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.04)))
            .contentShape(Rectangle())
            .onTapGesture {
                if open { expanded.remove(item.id) } else { expanded.insert(item.id) }
            }
        }
    }

    /// First Mate's input: Enter sends (an IME composition commits first — the
    /// field's own Return handling), a `/command` runs as one, a failed send
    /// keeps the text for another go.
    private var composer: some View {
        VStack(spacing: 6) {
            if !menuItems.isEmpty {
                menuList.transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let error = model.sendError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(error).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                    Text("Retry")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(IslandStyle.accent)
                        .onTapGesture { send() }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Ask First Mate — / for a command", text: $model.draft)
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
        } else {
            model.sendError = text.hasPrefix("/") ? "That command did not run." : "First Mate did not get it — is it running?"
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
        model.page = .conversation
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

    private struct ListHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
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

/// One line of First Mate's conversation as the island draws it: what was
/// said, folded tool runs, quiet notes. Turn edges are left out — the title
/// row's status says whether it is working.
struct ConversationItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case thinking(String)
        /// A run of tool calls: "Bash ×3 · Read".
        case tools(String)
        case note(String)
        /// What seahelm itself handed First Mate (`[seahelm event] …`, an
        /// approval's outcome): its first line, the whole text behind a tap.
        case event(headline: String, full: String)
    }

    let id: UInt64
    let kind: Kind

    static func items(from messages: [MessageEvent]) -> [ConversationItem] {
        var out: [ConversationItem] = []
        var run: [(tool: String, count: Int)] = []
        var runId: UInt64 = 0
        func closeRun() {
            guard !run.isEmpty else { return }
            let summary = run.map { $0.count > 1 ? "\($0.tool) ×\($0.count)" : $0.tool }.joined(separator: " · ")
            out.append(ConversationItem(id: runId, kind: .tools(summary)))
            run = []
        }
        for m in messages {
            let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch m.kind {
            case .tool:
                guard let tool = m.tool, !tool.isEmpty else { continue }
                if run.isEmpty { runId = m.seq }
                if run.last?.tool == tool { run[run.count - 1].count += 1 } else { run.append((tool, 1)) }
                continue
            case .user where text.hasPrefix("[seahelm"):
                let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
                let headline = first
                    .replacingOccurrences(of: "[seahelm event] ", with: "")
                    .replacingOccurrences(of: "[seahelm] ", with: "")
                closeRun(); out.append(ConversationItem(id: m.seq, kind: .event(headline: headline, full: text)))
            case .user where !text.isEmpty:
                closeRun(); out.append(ConversationItem(id: m.seq, kind: .user(text)))
            case .assistant where !text.isEmpty:
                closeRun(); out.append(ConversationItem(id: m.seq, kind: .assistant(text)))
            case .thinking where !text.isEmpty:
                closeRun(); out.append(ConversationItem(id: m.seq, kind: .thinking(text)))
            // Notices ("Claude is waiting for your input") say what the title's
            // status already does, once per turn: left out.
            case .decision where !text.isEmpty:
                closeRun(); out.append(ConversationItem(id: m.seq, kind: .note(text)))
            case .status where m.status == AgentStatus.error.rawValue:
                closeRun(); out.append(ConversationItem(id: m.seq, kind: .note("Stopped with an error")))
            default:
                continue
            }
        }
        closeRun()
        return out
    }
}

/// A pending suggest/question order rendered as a card with option chips.
private struct SuggestionCard: View {
    let order: Card
    let onOption: (String) -> Void
    let onDismiss: () -> Void
    /// Blank-area tap: jump to the raising pane without resolving the card.
    let onReveal: () -> Void

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isIntegration ? .orange : .yellow)
                Text(order.project)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                if !order.branch.isEmpty {
                    Text(order.branch)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                } else if isIntegration {
                    // The card names what it is about: without this it reads as
                    // the repo saying something, and a repo never speaks.
                    Text("integration")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                // onTapGesture, not Button: SwiftUI Buttons in a non-activating
                // panel swallow the click for key acquisition.
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
            }
            if !order.message.isEmpty {
                Text(order.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Options keep their own taps so they don't bubble to onReveal.
            OptionList(options: order.labels, onTap: onOption)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(IslandStyle.accent.opacity(0.3), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onReveal() }
    }
}

/// Options as full-width rows, top to bottom, each with a numbered badge.
private struct OptionList: View {
    let options: [String]
    let onTap: (String) -> Void
    @State private var hoveredIndex: Int?

    var body: some View {
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
                        Text(option)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
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
                .onTapGesture { onTap(option) }
                .onHover { inside in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
                    }
                }
            }
        }
    }
}
