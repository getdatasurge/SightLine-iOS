import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

enum ApiClientFactory {
    static func make(environment: AppEnvironment, tokenStore: TokenStore, refresher: TokenRefresher) -> Client {
        Client(
            serverURL: environment.baseURL.appending(path: "api/v1"),
            transport: URLSessionTransport(),
            middlewares: [BearerAuthMiddleware(tokenStore: tokenStore, refresher: refresher)]
        )
    }
}
