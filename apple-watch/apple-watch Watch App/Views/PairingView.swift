import SwiftUI

/// Mandatory pairing gate (§7.5.4): shown until the watch holds a root secret.
/// watchOS has no numeric keyboard for TextField, so the 8-digit short code is
/// entered with a built-in keypad; on the 8th digit it auto-submits, trading the
/// code for the root secret over MQTT and reconnecting E2EE.
struct PairingView: View {
    @EnvironmentObject var store: Store
    @State private var code = ""
    @State private var pairing = false
    @State private var failed = false

    private var display: String {
        let d = Array(code)
        return (0..<8).map { i in i < d.count ? String(d[i]) : "·" }.joined()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("配对").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.bone)
                    .padding(.top, 2)

                Text(display)
                    .font(.mono(22, weight: .semibold)).tracking(3)
                    .foregroundStyle(failed ? Ink.red : Ink.bone)

                if failed {
                    Text("码错误或已过期").font(.system(size: 11)).foregroundStyle(Ink.red)
                } else if pairing {
                    HStack(spacing: 6) { ProgressView().tint(Ink.ember); Text("配对中…").font(.mono(11)).foregroundStyle(Ink.ash) }
                } else {
                    Text(store.conn == .connected ? "Mac『生成短码』· 60s 内输入" : "连接 broker 中…")
                        .font(.mono(10)).foregroundStyle(Ink.ash).multilineTextAlignment(.center)
                }

                keypad.padding(.top, 2).disabled(pairing)

                OptButton(label: code.count == 8 ? "配对" : "还需 \(8 - code.count) 位",
                          style: code.count == 8 ? .fill : .ghost) { submit() }
                    .disabled(code.count != 8 || pairing)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 6)
        }
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                if k.isEmpty {
                    Color.clear.frame(height: 42)
                } else {
                    Button { tap(k) } label: {
                        Text(k)
                            .font(k == "⌫" ? .system(size: 18) : .mono(20, weight: .medium))
                            .foregroundStyle(Ink.bone)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(Ink.lamp, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tap(_ k: String) {
        failed = false
        if k == "⌫" {
            if !code.isEmpty { code.removeLast() }
        } else if code.count < 8 {
            code += k               // no auto-submit — user taps 配对 to confirm
        }
    }

    private func submit() {
        guard code.count == 8, !pairing else { return }
        pairing = true; failed = false
        store.pairWithCode(code) { ok in
            pairing = false
            if !ok { failed = true; code = "" }
        }
    }
}
