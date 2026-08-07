import SwiftUI

@main
@MainActor
struct SightLineFieldApp: App {
    @State private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    /// A unit-test run injects its bundle into this app as the test host, so `body` renders and
    /// the launch side-effects fire the moment an `async @MainActor` test yields the main actor —
    /// pure interference with logic tests, and on newer simulator OSes the login scene's custom-
    /// font rendering under XCTest's cooperatively-scheduled main actor traps the host mid-test.
    /// `XCTestConfigurationFilePath` is set ONLY for the unit-test host process — a UITest runs
    /// the app as a separate process without it, and a normal launch never has it — so both
    /// render the real scene unchanged.
    private static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if Self.isRunningUnitTests {
                // Unit-test host: render nothing and skip launch side-effects. Unit tests
                // exercise types directly; booting the production scene here only runs when an
                // async test yields the main actor and, on newer simulator OSes, traps the host
                // while rendering the custom-font login screen mid-test.
                Color.clear
            } else {
                RootView()
                    .environment(dependencies.session)
                    .environment(dependencies.syncEngine)
                    .environment(dependencies.workLogActions)
                    .environment(dependencies.workLogActions.outboxWorker)
                    .environment(dependencies.biometricGate)
                    .environment(dependencies.photoActions)
                    .environment(dependencies.elevationActions)
                    .environment(dependencies.surfaceActions)
                    .environment(dependencies.connectivity)
                    .environment(\.apiClient, dependencies.client)
                    .modelContainer(dependencies.modelContainer)
                    .task { await dependencies.session.bootstrap() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard !Self.isRunningUnitTests else { return }
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
