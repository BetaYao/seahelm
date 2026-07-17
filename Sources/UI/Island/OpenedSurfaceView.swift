import SwiftUI

/// Expanded island: suggestion/question cards with tappable option chips,
/// then per-worktree agent rows, then recent notifications.
struct OpenedSurfaceView: View {
    let model: IslandModel
    @State private var hoveredRowID: String?

    private static let maxNotifications = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Spacer band matching the physical notch so content starts
            // below the hardware cutout.
            Color.clear.frame(height: model.notchHeight + 6)

            VStack(alignment: .leading, spacing: 10) {
                header

                if !model.orders.isEmpty {
                    // A pending suggestion takes over the island — worktree
                    // rows and notifications stay hidden until it resolves.
                    ForEach(model.orders) { order in
                        SuggestionCard(order: order) { optionText in
                            model.onOptionTapped?(order, optionText)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    if !model.rows.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(model.rows) { row in
                                agentRow(row)
                            }
                        }
                    }

                    if !recentNotifications.isEmpty {
                        Divider().overlay(Color.white.opacity(0.08))
                        VStack(spacing: 2) {
                            ForEach(recentNotifications) { entry in
                                notificationRow(entry)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: model.openedWidth)
        .background(
            NotchShape(topRadius: 10, bottomRadius: 22)
                .fill(Color.black)
                .overlay(
                    NotchShape(topRadius: 10, bottomRadius: 22)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        )
    }

    private var recentNotifications: [NotificationEntry] {
        Array(
            NotificationHistory.shared.entries
                .filter { !$0.isRead }
                .prefix(Self.maxNotifications)
        )
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
                        .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
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
