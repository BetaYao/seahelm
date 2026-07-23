import SwiftUI

@main
struct SeahelmWatchApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Ink.ember)
                .preferredColorScheme(.dark)
                .task { store.start() }
        }
    }
}
