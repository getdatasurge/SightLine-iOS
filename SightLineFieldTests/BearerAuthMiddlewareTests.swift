import XCTest
import OpenAPIRuntime
import HTTPTypes
@testable import SightLineField

final class RefresherSpy: TokenRefresher, @unchecked Sendable {
    var result = false
    private(set) var calls = 0
    func refreshTokens() async -> Bool { calls += 1; return result }
}

final class BearerAuthMiddlewareTests: XCTestCase {
    func run(_ mw: BearerAuthMiddleware, statuses: [Int], onRequest: ((HTTPRequest) -> Void)? = nil) async throws -> HTTPResponse {
        var remaining = statuses
        let (req, url) = (HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/jobs"), URL(string: "http://x")!)
        return try await mw.intercept(req, body: nil, baseURL: url, operationID: "listJobs") { request, _, _ in
            onRequest?(request)
            return (HTTPResponse(status: .init(code: remaining.removeFirst())), nil)
        }.0
    }

    func testInjectsBearerHeader() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "slm_a.1", refreshToken: "r"))
        var seen: String?
        _ = try await run(BearerAuthMiddleware(tokenStore: store, refresher: RefresherSpy()), statuses: [200]) {
            seen = $0.headerFields[.authorization]
        }
        XCTAssertEqual(seen, "Bearer slm_a.1")
    }

    func testRefreshesOnceAndReplaysOn401() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r"))
        let spy = RefresherSpy(); spy.result = true
        let resp = try await run(BearerAuthMiddleware(tokenStore: store, refresher: spy), statuses: [401, 200])
        XCTAssertEqual(resp.status.code, 200)
        XCTAssertEqual(spy.calls, 1)
    }

    func testSecond401Propagates() async throws {
        let store = InMemoryTokenStore()
        try store.save(TokenPair(accessToken: "old", refreshToken: "r"))
        let spy = RefresherSpy(); spy.result = true
        let resp = try await run(BearerAuthMiddleware(tokenStore: store, refresher: spy), statuses: [401, 401])
        XCTAssertEqual(resp.status.code, 401)
        XCTAssertEqual(spy.calls, 1)
    }
}
