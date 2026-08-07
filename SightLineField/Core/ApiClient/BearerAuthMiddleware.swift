import Foundation
import OpenAPIRuntime
import HTTPTypes

protocol TokenRefresher: Sendable {
    func refreshTokens() async -> Bool
    /// Called when a request still gets 401 after a successful `refreshTokens()` — the
    /// freshly reissued access token was itself rejected, which means the *session* (not
    /// just the token) has been invalidated server-side, e.g. stolen/reused refresh token.
    /// A plain 401 with a *failed* refresh must NOT trigger this.
    func sessionInvalidated() async
}

struct BearerAuthMiddleware: ClientMiddleware {
    let tokenStore: TokenStore
    let refresher: TokenRefresher

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        func authed(_ r: HTTPRequest) -> HTTPRequest {
            var r = r
            if let pair = tokenStore.load() {
                r.headerFields[.authorization] = "Bearer \(pair.accessToken)"
            }
            return r
        }
        let (response, responseBody) = try await next(authed(request), body, baseURL)
        guard response.status.code == 401, await refresher.refreshTokens() else {
            return (response, responseBody)
        }
        let (retryResponse, retryBody) = try await next(authed(request), body, baseURL)
        if retryResponse.status.code == 401 {
            await refresher.sessionInvalidated()
        }
        return (retryResponse, retryBody)
    }
}
