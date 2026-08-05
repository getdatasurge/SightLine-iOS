import XCTest
@testable import SightLineField

final class StubAuthGateway: AuthGateway, @unchecked Sendable {
    var loginResult: Result<(TokenPair, AccountContext), Error>
    var refreshResult: Result<TokenPair, Error>
    var logoutThrows: Bool
    var fetchIdentityResult: Result<Identity, Error>
    var refreshDelayNanoseconds: UInt64 = 0
    private(set) var logoutCallCount = 0
    private(set) var lastLogoutSessionId: String?
    private(set) var refreshCallCount = 0
    private(set) var fetchIdentityCallCount = 0

    init(
        loginResult: Result<(TokenPair, AccountContext), Error> = .failure(ApiError.unauthorized),
        refreshResult: Result<TokenPair, Error> = .failure(ApiError.unauthorized),
        logoutThrows: Bool = false,
        fetchIdentityResult: Result<Identity, Error> = .success(Identity(technicianId: nil, capabilities: []))
    ) {
        self.loginResult = loginResult
        self.refreshResult = refreshResult
        self.logoutThrows = logoutThrows
        self.fetchIdentityResult = fetchIdentityResult
    }

    func login(email: String, password: String, device: DeviceInfo) async throws -> (TokenPair, AccountContext) {
        try loginResult.get()
    }

    func refresh(refreshToken: String) async throws -> TokenPair {
        refreshCallCount += 1
        if refreshDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: refreshDelayNanoseconds)
        }
        return try refreshResult.get()
    }

    func logout(sessionId: String) async {
        // `logoutThrows` documents that a real network failure occurred and was swallowed —
        // the protocol has no throwing path (matches LiveAuthGateway's `try?`), so it's
        // recorded here only for test observability, not control flow.
        logoutCallCount += 1
        lastLogoutSessionId = sessionId
    }

    func fetchIdentity() async throws -> Identity {
        fetchIdentityCallCount += 1
        return try fetchIdentityResult.get()
    }
}

