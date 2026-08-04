import Foundation

struct TokenPair: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

protocol TokenStore: Sendable {
    func load() -> TokenPair?
    func save(_ pair: TokenPair) throws
    func clear()
}
