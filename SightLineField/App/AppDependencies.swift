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
    let modelContainer: ModelContainer

    init(environment: AppEnvironment = .resolve(), inMemoryStore: Bool = false) {
        let tokenStore = KeychainTokenStore()

        // UITest isolation: wipe any persisted session before wiring anything, so every
        // UI-test launch starts signed out regardless of what a prior run left behind.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            tokenStore.clear()
            UserDefaults.standard.removeObject(forKey: "accountContext")
        }
        let refresherBox = SessionRefresherBox()

        let client = ApiClientFactory.make(environment: environment, tokenStore: tokenStore, refresher: refresherBox)
        let gateway = LiveAuthGateway(client: client)
        let session = SessionManager(gateway: gateway, tokenStore: tokenStore)
        refresherBox.session = session
        self.session = session

        do {
            modelContainer = try StoreContainer.make(inMemory: inMemoryStore)
        } catch {
            // A local SwiftData store failing to open (disk full, corrupt file, migration
            // failure) leaves the app with no usable data layer — nothing downstream can
            // recover from this, so fail fast rather than limp along without persistence.
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
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