@MainActor
final class SessionManagerTests: XCTestCase {
    func ctx(sessionId: String = "s1") -> AccountContext {
        AccountContext(accountId: "a1", email: "t@x.com", businessId: "b1", sessionId: sessionId,
                       technicianId: nil, capabilities: [])
    }

    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SessionManagerTests.\(UUID().uuidString)")!
    }

    func testLoginSuccessStoresPairAndSignsIn() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        await sm.login(email: "t@x.com", password: "pw")
        XCTAssertEqual(sm.state, .signedIn(ctx()))
        XCTAssertEqual(store.load(), TokenPair(accessToken: "a", refreshToken: "r"))
    }

    func testLoginFailureStaysSignedOutWithError() async {
        let sm = SessionManager(gateway: StubAuthGateway(loginResult: .failure(ApiError.unauthorized)),
                                 tokenStore: InMemoryTokenStore(), defaults: freshDefaults())
        await sm.login(email: "t@x.com", password: "bad")
        XCTAssertEqual(sm.state, .signedOut)
        XCTAssertNotNil(sm.lastError)
    }

    func testRefreshRotationSavesNewPair() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r1"))
        let gw = StubAuthGateway(refreshResult: .success(TokenPair(accessToken: "new", refreshToken: "r2")))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        let ok = await sm.refreshTokens()
        XCTAssertTrue(ok)
        XCTAssertEqual(store.load(), TokenPair(accessToken: "new", refreshToken: "r2"))
    }

    func testRefreshFailureClearsAndSignsOut() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r1"))
        let sm = SessionManager(gateway: StubAuthGateway(refreshResult: .failure(ApiError.unauthorized)),
                                 tokenStore: store, defaults: freshDefaults())
        let ok = await sm.refreshTokens()
        XCTAssertFalse(ok)
        XCTAssertNil(store.load())
        XCTAssertEqual(sm.state, .signedOut)
    }

    func testLogoutClearsEvenIfNetworkFails() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())),
                                  logoutThrows: true)
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        await sm.login(email: "t@x.com", password: "pw")
        await sm.logout()
        XCTAssertNil(store.load())
        XCTAssertEqual(sm.state, .signedOut)
        XCTAssertEqual(gw.logoutCallCount, 1)
        XCTAssertEqual(gw.lastLogoutSessionId, "s1")
    }

    func testBootstrapWithPersistedContextSignsIn() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "a", refreshToken: "r"))
        let defaults = freshDefaults()
        defaults.set(try JSONEncoder().encode(ctx()), forKey: "accountContext")
        let sm = SessionManager(gateway: StubAuthGateway(), tokenStore: store, defaults: defaults)
        await sm.bootstrap()
        XCTAssertEqual(sm.state, .signedIn(ctx()))
    }

    func testBootstrapWithoutPersistedContextSignsOutAndClears() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "a", refreshToken: "r"))
        let sm = SessionManager(gateway: StubAuthGateway(), tokenStore: store, defaults: freshDefaults())
        await sm.bootstrap()
        XCTAssertEqual(sm.state, .signedOut)
        XCTAssertNil(store.load())
    }

    func testConcurrentRefreshCoalescesIntoOneGatewayCall() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r1"))
        let gw = StubAuthGateway(refreshResult: .success(TokenPair(accessToken: "new", refreshToken: "r2")))
        gw.refreshDelayNanoseconds = 50_000_000 // 50ms: wide enough for both callers to overlap
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        async let first = sm.refreshTokens()
        async let second = sm.refreshTokens()
        let (firstOk, secondOk) = await (first, second)
        XCTAssertTrue(firstOk)
        XCTAssertTrue(secondOk)
        XCTAssertEqual(gw.refreshCallCount, 1)
        XCTAssertEqual(store.load(), TokenPair(accessToken: "new", refreshToken: "r2"))
    }

    func testRefreshNetworkErrorKeepsSession() async throws {
        let store = InMemoryTokenStore()
        let pair = TokenPair(accessToken: "old", refreshToken: "r1")
        try store.save(pair)
        let gw = StubAuthGateway(refreshResult: .failure(ApiError.network(URLError(.notConnectedToInternet))))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        let ok = await sm.refreshTokens()
        XCTAssertFalse(ok)
        XCTAssertEqual(store.load(), pair)
        XCTAssertEqual(sm.state, .signedOut)
    }

    func testBootstrapWithContextButNoPairSignsOutAndClearsContext() async throws {
        let store = InMemoryTokenStore()
        let defaults = freshDefaults()
        defaults.set(try JSONEncoder().encode(ctx()), forKey: "accountContext")
        let sm = SessionManager(gateway: StubAuthGateway(), tokenStore: store, defaults: defaults)
        await sm.bootstrap()
        XCTAssertEqual(sm.state, .signedOut)
        XCTAssertNil(defaults.data(forKey: "accountContext"))
    }

    func testSessionInvalidatedClearsStoreContextAndState() async throws {
        let store = InMemoryTokenStore()
        let defaults = freshDefaults()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: defaults)
        await sm.login(email: "t@x.com", password: "pw")
        XCTAssertEqual(sm.state, .signedIn(ctx()))
        await sm.sessionInvalidated()
        XCTAssertNil(store.load())
        XCTAssertEqual(sm.state, .signedOut)
        XCTAssertNil(defaults.data(forKey: "accountContext"))
    }

    func testLoginMergesIdentityFromFetchIdentity() async throws {
        let store = InMemoryTokenStore()
        let identity = Identity(technicianId: "tech-1", capabilities: ["jobs:read"])
        let gw = StubAuthGateway(
            loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())),
            fetchIdentityResult: .success(identity)
        )
        let defaults = freshDefaults()
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: defaults)
        await sm.login(email: "t@x.com", password: "pw")
        let expected = AccountContext(accountId: "a1", email: "t@x.com", businessId: "b1", sessionId: "s1",
                                       technicianId: "tech-1", capabilities: ["jobs:read"])
        XCTAssertEqual(sm.state, .signedIn(expected))
        XCTAssertEqual(gw.fetchIdentityCallCount, 1)
        let persisted = try JSONDecoder().decode(AccountContext.self, from: try XCTUnwrap(defaults.data(forKey: "accountContext")))
        XCTAssertEqual(persisted, expected)
    }

    func testBootstrapMergesIdentityFromFetchIdentity() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "a", refreshToken: "r"))
        let defaults = freshDefaults()
        defaults.set(try JSONEncoder().encode(ctx()), forKey: "accountContext")
        let identity = Identity(technicianId: "tech-2", capabilities: ["jobs:read", "jobs:write"])
        let gw = StubAuthGateway(fetchIdentityResult: .success(identity))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: defaults)
        await sm.bootstrap()
        let expected = AccountContext(accountId: "a1", email: "t@x.com", businessId: "b1", sessionId: "s1",
                                       technicianId: "tech-2", capabilities: ["jobs:read", "jobs:write"])
        XCTAssertEqual(sm.state, .signedIn(expected))
    }

    func testIdentityFetchFailureLeavesSignedInUnchanged() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(
            loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())),
            fetchIdentityResult: .failure(ApiError.network(URLError(.notConnectedToInternet)))
        )
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        await sm.login(email: "t@x.com", password: "pw")
        XCTAssertEqual(sm.state, .signedIn(ctx()))
        XCTAssertEqual(gw.fetchIdentityCallCount, 1)
    }

    func testPersistedContextRoundTripsTechnicianIdAndCapabilities() throws {
        let context = AccountContext(accountId: "a1", email: "t@x.com", businessId: "b1", sessionId: "s1",
                                      technicianId: "tech-9", capabilities: ["jobs:read", "jobs:write"])
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(AccountContext.self, from: data)
        XCTAssertEqual(decoded, context)
        XCTAssertEqual(decoded.technicianId, "tech-9")
        XCTAssertEqual(decoded.capabilities, ["jobs:read", "jobs:write"])
    }

    func testLogoutFiresOnSignedOutExactlyOnce() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        var callCount = 0
        sm.onSignedOut = { callCount += 1 }
        await sm.login(email: "t@x.com", password: "pw")
        await sm.logout()
        XCTAssertEqual(callCount, 1)
    }

    func testSessionInvalidatedFiresOnSignedOut() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        var callCount = 0
        sm.onSignedOut = { callCount += 1 }
        await sm.login(email: "t@x.com", password: "pw")
        await sm.sessionInvalidated()
        XCTAssertEqual(callCount, 1)
    }

    func testSuccessfulLoginDoesNotFireOnSignedOut() async throws {
        let store = InMemoryTokenStore()
        let gw = StubAuthGateway(loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), ctx())))
        let sm = SessionManager(gateway: gw, tokenStore: store, defaults: freshDefaults())
        var callCount = 0
        sm.onSignedOut = { callCount += 1 }
        await sm.login(email: "t@x.com", password: "pw")
        XCTAssertEqual(sm.state, .signedIn(ctx()))
        XCTAssertEqual(callCount, 0)
    }

    func testBootstrapWithoutPersistedContextFiresOnSignedOut() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "a", refreshToken: "r"))
        let sm = SessionManager(gateway: StubAuthGateway(), tokenStore: store, defaults: freshDefaults())
        var callCount = 0
        sm.onSignedOut = { callCount += 1 }
        await sm.bootstrap()
        XCTAssertEqual(callCount, 1)
    }
}
