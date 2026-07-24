import SwiftUI

enum Route: Hashable {
    case allSessions
    case paneList(project: String, wt: String)
    case pane(slot: String)
    case orders
    case confirm(slot: String)
    case dnd
    case reply(slot: String)
    case settings
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !store.isPaired {
                    PairingView()                       // mandatory gate — no browsing until paired
                } else if store.everConnected {
                    HomeView(path: $path)
                } else {
                    ConnectingView(path: $path)
                }
            }
            .inkBackground()
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .allSessions:                AllSessionsView(path: $path).inkBackground()
                case .paneList(let proj, let wt): PaneListView(project: proj, wt: wt, path: $path).inkBackground()
                case .pane(let slot):             PaneDetailView(slot: slot, path: $path).inkBackground()
                case .orders:                     OrdersView(path: $path).inkBackground()
                case .confirm(let slot):          ConfirmView(slot: slot, path: $path).inkBackground()
                case .dnd:                        DndView().inkBackground()
                case .reply(let slot):            ReplyView(slot: slot, path: $path).inkBackground()
                case .settings:                   SettingsView(path: $path).inkBackground()
                }
            }
        }
    }
}

/// Shown until the first successful connect (or when the user opens Settings to
/// point at a different broker). Mirrors the design's Pairing screen.
struct ConnectingView: View {
    @EnvironmentObject var store: Store
    @Binding var path: [Route]
    var body: some View {
        VStack(spacing: 12) {
            Spirit(size: 96)
            Text(store.conn == .connecting ? "连接中…" : "未连接")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.bone)
            Text("\(store.config.gatewayBaseURL) · \(store.config.macId)")
                .font(.mono(11)).foregroundStyle(Ink.ash).multilineTextAlignment(.center)
            if let err = store.netError {
                Text(err).font(.system(size: 11)).foregroundStyle(Ink.red).multilineTextAlignment(.center)
            }
            if store.conn == .connecting { ProgressView().tint(Ink.ember) }
            OptButton(label: "设置", style: .ghost) { path.append(.settings) }
                .padding(.top, 6)
        }
        .padding(.horizontal, 10)
    }
}

/// Shared top bar (moon/DND toggle + live clock).
struct TopBar: View {
    @Binding var path: [Route]
    @EnvironmentObject var store: Store
    var body: some View {
        HStack {
            Button { path.append(.dnd) } label: {
                Image(systemName: "moon.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(store.dnd.on ? Ink.ember : Ink.ash)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(Date.now, style: .time)
                .font(.mono(13, weight: .medium)).foregroundStyle(Ink.ash)
        }
    }
}
