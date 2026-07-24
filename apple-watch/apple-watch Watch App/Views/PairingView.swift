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
    @State private var failReason = ""

    private var display: String {
        let d = Array(code)
        return (0..<8).map { i in i < d.count ? String(d[i]) : "·" }.joined()
    }

    private var brokerReady: Bool { store.conn == .connected }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("配对").font(.system(size: 16, weight: .semibold)).foregroundStyle(Ink.bone)
                    .padding(.top, 2)

                Text(display)
                    .font(.mono(22, weight: .semibold)).tracking(3)
                    .foregroundStyle(failed ? Ink.red : Ink.bone)

                statusRow

                keypad.padding(.top, 2).disabled(pairing || !brokerReady)

                OptButton(label: code.count == 8 ? "配对" : "还需 \(8 - code.count) 位",
                          style: code.count == 8 && brokerReady ? .fill : .ghost) { submit() }
                    .disabled(code.count != 8 || pairing || !brokerReady)
                    .padding(.top, 4)

                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.system(size: 8)).foregroundStyle(Ink.ash.opacity(0.4))
                    .padding(.top, 6)
            }
            .padding(.horizontal, 6)
        }
        .onChange(of: store.conn) { _, new in
            // Socket died mid-pair → clear the spinner instead of spinning to 60s.
            if pairing, new != .connected {
                pairing = false
                failed = true
                failReason = "连接断开，请重试"
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if failed {
            Text(failReason.isEmpty ? "码错误或已过期" : failReason)
                .font(.system(size: 11)).foregroundStyle(Ink.red)
                .multilineTextAlignment(.center)
        } else if pairing {
            HStack(spacing: 6) {
                ProgressView().tint(Ink.ember)
                Text("配对中…").font(.mono(11)).foregroundStyle(Ink.ash)
            }
        } else if !brokerReady {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().tint(Ink.ember)
                    Text(store.conn == .connecting ? "连接 gateway 中…" : "未连接，重试中…")
                        .font(.mono(10)).foregroundStyle(Ink.ash)
                }
                if let err = store.netError {
                    Text(err)
                        .font(.system(size: 10)).foregroundStyle(Ink.red)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            Text("Mac『生成短码』· 60s 内输入")
                .font(.mono(10)).foregroundStyle(Ink.ash).multilineTextAlignment(.center)
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
        failReason = ""
        if k == "⌫" {
            if !code.isEmpty { code.removeLast() }
        } else if code.count < 8 {
            code += k               // no auto-submit — user taps 配对 to confirm
        }
    }

    private func submit() {
        guard code.count == 8, !pairing, brokerReady else { return }
        pairing = true; failed = false; failReason = ""
        store.pairWithCode(code) { ok in
            pairing = false
            if !ok {
                failed = true
                failReason = brokerReady ? "码错误或已过期" : "连接断开，请重试"
                code = ""
            }
        }
    }
}
