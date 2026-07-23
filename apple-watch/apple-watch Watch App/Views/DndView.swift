import SwiftUI

struct DndView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(store.dnd.on ? Ink.ember : Ink.lamp)
                        .frame(width: 84, height: 84)
                        .shadow(color: store.dnd.on ? Ink.ember.opacity(0.45) : .clear, radius: 12)
                    Image(systemName: "moon.fill").font(.system(size: 30))
                        .foregroundStyle(store.dnd.on ? .white : Ink.ash)
                }
                .padding(.top, 6)

                if store.dnd.on {
                    Text("专注中").font(.system(size: 19, weight: .semibold)).foregroundStyle(Ink.bone)
                    Text("剩 \(store.dnd.minutes) 分 · 已拦截 \(store.dnd.blocked) 条通知")
                        .font(.system(size: 13)).foregroundStyle(Ink.ash)
                    OptButton(label: "结束专注", style: .ghost) { store.setDnd(on: false) }
                        .padding(.top, 8)
                } else {
                    Text("开启专注").font(.system(size: 19, weight: .semibold)).foregroundStyle(Ink.bone)
                    Text("期间只放行 2FA 与危险确认").font(.system(size: 13)).foregroundStyle(Ink.ash)
                    HStack(spacing: 8) {
                        ForEach([25, 45, 60], id: \.self) { m in
                            Button { store.setDnd(on: true, minutes: m) } label: {
                                Text("\(m)分").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(Ink.ember, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
        .navigationTitle("专注勿扰")
    }
}
