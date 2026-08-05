import Foundation
import SwiftData

/// App composition root: wires `AppEnvironment` → `KeychainTokenStore` → `Client` →
/// `LiveAuthGateway` → `SessionManager`, plus the SwiftData `ModelContainer`, and hands both
/// to `SightLineFieldApp` for injection into the SwiftUI environment.
///
/// **Construction-order cycle.** `ApiClientFactory.make` needs a `TokenRefresher` to build the
/// generated `Client` (it's baked into `BearerAuthMiddleware`, which retries a 401 once via
/// `refresher.refreshTokens()`). The only `TokenRefresher` in the app is `SessionManager`
/// itself — but `SessionManager.init` needs an `AuthGateway`, and the only `AuthGateway` is
/// `LiveAuthGateway`, which needs the `Client` that hasn't been built yet. Neither side can be
/// constructed first.
///
/// Broken with `SessionRefresherBox`, a tiny `TokenRefresher` shim built *before* the client:
/// it starts out with no session, is handed to `ApiClientFactory.make`, and then — once
/// `SessionManager` exists a few lines later — is pointed at it. The reference is `weak`, so
/// the box never keeps `SessionManager` alive (no retain cycle is possible even though
/// `SessionManager` transitively owns the `Client` that owns the middleware that owns the
/// box); it's a construction-order fix, not a lifetime one, since `AppDependencies` itself
/// holds the one strong reference to `session` for the app's lifetime.
@MainActor
final class AppDependencies {
    let session: SessionManager
    let client: Client
    let modelContainer: ModelContainer
    let syncEngine: SyncEngine
    let workLogActions: WorkLogActions
    let connectivity: Connectivity
    let biometricGate: BiometricGate
    let backgroundRefresher: BackgroundRefresher
    let photoActions: PhotoActions

    init(environment: AppEnvironment = .resolve(), inMemoryStore: Bool = false) {
        let tokenStore = KeychainTokenStore()

        // UITest isolation: wipe any persisted session before wiring anything, so every
        // UI-test launch starts signed out regardless of what a prior run left behind.
        let uitestReset = ProcessInfo.processInfo.arguments.contains("-uitest-reset")
        if uitestReset {
            tokenStore.clear()
            UserDefaults.standard.removeObject(forKey: "accountContext")
        }
        let refresherBox = SessionRefresherBox()

        let client = ApiClientFactory.make(environment: environment, tokenStore: tokenStore, refresher: refresherBox)
        let gateway = LiveAuthGateway(client: client)
        let session = SessionManager(gateway: gateway, tokenStore: tokenStore)
        refresherBox.session = session
        self.client = client
        self.session = session

        let container: ModelContainer
        do {
            container = try StoreContainer.make(inMemory: inMemoryStore)
        } catch {
            // A local SwiftData store failing to open (disk full, corrupt file, migration
            // failure) leaves the app with no usable data layer — nothing downstream can
            // recover from this, so fail fast rather than limp along without persistence.
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
        self.modelContainer = container

        let watermarks = SyncWatermarks(defaults: .standard)
        self.syncEngine = SyncEngine(
            backend: LiveSyncBackend(client: client),
            modelContext: container.mainContext,
            watermarks: watermarks
        )

        self.workLogActions = WorkLogActions(client: client, modelContext: container.mainContext)

        // M4b: photo uploads replay through the same outbox `WorkLogActions` writes into, so
        // both actions classes drain one queue instead of racing two.
        workLogActions.outboxWorker.photoGateway = LivePhotoUploadGateway(environment: environment, tokenStore: tokenStore)
        self.photoActions = PhotoActions(outboxWorker: workLogActions.outboxWorker, modelContext: container.mainContext)
        self.backgroundRefresher = BackgroundRefresher(outboxWorker: workLogActions.outboxWorker, syncEngine: syncEngine)

        // Mirrors the `-uitest-reset` isolation above: disabled entirely so an automated launch
        // never blocks on a biometric prompt it has no way to satisfy.
        self.biometricGate = BiometricGate(enabled: !uitestReset)

        self.connectivity = Connectivity()
        connectivity.onBecameOnline = { [weak workLogActions] in
            Task { await workLogActions?.outboxWorker.drain() }
        }

        // UITest hook (paired with `-uitest-reset`): suppresses the outbox drain so a queued
        // write stays local-only and observable in Settings instead of racing the live backend
        // — see `OfflineOutboxUITests`.
        if ProcessInfo.processInfo.arguments.contains("-uitest-outbox-hold") {
            workLogActions.outboxWorker.isHeld = true
        }

        // Every sign-out (explicit logout, expired bootstrap, 401 theft-signal) must leave no
        // trace of the prior account on a shared installer device: drop the delta watermarks so
        // the next sign-in does a full pull, and wipe the cached rows. Runs on the MainActor —
        // `clearAll` is only ever reached from MainActor-isolated SessionManager methods.
        session.onSignedOut = { [weak container] in
            watermarks.clearAll()
            guard let context = container?.mainContext else { return }
            try? context.delete(model: JobSummary.self)
            try? context.delete(model: Appointment.self)
            try? context.delete(model: WorkType.self)
            try? context.delete(model: WorkLog.self)
            try? context.delete(model: Surface.self)
        }
    }
}

/// `TokenRefresher` shim that breaks the `ApiClientFactory` ↔ `SessionManager` construction
/// cycle (see `AppDependencies` doc comment above). `@unchecked Sendable`: `session` is set
/// exactly once, synchronously, immediately after `SessionManager` is constructed and before
/// the box is handed to anything that could call `refreshTokens()` concurrently; every read
/// after that is a plain weak-reference load, no mutation races against it.
private final class SessionRefresherBox: TokenRefresher, @unchecked Sendable {
    weak var session: SessionManager?

    func refreshTokens() async -> Bool {
        guard let session else { return false }
        return await session.refreshTokens()
    }

    func sessionInvalidated() async {
        await session?.sessionInvalidated()
    }
}
