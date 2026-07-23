import SwiftUI

struct PaneDetailView: View {
    @EnvironmentObject var store: Store
    let slot: String
    @Binding var path: [Route]
    @State private var history: [HistoryMsg] = []

    private var ctx: (pane: Pane, repo: Repo, wt: Worktree)? { store.pane(slot) }

    var body: some View {
        Group {
            if let ctx {
                let p = ctx.pane
                let st = StatusStyle.of(p.status)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Dot(status: p.status)
                            Text(st.zh).font(.mono(11, weight: .semibold)).foregroundStyle(st.color)
                            Text("· \(ctx.repo.name)/\(ctx.wt.branch)").font(.mono(11)).foregroundStyle(Ink.ash)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        Bubbles(msgs: history.isEmpty ? liveFallback(p) : history)

                        options(for: p)

                        // quick replies (control, when nothing pending)
                        if store.cap.canType && !store.offline && p.question == nil && p.suggest == nil {
                            replyBar(for: p)
                        }
                    }
                    .opacity(store.offline ? 0.6 : 1)
                    .padding(.bottom, 8)
                }
                .navigationTitle(AgentStyle.of(p.agent).name)
                .task(id: slot) { store.loadHistory(slot) { history = $0 } }
                .safeAreaInset(edge: .bottom) { lockBar }
            } else {
                Color.clear.onAppear { if !path.isEmpty { path.removeLast() } }
            }
        }
    }

    private func liveFallback(_ p: Pane) -> [HistoryMsg] {
        p.brief.isEmpty ? [] : [HistoryMsg(kind: "msg", text: p.brief)]
    }

    // MARK: options (question / suggest)

    @ViewBuilder private func options(for p: Pane) -> some View {
        if !store.offline && store.cap.canPick, let q = p.question {
            VStack(alignment: .leading, spacing: 8) {
                GroupLabel(text: "需要你确认")
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                    OptButton(label: o, style: i == 0 ? (q.danger ? .danger : .fill) : .ghost) {
                        store.resolve(p, index: i)
                    }
                }
            }
        } else if !store.offline && store.cap.canPick, let s = p.suggest {
            VStack(alignment: .leading, spacing: 8) {
                GroupLabel(text: "建议 · 选一个")
                ForEach(Array(s.options.enumerated()), id: \.offset) { i, o in
                    OptButton(label: o, chevron: true) { store.resolve(p, index: i) }
                }
            }
        }
    }

    @ViewBuilder private func replyBar(for p: Pane) -> some View {
        OptButton(label: "听写回复", style: .fill) { path.append(.reply(slot: p.id)) }
    }

    // MARK: capability / offline lock

    @ViewBuilder private var lockBar: some View {
        if store.offline {
            LockBar(text: !store.online ? "Mac 离线 · 只读" : "重连中 · 只读")
        } else if store.cap == .read {
            LockBar(text: "只读客户端")
        } else if store.cap == .interactive {
            LockBar(text: "交互档 · 仅可选择选项")
        }
    }
}

/// Conversation bubbles (you = right/ember, agent = left, status = centered).
struct Bubbles: View {
    let msgs: [HistoryMsg]
    var body: some View {
        VStack(spacing: 9) {
            // history buffer is oldest→newest; show newest at the bottom
            ForEach(msgs) { m in
                if m.kind == "status" {
                    Text(m.text).font(.mono(11)).foregroundStyle(Ink.ash)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    let you = m.kind == "you"
                    HStack {
                        if you { Spacer(minLength: 24) }
                        Text(m.text)
                            .font(.system(size: 14)).foregroundStyle(Ink.bone)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(you ? Ink.lamp2 : Ink.lamp,
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 13)
                                .stroke(you ? Ink.ember.opacity(0.3) : m.kind == "ask" ? Ink.amber.opacity(0.35) : .clear, lineWidth: 1))
                        if !you { Spacer(minLength: 24) }
                    }
                }
            }
        }
    }
}

struct LockBar: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 11))
            Text(text).font(.mono(11))
        }
        .foregroundStyle(Ink.ash)
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Ink.night.opacity(0.9))
    }
}
