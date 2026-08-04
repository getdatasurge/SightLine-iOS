import XCTest
@testable import SightLineField

final class AppEnvironmentTests: XCTestCase {
    func testDefaultDebugBaseURL() {
        let env = AppEnvironment.resolve(arguments: [])
        XCTAssertEqual(env.baseURL.absoluteString, "http://localhost:3005")
    }
    func testLaunchArgumentOverride() {
        let env = AppEnvironment.resolve(arguments: ["-apiBaseURL", "https://staging.example.com"])
        XCTAssertEqual(env.baseURL.absoluteString, "https://staging.example.com")
    }
    func testMalformedOverrideFallsBackToDefault() {
        let env = AppEnvironment.resolve(arguments: ["-apiBaseURL", ""])
        XCTAssertEqual(env.baseURL.absoluteString, "http://localhost:3005")
    }
}
