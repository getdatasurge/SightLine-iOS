import Foundation
import OpenAPIRuntime
import HTTPTypes

protocol TokenRefresher: Sendable {
    func refreshTokens() async -> Bool
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
        return try await next(authed(request), body, baseURL)
    }
}
