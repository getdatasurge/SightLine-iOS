import Foundation

enum ApiError: Error {
    case network(Error)
    case unauthorized
    case server(status: Int)
    case decoding
}
