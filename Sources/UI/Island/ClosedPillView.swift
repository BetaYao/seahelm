import SwiftUI

/// Collapsed island: a black pill that merges with the hardware notch.
/// Left wing shows an attention glyph/count, right wing a mini status-tile
/// grid (one tile per worktree agent). The centre stays empty — it sits
/// behind the physical notch on MacBooks.
struct ClosedPillView: View {
    let model: IslandModel

    private var pulseTiles: Bool {
        model.tileRows.contains { $0.status == .waiting }
    }

    var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: wingWidth, alignment: .leading)
            Spacer(minLength: model.isNotchedDisplay ? model.notchWidth : 8)
            rightWing
                .frame(width: wingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(width: model.closedWidth, height: model.notchHeight)
        .background(ClosedPillShape(bottomRadius: 14).fill(Color.black))
        .contentShape(Rectangle())
        // Material-style curve so wing content (badge/tiles) slides in and
        // out smoothly as counts change while closed.
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.45), value: model.unreadCount)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.45), value: model.orders.isEmpty)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.45), value: model.rows)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.transientText)
    }

    private var wingWidth: CGFloat { (model.closedWidth - model.notchWidth) / 2 - 10 }

    @ViewBuilder
    private var leftWing: some View {
        if let transient = model.transientText {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: SailorStatus.waiting.color))
                    .frame(width: 6, height: 6)
                Text(transient)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .transition(.opacity.combined(with: .move(edge: .leading)))
        } else if !model.orders.isEmpty {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.yellow)
                .transition(.opacity.combined(with: .move(edge: .leading)))
        } else if model.unreadCount > 0 {
            Text("\(model.unreadCount)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(model.unreadCount)))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.18)))
                .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if !model.tileRows.isEmpty {
            HStack(spacing: 3) {
                ForEach(model.tileRows.prefix(6)) { row in
                    StatusTile(status: row.status)
                }
                if model.tileRows.count > 6 {
                    Text("+\(model.tileRows.count - 6)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}

/// 8×8pt rounded tile colored by agent status; waiting pulses.
private struct StatusTile: View {
    let status: SailorStatus
    @State private var pulsing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color(nsColor: status.color))
            .frame(width: 8, height: 8)
            .opacity(opacityValue)
            .onAppear { startPulseIfNeeded() }
            .onChange(of: status) { startPulseIfNeeded() }
    }

    private var opacityValue: Double {
        switch status {
        case .waiting: return pulsing ? 1.0 : 0.35
        case .idle, .exited: return 0.35
        default: return 1.0
        }
    }

    private func startPulseIfNeeded() {
        if status == .waiting {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulsing = false }
        }
    }
}
