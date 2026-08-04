import Foundation

struct AppEnvironment: Sendable {
    let baseURL: URL

    static let `default` = AppEnvironment(baseURL: defaultBaseURL)

    private static var defaultBaseURL: URL {
        #if DEBUG
        URL(string: "http://localhost:3005")!
        #else
        URL(string: "https://staging-placeholder.sightline.invalid")! // TBD host is intentional: Release target unset until staging exists (spec: non-blocking)
        #endif
    }

    static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        if let i = arguments.firstIndex(of: "-apiBaseURL"),
           arguments.indices.contains(i + 1),
           let url = URL(string: arguments[i + 1]),
           url.scheme != nil {
            return AppEnvironment(baseURL: url)
        }
        return .default
    }
}
