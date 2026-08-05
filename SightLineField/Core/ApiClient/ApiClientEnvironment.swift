import SwiftUI

/// The generated `Client` is a value type (not `@Observable`), so it rides the classic
/// `EnvironmentKey` route rather than the `.environment(Object.self)` observation route the
/// session/sync engines use. One instance lives in `AppDependencies` for the app's lifetime —
/// views that need direct reads (e.g. the Job Card) pull it from here instead of building
/// throwaway clients, so the shared `BearerAuthMiddleware` refresh chain stays in play.
private struct ApiClientKey: EnvironmentKey {
    static let defaultValue: Client? = nil
}

extension EnvironmentValues {
    var apiClient: Client? {
        get { self[ApiClientKey.self] }
        set { self[ApiClientKey.self] = newValue }
    }
}
