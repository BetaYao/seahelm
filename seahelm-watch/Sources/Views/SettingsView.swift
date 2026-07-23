import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Binding var path: [Route]

    @State private var host = ""
    @State private var portText = ""
    @State private var macId = ""
    @State private var tls = false
    @State private var cap: Capability = .control

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                field("Broker Host", text: $host, placeholder: "192.168.1.x / cloud host")
                field("Port", text: $portText, placeholder: "8083")
                field("Mac ID", text: $macId, placeholder: "live")

                Toggle(isOn: $tls) {
                    Text("TLS (wss)").font(.system(size: 14)).foregroundStyle(Ink.bone)
                }
                .tint(Ink.ember)

                VStack(alignment: .leading, spacing: 6) {
                    GroupLabel(text: "能力档位")
                    Picker("", selection: $cap) {
                        Text("只读").tag(Capability.read)
                        Text("交互").tag(Capability.interactive)
                        Text("控制").tag(Capability.control)
                    }
                    .pickerStyle(.navigationLink)
                    .tint(Ink.bone)
                }

                OptButton(label: "保存并重连", style: .fill) {
                    var c = store.config
                    c.host = host.trimmingCharacters(in: .whitespaces)
                    c.port = UInt16(portText) ?? c.port
                    c.macId = macId.trimmingCharacters(in: .whitespaces)
                    c.tls = tls
                    c.capability = cap
                    store.reconnect(with: c)
                    if !path.isEmpty { path.removeAll() }
                }
                .padding(.top, 4)
            }
        }
        .navigationTitle("设置")
        .onAppear {
            host = store.config.host
            portText = String(store.config.port)
            macId = store.config.macId
            tls = store.config.tls
            cap = store.config.capability
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupLabel(text: label)
            TextField(placeholder, text: text)
                .font(.mono(13))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Ink.lamp, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.stone, lineWidth: 1))
        }
    }
}
