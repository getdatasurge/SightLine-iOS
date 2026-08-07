import SwiftUI
#if canImport(UIKit)
import UIKit
import BackgroundTasks
#endif

/// Process entry point. Under a unit-test run the test bundle is injected into this app as its
/// host, so booting the real SwiftUI scene + launch side-effects (`session.bootstrap()`,
/// scene-phase biometric, `AppDependencies` construction, custom-font rendering) races the
/// tests: it only runs once an async `@MainActor` test yields the main actor, and on newer
/// simulator OSes (CI: Xcode 16.4 / iOS 26.2) that first-frame presentation crashes the host
/// mid-test — a launch-timing race, not any test's own logic (the SIGTRAP lands on whichever
/// async test happens to be executing, so it moves run to run). So under tests we launch a bare
/// `UIApplication` with an inert delegate: no scene, no window, no launch work, nothing to race.
///
/// `XCTestConfigurationFilePath` is set only for the unit-test host process — a UITest launches
/// the app as a separate process without it, and a normal launch never has it — so both get the
/// real `SightLineFieldApp`.
@main
enum AppMain {
    static func main() {
        #if canImport(UIKit)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            _ = UIApplicationMain(
                CommandLine.argc, CommandLine.unsafeArgv, nil,
                NSStringFromClass(UnitTestHostAppDelegate.self)
            )
            return
        }
        #endif
        SightLineFieldApp.main()
    }
}

#if canImport(UIKit)
/// Inert delegate for the unit-test host launch above — creates no window/scene, so the app
/// process is a bare shell XCTest injects into and runs logic tests against, with no scene to
/// race them. It does register the one background-task identifier the real app registers (via
/// `SightLineFieldApp`'s `.backgroundTask` scene modifier), so BG-scheduler unit tests see the
/// same "identifier registered, `submit` merely unavailable on the simulator" environment they
/// did when hosted in the full app. Without that registration `BGTaskScheduler.submit` raises an
/// ObjC "no launch handler registered" exception (uncatchable by Swift `do/catch`) instead of
/// the Swift error `BackgroundRefresher.scheduleNext()` swallows.
final class UnitTestHostAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefresher.taskIdentifier, using: nil
        ) { _ in }
        return true
    }
}
#endif

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
                .environment(dependencies.elevationActions)
                .environment(dependencies.surfaceActions)
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
