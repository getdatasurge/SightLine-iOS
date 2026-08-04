import XCTest
@testable import SightLineField

@MainActor
final class LoginViewModelTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "LoginViewModelTests.\(UUID().uuidString)")!
    }

    func testFieldsFilledRequiresBothFields() {
        let vm = LoginViewModel()
        XCTAssertFalse(vm.fieldsFilled)
        vm.email = "tech@example.com"
        XCTAssertFalse(vm.fieldsFilled)
        vm.password = "hunter2"
        XCTAssertTrue(vm.fieldsFilled)
    }

    func testSubmitCallsSessionLoginWithFieldValues() async {
        let expectedContext = AccountContext(
            accountId: "1", email: "tech@example.com", businessId: "b", sessionId: "s",
            technicianId: nil, capabilities: []
        )
        let gw = StubAuthGateway(
            loginResult: .success((TokenPair(accessToken: "a", refreshToken: "r"), expectedContext))
        )
        let session = SessionManager(gateway: gw, tokenStore: InMemoryTokenStore(), defaults: freshDefaults())

        let vm = LoginViewModel()
        vm.email = "tech@example.com"
        vm.password = "hunter2"
        await vm.submit(session: session)

        XCTAssertEqual(session.state, .signedIn(expectedContext))
    }

    func testSubmitNoOpsWhenFieldsIncomplete() async {
        // Default StubAuthGateway.loginResult is `.failure(.unauthorized)`; if `submit` ever
        // called through to `session.login` despite incomplete fields, `lastError` would flip
        // non-nil — so "state stays signedOut with no error" is the no-op signal.
        let gw = StubAuthGateway()
        let session = SessionManager(gateway: gw, tokenStore: InMemoryTokenStore(), defaults: freshDefaults())

        let vm = LoginViewModel()
        vm.email = "tech@example.com"
        // password left blank
        await vm.submit(session: session)

        XCTAssertEqual(session.state, .signedOut)
        XCTAssertNil(session.lastError)
    }

    func testErrorMessageMapping() {
        XCTAssertNil(LoginViewModel.errorMessage(for: nil))
        XCTAssertEqual(LoginViewModel.errorMessage(for: .unauthorized), "Wrong email or password")
        XCTAssertEqual(LoginViewModel.errorMessage(for: .network(URLError(.notConnectedToInternet))), "Can't reach server")
        XCTAssertEqual(LoginViewModel.errorMessage(for: .server(status: 500)), "Something went wrong. Please try again.")
        XCTAssertEqual(LoginViewModel.errorMessage(for: .decoding), "Something went wrong. Please try again.")
    }
}
