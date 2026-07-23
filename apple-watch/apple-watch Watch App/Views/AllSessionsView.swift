import SwiftUI

/// Full repo → worktree list (the design's HomeList / AllSessions).
struct AllSessionsView: View {
    @EnvironmentObject var store: Store
    @Binding var path: [Route]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // online / counts strip
                Card {
                    HStack {
                        HStack(spacing: 12) {
                            countChip(.running, store.counts.running, "运行")
                            countChip(.waiting, store.counts.waiting, "等你")
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Circle().fill(store.offline ? Ink.red : Ink.green).frame(width: 7, height: 7)
                            Text(store.offline ? "离线" : "在线")
                                .font(.mono(11)).foregroundStyle(store.offline ? Ink.red : Ink.green)
                        }
                    }
                }

                if !store.orders.isEmpty {
                    Button { path.append(.orders) } label: {
                        Card {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("待处理").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ember)
                                    Text("\(store.orders.count) 条需要你确认").font(.system(size: 12)).foregroundStyle(Ink.ash)
                                }
                                Spacer()
                                Text("\(store.orders.count)")
                                    .font(.mono(13, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Ink.ember, in: Capsule())
                            }
                        }
                    }.buttonStyle(.plain)
                }

                ForEach(store.repos) { repo in
                    GroupLabel(text: repo.name)
                    ForEach(repo.worktrees) { wt in
                        Button { path.append(.paneList(project: repo.id, wt: wt.id)) } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(wt.branch).font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(Ink.bone).lineLimit(1)
                                        Spacer()
                                        Rollup(panes: wt.panes)
                                    }
                                    if !wt.last.isEmpty {
                                        Text(wt.last).font(.system(size: 13)).foregroundStyle(Ink.ash).lineLimit(1)
                                    }
                                    Text("\(wt.panes.count) pane").font(.mono(11)).foregroundStyle(Ink.ash)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }

                Button { path.append(.settings) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill").font(.system(size: 12))
                        Text("设置 · broker / 档位").font(.system(size: 13))
                    }
                    .foregroundStyle(Ink.ash)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.plain).padding(.top, 6)
            }
            .opacity(store.offline ? 0.6 : 1)
        }
        .navigationTitle("全部会话")
    }

    private func countChip(_ s: PaneStatus, _ n: Int, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(StatusStyle.of(s).color).frame(width: 8, height: 8)
            Text("\(n)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.bone)
            Text(label).font(.mono(11)).foregroundStyle(Ink.ash)
        }
    }
}

/// Panes within one worktree.
struct PaneListView: View {
    @EnvironmentObject var store: Store
    let project: String
    let wt: String
    @Binding var path: [Route]

    private var worktree: (repo: Repo, wt: Worktree)? {
        guard let r = store.repos.first(where: { $0.id == project }),
              let w = r.worktrees.first(where: { $0.id == wt }) else { return nil }
        return (r, w)
    }

    var body: some View {
        ScrollView {
            if let ctx = worktree {
                VStack(alignment: .leading, spacing: 8) {
                    GroupLabel(text: "\(ctx.repo.name) · \(ctx.wt.panes.count) pane")
                    ForEach(ctx.wt.panes) { p in
                        Button { path.append(.pane(slot: p.id)) } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 10) {
                                        AgentBadge(agent: p.agent)
                                        Text(AgentStyle.of(p.agent).name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.bone)
                                        Spacer()
                                        StatusTag(status: p.status)
                                    }
                                    if !p.brief.isEmpty {
                                        Text(p.brief).font(.system(size: 13)).foregroundStyle(Ink.ash).lineLimit(2)
                                    }
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .opacity(store.offline ? 0.6 : 1)
            }
        }
        .navigationTitle(worktree?.wt.branch ?? "")
    }
}
