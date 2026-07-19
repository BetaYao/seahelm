import SwiftUI

/// Expanded island: suggestion/question cards with tappable option chips,
/// then per-worktree agent rows, then recent notifications.
struct OpenedSurfaceView: View {
    let model: IslandModel
    let namespace: Namespace.ID
    @State private var hoveredRowID: String?
    @State private var commandText = ""
    @FocusState private var commandFocused: Bool
    @State private var menuItems: [(name: String, desc: String)] = []
    @State private var menuSel = 0
    @State private var menuTrigger: Character = "/"
    @State private var menuToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The root's header band already spans the hardware notch; just
            // leave breathing room below it.
            Color.clear.frame(height: 6)

            VStack(alignment: .leading, spacing: 10) {
                header
                middleSection
                commandBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: model.openedWidth)
        // Content churn while open (rows/orders/notifications changing)
        // animates instead of hard-swapping.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.orders)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.rows)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.unreadCount)
    }

    /// Auto-height list area: renders at natural height, and past the cap it
    /// becomes an internal scroll instead of overflowing the panel. The
    /// measured height lives in the model so it survives close/reopen.
    private static let maxListHeight: CGFloat = 380
    private var listHeight: CGFloat { model.cachedListHeight }

    private var middleSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                if !model.orders.isEmpty {
                    // A pending suggestion takes over the island — worktree
                    // rows and notifications stay hidden until it resolves.
                    ForEach(model.orders) { order in
                        SuggestionCard(order: order,
                                       onOption: { optionText in
                                           model.onOptionTapped?(order, optionText)
                                       },
                                       onDismiss: { model.onDismissOrder?(order) })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    if !model.rows.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(model.rows) { row in
                                agentRow(row)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    if !model.recentNotifications.isEmpty {
                        Divider().overlay(IslandStyle.accent.opacity(0.14))
                        VStack(spacing: 2) {
                            ForEach(model.recentNotifications) { entry in
                                notificationRow(entry)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                }
            )
        }
        // Before the first preference lands, let the list size naturally —
        // pinning it to 1pt made the surface open squashed, then jump.
        .frame(height: listHeight > 0 ? min(listHeight, Self.maxListHeight) : nil)
        .onPreferenceChange(ListHeightKey.self) { height in
            // Ignore the 0 that fires as this view is removed on close —
            // it would wipe the cache and cause a first-frame jump next open.
            if height > 0 { model.cachedListHeight = height }
        }
    }

    private var commandBar: some View {
        VStack(spacing: 6) {
            if !menuItems.isEmpty {
                menuList
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Give an order — / command · @ repo · #", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .focused($commandFocused)
                    .onChange(of: commandText) { refreshMenu(for: commandText) }
                    .onKeyPress(.upArrow) { moveMenuSelection(-1) }
                    .onKeyPress(.downArrow) { moveMenuSelection(1) }
                    .onKeyPress(.tab) { acceptMenuSelection() }
                    .onKeyPress(.escape) {
                        guard !menuItems.isEmpty else { return .ignored }
                        withAnimation(.easeInOut(duration: 0.15)) { menuItems = [] }
                        return .handled
                    }
                    .onSubmit {
                        // Menu open: Enter completes the token instead of submitting.
                        if acceptMenuSelection() == .handled { return }
                        let t = commandText.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        model.onSubmitCommand?(t)
                        commandText = ""
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(commandFocused ? IslandStyle.accent.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { commandFocused = true }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: menuItems.map(\.name))
        .onAppear {
            consumePrefill()
            consumeFocusRequest()
        }
        .onChange(of: model.pendingCommandPrefill) { consumePrefill() }
        .onChange(of: model.pendingCommandFocus) { consumeFocusRequest() }
    }

    private func consumePrefill() {
        guard let prefill = model.pendingCommandPrefill else { return }
        commandText = prefill
        model.pendingCommandPrefill = nil
        // Focus after the field is mounted and the panel is key.
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
              let (trigger, _, token) = trailingToken(commandText) else { return .ignored }
        let name = menuItems[menuSel].name
        commandText = String(commandText.dropLast(token.count)) + String(trigger) + name + " "
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
        HStack {
            Text("Seahelm")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            if model.unreadCount > 0 {
                Text("\(model.unreadCount) unread")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText(value: Double(model.unreadCount)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(IslandStyle.accent.opacity(0.22)))
                    .matchedGeometryEffect(id: "unread-badge", in: namespace, isSource: model.isOpened)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Spacer()
            if model.unreadCount > 0 {
                // onTapGesture, not Button: SwiftUI Buttons in a
                // non-activating panel swallow the click for key acquisition.
                Text("Read all")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentShape(Rectangle())
                    .onTapGesture { model.onMarkAllRead?() }
            }
        }
    }

    private func agentRow(_ row: IslandAgentRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            agentRowHeader(row)
            if !row.message.isEmpty {
                Text(row.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 15) // align under the text, past the dot
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hoveredRowID == row.id ? 0.09 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.onNavigate?(row.id, nil)
            model.close()
        }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredRowID = inside ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
            }
        }
    }

    private func agentRowHeader(_ row: IslandAgentRow) -> some View {
        HStack(spacing: 8) {
                Circle()
                    .fill(Color(nsColor: row.status.color))
                    .frame(width: 7, height: 7)
                Text(row.project)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if !row.branch.isEmpty {
                    Text(row.branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                if !row.title.isEmpty {
                    Text(row.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(row.status.rawValue)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: row.status.color).opacity(0.9))
            }
    }

    private func notificationRow(_ entry: NotificationEntry) -> some View {
        HStack(spacing: 8) {
                Text(entry.status.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: entry.status.color))
                if !entry.workspaceName.isEmpty {
                    Text(entry.workspaceName)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text(entry.branch)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Text(entry.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(entry.timestamp, style: .relative)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                model.onNavigate?(entry.worktreePath, entry.paneIndex)
                model.close()
            }
    }
}

/// A pending suggest/question order rendered as a card with option chips.
private struct SuggestionCard: View {
    let order: PendingOrder
    let onOption: (String) -> Void
    let onDismiss: () -> Void

    private var isQuestion: Bool {
        order.action.payload == FirstMateAction.askUserQuestionPayload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isQuestion ? "questionmark.circle.fill" : "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                Text(order.action.project)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                if !order.action.branch.isEmpty {
                    Text(order.action.branch)
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
            if !order.action.message.isEmpty {
                Text(order.action.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OptionList(options: order.action.options ?? [], onTap: onOption)
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
