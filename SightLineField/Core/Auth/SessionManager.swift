import Foundation
import Observation

@Observable
@MainActor
final class SessionManager: TokenRefresher {
    enum State: Equatable {
        case signedOut
        case authenticating
        case signedIn(AccountContext)
    }

    private(set) var state: State = .signedOut
    var lastError: ApiError?

    private let gateway: AuthGateway
    private let tokenStore: TokenStore
    private let defaults: UserDefaults

    private static let contextKey = "accountContext"
    private var inFlightRefresh: Task<Bool, Never>?

    init(gateway: AuthGateway, tokenStore: TokenStore, defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.tokenStore = tokenStore
        self.defaults = defaults
    }

    /// A valid session requires both a keychain token pair and its persisted account context;
    /// either missing means the other is untrustworthy, so both are cleared.
    func bootstrap() async {
        guard tokenStore.load() != nil, let context = loadPersistedContext() else {
            clearAll()
            state = .signedOut
            return
        }
        state = .signedIn(context)
    }

    func login(email: String, password: String) async {
        state = .authenticating
        lastError = nil
        do {
            let (pair, context) = try await gateway.login(email: email, password: password, device: .current)
            try tokenStore.save(pair)
            persist(context)
            state = .signedIn(context)
        } catch {
            clearAll()
            state = .signedOut
            lastError = (error as? ApiError) ?? .network(error)
        }
    }

    func logout() async {
        if case .signedIn(let context) = state {
            await gateway.logout(sessionId: context.sessionId)
        }
        clearAll()
        state = .signedOut
    }

    /// Concurrent callers coalesce onto a single in-flight refresh: the first caller starts
    /// it and stashes the `Task` on the actor, later callers just await that same `Task` —
    /// so N concurrent callers still produce exactly one `gateway.refresh` call.
    nonisolated func refreshTokens() async -> Bool { await coalescedRefresh() }

    /// Called by `BearerAuthMiddleware` when a request still gets 401 after a successful
    /// refresh — the session itself was invalidated server-side (theft/reuse signal), not
    /// just the access token. Reuses the same clear-and-sign-out path as a rejected refresh.
    nonisolated func sessionInvalidated() async {
        await performSessionInvalidation()
    }

    private func performSessionInvalidation() {
        clearAll()
        state = .signedOut
    }

    private func coalescedRefresh() async -> Bool {
        if let inFlight = inFlightRefresh { return await inFlight.value }
        let task = Task { await performRefresh() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    /// Failure policy is split by cause: a network error is transient (offline/airplane
    /// mode) so the pair/context/state are kept for the field app to retry later. Any other
    /// rejection (unauthorized, server, decoding, ...) means the refresh token itself was
    /// consumed or revoked and can't be recovered from, so it's a theft signal — clear and
    /// sign out.
    private func performRefresh() async -> Bool {
        guard let pair = tokenStore.load() else {
            clearAll()
            state = .signedOut
            return false
        }
        do {
            let newPair = try await gateway.refresh(refreshToken: pair.refreshToken)
            do {
                try tokenStore.save(newPair)
            } catch {
                // The server already rotated the refresh token (the old one is now invalid)
                // but we failed to persist the new pair locally — either way the usable pair
                // is lost, so treat it the same as a rejection: clear and sign out.
                clearAll()
                state = .signedOut
                return false
            }
            return true
        } catch ApiError.network {
            return false
        } catch {
            clearAll()
            state = .signedOut
            return false
        }
    }

    private func persist(_ context: AccountContext) {
        guard let data = try? JSONEncoder().encode(context) else { return }
        defaults.set(data, forKey: Self.contextKey)
    }

    private func loadPersistedContext() -> AccountContext? {
        guard let data = defaults.data(forKey: Self.contextKey) else { return nil }
        return try? JSONDecoder().decode(AccountContext.self, from: data)
    }

    /// Tokens live only in the Keychain; the context is non-secret metadata mirrored to
    /// UserDefaults purely so `bootstrap()` can restore `state` without a network round trip.
    private func clearAll() {
        tokenStore.clear()
        defaults.removeObject(forKey: Self.contextKey)
    }
}
