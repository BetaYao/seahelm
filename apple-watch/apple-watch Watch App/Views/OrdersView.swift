import SwiftUI

struct OrdersView: View {
    @EnvironmentObject var store: Store
    @Binding var path: [Route]

    var body: some View {
        ScrollView {
            if store.orders.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 24)).foregroundStyle(Ink.green)
                        .frame(width: 56, height: 56).background(Ink.lamp, in: Circle())
                    Text("没有待办").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.bone)
                    Text("所有确认都处理完了").font(.system(size: 12)).foregroundStyle(Ink.ash)
                }
                .frame(maxWidth: .infinity).padding(.top, 30)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.orders) { o in
                        Button { path.append(.confirm(slot: o.paneId)) } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        AgentBadge(agent: o.agent, size: 22)
                                        Text(o.path).font(.mono(11)).foregroundStyle(Ink.ash).lineLimit(1)
                                        Spacer()
                                        Text(o.danger ? "危险" : o.isQuestion ? "需确认" : "建议")
                                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(o.danger ? Ink.red : o.isQuestion ? Ink.amber : Ink.green, in: Capsule())
                                    }
                                    Text(o.prompt).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.bone).lineLimit(2)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("待处理")
    }
}

struct ConfirmView: View {
    @EnvironmentObject var store: Store
    let slot: String
    @Binding var path: [Route]

    var body: some View {
        Group {
            if let ctx = store.pane(slot), (ctx.pane.question != nil || ctx.pane.suggest != nil) {
                let p = ctx.pane
                let q = p.question
                let danger = q?.danger ?? false
                let opts = q?.options ?? p.suggest?.options ?? []
                let prompt = q?.prompt ?? p.suggest?.message ?? "选择下一步"
                VStack(spacing: 0) {
                    if danger { Rectangle().fill(Ink.red).frame(height: 4).ignoresSafeArea(edges: .top) }
                    ScrollView {
                        VStack(spacing: 12) {
                            HStack(spacing: 7) {
                                AgentBadge(agent: p.agent, size: 22)
                                Text("\(ctx.repo.name)/\(ctx.wt.branch)").font(.mono(11)).foregroundStyle(Ink.ash).lineLimit(1)
                            }
                            Text(prompt).font(.system(size: 18, weight: .semibold)).foregroundStyle(Ink.bone)
                                .multilineTextAlignment(.center)
                            if danger {
                                HStack(spacing: 5) {
                                    Image(systemName: "bolt.fill").font(.system(size: 11))
                                    Text("此操作有风险").font(.mono(11))
                                }.foregroundStyle(Ink.amber)
                            }
                            VStack(spacing: 9) {
                                if store.cap == .read {
                                    LockBar(text: "只读客户端 · 无法确认")
                                } else {
                                    ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
                                        OptButton(label: o, style: i == 0 ? (danger ? .danger : .fill) : .ghost) {
                                            store.resolve(p, index: i)
                                            if !path.isEmpty { path.removeLast() }
                                        }
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                        .padding(.top, 8)
                    }
                }
                .navigationTitle(q != nil ? "确认" : "建议")
            } else {
                Color.clear.onAppear { if !path.isEmpty { path.removeLast() } }
            }
        }
    }
}
