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
                if let warning = model.warning {
                    warningBanner(warning.message)
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
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.warning)
        .onAppear { consumePrefill(); consumeFocusRequest() }
        .onChange(of: model.pendingCommandPrefill) { consumePrefill() }
        .onChange(of: model.pendingCommandFocus) { consumeFocusRequest() }
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

    /// First Mate's column: everything it says sits right of the event icons.
    private static let gutter: CGFloat = 26

    private var conversation: some View {
        let items = ConversationItem.items(from: model.mateMessages)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if items.isEmpty {
                        Text(model.mateRunning ? "Nothing said yet. Ask First Mate anything — a `/command` runs as one."
                                               : "First Mate is off. Turn it on in Settings ▸ First Mate.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                            // A new section (an event, the user speaking) gets air above it.
                            .padding(.top, index > 0 && Self.startsSection(item) ? 12 : 0)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: Self.maxListHeight * 0.85)
            .onAppear { proxy.scrollTo(items.last?.id, anchor: .bottom) }
            .onChange(of: items.last?.id) { proxy.scrollTo(items.last?.id, anchor: .bottom) }
        }
    }

    static func startsSection(_ item: ConversationItem) -> Bool {
        switch item.kind {
        case .event, .user, .brief: return true
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
            let open = expanded.contains(item.id)
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
                                Text(open ? "Less" : "More")
                                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if open { expanded.remove(item.id) } else { expanded.insert(item.id) }
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
            Text(text)
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
            eventHeader(id: item.id, ts: item.ts, headline: headline, full: full, style: style)
        }
    }

    /// An event as the header of what First Mate did about it: an icon in its
    /// colour, what happened, when. The text seahelm sent sits behind a tap.
    @ViewBuilder
    private func eventHeader(id: UInt64, ts: Date, headline: String, full: String,
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
    }

    let id: UInt64
    let kind: Kind
    let ts: Date

    init(id: UInt64, kind: Kind, ts: Date = .distantPast) {
        self.id = id; self.kind = kind; self.ts = ts
    }

    static func items(from messages: [MessageEvent]) -> [ConversationItem] {
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
        for m in messages {
            let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let item = { (kind: Kind) in ConversationItem(id: m.seq, kind: kind, ts: m.ts) }
            switch m.kind {
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
                out.append(item(.assistant(text, tools: summary)))
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
                if options.count > 1 { held = item(.decision(options)) } else { out.append(item(.note(text))) }
            case .status where m.status == AgentStatus.error.rawValue:
                dropRun(); flush(); out.append(item(.note("Stopped with an error")))
            default:
                continue
            }
        }
        // Calls with nothing after them: the turn is still under way.
        if let summary { out.append(ConversationItem(id: runId, kind: .tools(summary), ts: runTs)) }
        flush()
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
            if isQuestion, !order.header.isEmpty {
                // The question's tab title in the agent's dialog.
                Text(order.header)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, -4)
            }
            if !order.message.isEmpty {
                Text(order.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Options keep their own taps so they don't bubble to onReveal.
            OptionList(options: order.labels,
                       details: order.labels.indices.map { order.detail(forLabelAt: $0) },
                       onTap: onOption)
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
    /// A line under each option ("" for none), as the agent's dialog shows it.
    var details: [String] = []
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
