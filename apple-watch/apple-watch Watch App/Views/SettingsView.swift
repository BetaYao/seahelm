import SwiftUI

/// Reachable only when paired (the unpaired gate is PairingView). Minimal by
/// request: show the pairing state + a single 取消配对 action.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Binding var path: [Route]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupLabel(text: "配对 · E2EE")
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(Ink.green)
                    Text(store.config.macId).font(.mono(13, weight: .semibold)).foregroundStyle(Ink.bone)
                    Text("E2EE").font(.mono(10)).tracking(1).foregroundStyle(Ink.green)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Ink.green.opacity(0.4), lineWidth: 1))
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Ink.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                OptButton(label: "取消配对", style: .danger) {
                    store.unpair()                       // → RootView gate returns to PairingView
                    if !path.isEmpty { path.removeAll() }
                }

                Text("取消后需在 Mac 重新生成短码配对").font(.system(size: 11)).foregroundStyle(Ink.ash)
            }
        }
        .navigationTitle("设置")
    }
}
