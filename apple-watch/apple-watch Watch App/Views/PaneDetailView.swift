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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Dot(status: p.status)
                                Text(st.zh).font(.mono(11, weight: .semibold)).foregroundStyle(st.color)
                                Text("· \(ctx.repo.name)/\(ctx.wt.branch)").font(.mono(11)).foregroundStyle(Ink.ash)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)

                            Bubbles(msgs: history.isEmpty ? liveFallback(p) : history)

                            // watchOS: no fixed bottom bar (too little screen) — actions
                            // scroll at the end of the conversation.
                            inlineActions(for: p)

                            Color.clear.frame(height: 1).id("bottom")   // scroll anchor
                        }
                        .opacity(store.offline ? 0.6 : 1)
                        .padding(.bottom, 8)
                    }
                    .navigationTitle(AgentStyle.of(p.agent).name)
                    .task(id: slot) {
                        store.loadHistory(slot) { msgs in
                            history = msgs
                            // let the new bubbles lay out, then jump to the latest.
                            DispatchQueue.main.async {
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                    }
                }
            } else {
                Color.clear.onAppear { if !path.isEmpty { path.removeLast() } }
            }
        }
    }

    private func liveFallback(_ p: Pane) -> [HistoryMsg] {
        p.brief.isEmpty ? [] : [HistoryMsg(kind: "msg", text: p.brief)]
    }

    // MARK: inline actions (end of scroll — decision options / reply / lock)

    @ViewBuilder private func inlineActions(for p: Pane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.offline {
                LockBar(text: !store.online ? "Mac 离线 · 只读" : "重连中 · 只读")
            } else if store.cap == .read {
                LockBar(text: "只读客户端")
            } else if let q = p.question, store.cap.canPick {
                GroupLabel(text: q.danger ? "确认 · 有风险" : "需要你确认")
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                    OptButton(label: o, style: i == 0 ? (q.danger ? .danger : .fill) : .ghost) {
                        store.resolve(p, index: i)
                    }
                }
            } else if let s = p.suggest, store.cap.canPick {
                GroupLabel(text: "建议 · 选一个")
                ForEach(Array(s.options.enumerated()), id: \.offset) { i, o in
                    OptButton(label: o, chevron: true) { store.resolve(p, index: i) }
                }
            } else if store.cap == .interactive {
                LockBar(text: "交互档 · 无待处理")
            } else {   // control, nothing pending → reply
                replyBar(for: p)
            }
        }
        .padding(.top, 4)
    }

    /// Reply — voice (dictation) is the prominent path; a smaller 文字 entry uses
    /// the same watchOS input (keyboard / scribble). Both submit via TextFieldLink.
    @ViewBuilder private func replyBar(for p: Pane) -> some View {
        let target = AgentStyle.of(p.agent).name
        VStack(spacing: 8) {
            TextFieldLink(prompt: Text("对 \(target) 说…")) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 16))
                    Text("语音回复").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Ink.ember, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } onSubmit: { store.send(p, text: $0) }
            .buttonStyle(.plain)

            TextFieldLink(prompt: Text("对 \(target) 说…")) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard").font(.system(size: 12))
                    Text("文字").font(.system(size: 13))
                }
                .foregroundStyle(Ink.ash)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.stone, lineWidth: 1))
            } onSubmit: { store.send(p, text: $0) }
            .buttonStyle(.plain)
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
