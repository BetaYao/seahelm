import SwiftUI

/// Free-text reply (Control tier). On watchOS a `TextField` presents the native
/// input (dictation / scribble / emoji) — no custom waveform needed.
struct ReplyView: View {
    @EnvironmentObject var store: Store
    let slot: String
    @Binding var path: [Route]
    @State private var text = ""

    private var target: String { store.pane(slot).map { AgentStyle.of($0.pane.agent).name } ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("对 \(target) 说…").font(.mono(11)).foregroundStyle(Ink.ash)

                TextField("听写回复", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Ink.lamp, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.stone, lineWidth: 1))

                HStack(spacing: 10) {
                    OptButton(label: "取消", style: .ghost) { if !path.isEmpty { path.removeLast() } }
                    Button {
                        if let p = store.pane(slot)?.pane { store.send(p, text: text) }
                        if !path.isEmpty { path.removeLast() }
                    } label: {
                        Text("发送").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(text.isEmpty ? Ink.stone : Ink.ember,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(text.isEmpty)
                }
            }
        }
        .navigationTitle("听写")
    }
}
