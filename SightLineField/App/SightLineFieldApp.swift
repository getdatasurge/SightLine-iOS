import SwiftUI

@main
@MainActor
struct SightLineFieldApp: App {
    @State private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(dependencies.session)
                .environment(dependencies.syncEngine)
                .environment(dependencies.workLogActions)
                .environment(dependencies.workLogActions.outboxWorker)
                .environment(dependencies.biometricGate)
                .environment(dependencies.photoActions)
                .environment(dependencies.connectivity)
                .environment(\.apiClient, dependencies.client)
                .modelContainer(dependencies.modelContainer)
                .task { await dependencies.session.bootstrap() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await dependencies.workLogActions.outboxWorker.drain() }
                if case .signedIn = dependencies.session.state {
                    Task { await dependencies.biometricGate.requireUnlock() }
                }
            case .background:
                dependencies.biometricGate.lock()
                dependencies.backgroundRefresher.scheduleNext()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresher.taskIdentifier)) {
            await dependencies.backgroundRefresher.performRefresh()
            await dependencies.backgroundRefresher.scheduleNext()
        }
    }
}
