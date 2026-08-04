import XCTest
@testable import SightLineField

final class StubAuthGateway: AuthGateway, @unchecked Sendable {
    var loginResult: Result<(TokenPair, AccountContext), Error>
    var refreshResult: Result<TokenPair, Error>
    var logoutThrows: Bool
    var refreshDelayNanoseconds: UInt64 = 0
    private(set) var logoutCallCount = 0
    private(set) var lastLogoutSessionId: String?
    private(set) var refreshCallCount = 0

    init(
        loginResult: Result<(TokenPair, AccountContext), Error> = .failure(ApiError.unauthorized),
        refreshResult: Result<TokenPair, Error> = .failure(ApiError.unauthorized),
        logoutThrows: Bool = false
    ) {
        self.loginResult = loginResult
        self.refreshResult = refreshResult
        self.logoutThrows = logoutThrows
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
}
