import SwiftUI

/// Home = single-attention focus (SRP §5), or the immersive 灰灵 when all-quiet.
struct HomeView: View {
    @EnvironmentObject var store: Store
    @Binding var path: [Route]

    private var attn: Int { store.counts.waiting + store.counts.failed }
    private var allQuiet: Bool { store.counts.running == 0 && attn == 0 && !store.offline }

    var body: some View {
        Group {
            if store.repos.isEmpty && !store.offline {
                idleSpirit
            } else if allQuiet {
                idleSpirit
            } else {
                focus
            }
        }
    }

    // MARK: focus

    private var focusTarget: Pane? {
        store.repos.flatMap { $0.worktrees.flatMap(\.panes) }
            .min { $0.status.priority < $1.status.priority }
    }

    @ViewBuilder private var focus: some View {
        let c = store.counts
        let heartbeat: (n: Int, w: String) =
            c.running > 0 ? (c.running, "running")
            : c.waiting > 0 ? (c.waiting, "waiting")
            : c.failed > 0 ? (c.failed, "failed") : (0, "idle")
        let fp = focusTarget
        let idle = fp == nil || (heartbeat.n == 0 && c.waiting == 0 && c.failed == 0)
        let headline: String = {
            guard let fp, !idle else { return "一切安好" }
            let a = AgentStyle.of(fp.agent).name
            if let q = fp.question { return "\(a) · 等你答:\(q.prompt)" }
            return "\(a) · \(fp.brief)"
        }()

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TopBar(path: $path)
                GroupLabel(text: idle ? "现在" : "FOCUS", color: idle ? Ink.ash : Ink.ember)
                    .padding(.top, 4)

                Button {
                    if let fp, !idle { path.append(.pane(slot: fp.id)) }
                } label: {
                    VStack(spacing: 4) {
                        Text("\(idle ? 0 : heartbeat.n)")
                            .font(.serif(66, weight: .medium))
                            .foregroundStyle(idle ? Ink.ash : Ink.bone)
                            .monospacedDigit()
                        Text(idle ? "idle" : heartbeat.w)
                            .font(.mono(12)).tracking(1).foregroundStyle(Ink.ash)
                        Text(headline)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Ink.bone)
                            .multilineTextAlignment(.center)
                            .lineLimit(3).lineSpacing(1)
                            .padding(.top, 10)
                        if c.waiting + c.failed > 0 {
                            HStack(spacing: 14) {
                                if c.waiting > 0 { Text("\(c.waiting) waiting").foregroundStyle(Ink.amber) }
                                if c.failed > 0 { Text("\(c.failed) failed").foregroundStyle(Ink.red) }
                            }
                            .font(.mono(13, weight: .medium)).padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(idle ? Color.clear : Ink.lamp,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(idle ? .clear : Ink.line, lineWidth: 1))
                }
                .buttonStyle(.plain).disabled(idle)

                if !store.orders.isEmpty {
                    OptButton(label: "待处理 · \(store.orders.count)", chevron: true) { path.append(.orders) }
                }
                Button { path.append(.allSessions) } label: {
                    Text("全部会话 · \(c.panes) pane ›")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.ash)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                }
                .buttonStyle(.plain)

                if store.offline {
                    Text("Mac 离线 · 最后同步状态")
                        .font(.mono(11)).foregroundStyle(Ink.ash)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .opacity(store.offline ? 0.6 : 1)
        }
    }

    // MARK: idle spirit

    private var idleSpirit: some View {
        Button { path.append(.allSessions) } label: {
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "moon.fill").font(.system(size: 12))
                        .foregroundStyle(store.dnd.on ? Ink.ember : Ink.ash)
                    Spacer()
                    Text(Date.now, style: .time).font(.mono(13, weight: .medium)).foregroundStyle(Ink.ash)
                }
                Spacer()
                Spirit(size: 132)
                Text(attn > 0 ? "\(attn) 项待处理 · 轻点进入" : "一切安好 · 轻点进入")
                    .font(.system(size: 13)).foregroundStyle(Ink.ash)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}

/// The design's `aw-opt` row button.
struct OptButton: View {
    var label: String
    var chevron = false
    var style: OptStyle = .ghost
    var action: () -> Void
    enum OptStyle { case ghost, fill, danger }
    var body: some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style == .fill || style == .danger ? .white : Ink.bone)
                    .multilineTextAlignment(.leading)
                Spacer()
                if chevron { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Ink.ash) }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(style == .ghost ? Ink.stone : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private var background: Color {
        switch style { case .ghost: return Ink.lamp; case .fill: return Ink.ember; case .danger: return Ink.red }
    }
}
