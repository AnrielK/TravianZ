import SwiftUI

@main
@MainActor
struct TravianZApp: App {
    @State private var runtime = GameRuntime.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(runtime)
        }
    }
}
