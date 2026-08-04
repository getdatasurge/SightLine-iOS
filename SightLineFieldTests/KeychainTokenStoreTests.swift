import XCTest
@testable import SightLineField

final class KeychainTokenStoreTests: XCTestCase {
    let store = KeychainTokenStore(service: "com.getdatasurge.sightline.field.tests")
    override func tearDown() { store.clear() }

    func testRoundTrip() throws {
        let pair = TokenPair(accessToken: "slm_a.1", refreshToken: "slm_r.2")
        try store.save(pair)
        XCTAssertEqual(store.load(), pair)
    }
    func testOverwrite() throws {
        try store.save(TokenPair(accessToken: "a", refreshToken: "b"))
        try store.save(TokenPair(accessToken: "c", refreshToken: "d"))
        XCTAssertEqual(store.load(), TokenPair(accessToken: "c", refreshToken: "d"))
    }
    func testClear() throws {
        try store.save(TokenPair(accessToken: "a", refreshToken: "b"))
        store.clear()
        XCTAssertNil(store.load())
    }
}
