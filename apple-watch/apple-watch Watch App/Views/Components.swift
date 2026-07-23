import SwiftUI

/// Status dot — pulses ("breathes") for running/waiting.
struct Dot: View {
    let status: PaneStatus
    var size: CGFloat = 9
    @State private var pulse = false
    var body: some View {
        let st = StatusStyle.of(status)
        Circle()
            .fill(st.color)
            .frame(width: size, height: size)
            .shadow(color: st.color.opacity(0.9), radius: st.breathe ? 5 : 0)
            .scaleEffect(st.breathe && pulse ? 1.18 : 1)
            .opacity(st.breathe && pulse ? 0.75 : 1)
            .animation(st.breathe ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

struct StatusTag: View {
    let status: PaneStatus
    var body: some View {
        let st = StatusStyle.of(status)
        HStack(spacing: 5) {
            Dot(status: status)
            Text(st.zh).font(.mono(11, weight: .medium)).foregroundStyle(st.color)
        }
    }
}

/// Small square agent glyph.
struct AgentBadge: View {
    let agent: String
    var size: CGFloat = 26
    var body: some View {
        let a = AgentStyle.of(agent)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(a.color.opacity(0.16))
            .overlay(Text(a.mono).font(.mono(size * 0.42, weight: .semibold)).foregroundStyle(a.color))
            .frame(width: size, height: size)
    }
}

/// Compact per-worktree status roll-up: colored dots with counts.
struct Rollup: View {
    let panes: [Pane]
    var body: some View {
        let order: [PaneStatus] = [.waiting, .failed, .running, .done, .idle]
        let counts = Dictionary(grouping: panes, by: { $0.status }).mapValues(\.count)
        HStack(spacing: 6) {
            ForEach(order.filter { (counts[$0] ?? 0) > 0 }, id: \.self) { s in
                HStack(spacing: 3) {
                    Circle().fill(StatusStyle.of(s).color).frame(width: 6, height: 6)
                    Text("\(counts[s]!)").font(.mono(11)).foregroundStyle(Ink.ash)
                }
            }
        }
    }
}

/// Card container matching the design's `aw-card`.
struct Card<Content: View>: View {
    var plain = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(plain ? Color.clear : Ink.lamp,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Ink.line, lineWidth: plain ? 0 : 1))
    }
}

/// Section label ("aw-grp").
struct GroupLabel: View {
    let text: String
    var color: Color = Ink.ash
    var body: some View {
        Text(text.uppercased())
            .font(.mono(10, weight: .medium)).tracking(2)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The idle "灰灵" (sea spirit) — a breathing ship's wheel glyph. Placeholder
/// vector until the real `assets/sea_ship_wheel_logo` is bundled.
struct Spirit: View {
    var size: CGFloat = 150
    @State private var breathe = false
    var body: some View {
        ZStack {
            Circle().stroke(Ink.stone, lineWidth: 2).frame(width: size * 0.62, height: size * 0.62)
            ForEach(0..<8, id: \.self) { i in
                Capsule().fill(Ink.ash.opacity(0.55))
                    .frame(width: 3, height: size * 0.16)
                    .offset(y: -size * 0.36)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
            Circle().fill(Ink.lamp).frame(width: size * 0.26, height: size * 0.26)
            Circle().stroke(Ink.ash.opacity(0.5), lineWidth: 1.5).frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .scaleEffect(breathe ? 1.03 : 0.97)
        .opacity(breathe ? 0.9 : 0.7)
        .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
    }
}

extension View {
    /// Screen background.
    func inkBackground() -> some View {
        self.background(Ink.night.ignoresSafeArea())
    }
}
