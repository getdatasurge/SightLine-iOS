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

    /// One-time-use refresh-token rotation: any failure clears the store and signs out
    /// (theft signal) rather than retrying, since a used-up or revoked refresh token can't
    /// be recovered from.
    nonisolated func refreshTokens() async -> Bool { await performRefresh() }

    private func performRefresh() async -> Bool {
        guard let pair = tokenStore.load() else {
            clearAll()
            state = .signedOut
            return false
        }
        do {
            let newPair = try await gateway.refresh(refreshToken: pair.refreshToken)
            try tokenStore.save(newPair)
            return true
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
