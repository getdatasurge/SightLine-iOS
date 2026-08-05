import SwiftUI

@main
@MainActor
struct SightLineFieldApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies.session)
                .environment(dependencies.syncEngine)
                .modelContainer(dependencies.modelContainer)
                .task { await dependencies.session.bootstrap() }
        }
    }
}
