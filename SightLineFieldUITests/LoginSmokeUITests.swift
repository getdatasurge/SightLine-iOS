import XCTest

/// End-to-end login smoke against a live backend (M2 skeleton DoD item).
///
/// Requires a server running the `integration/field-app` branch on the host:
/// `PORT=3005 next start` (see README "Dev server pairing") with the seeded
/// demo tenant (`prisma/seed.ts` — technician marco@demo.sightline.app).
/// The test SKIPS (not fails) when the backend is unreachable so the suite
/// stays green in CI, where no paired server exists.
final class LoginSmokeUITests: XCTestCase {

    private static let baseURL = URL(string: "http://localhost:3005")!

    override func setUp() {
        continueAfterFailure = false
    }

    private func backendReachable() async -> Bool {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/v1/openapi"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func testTechnicianSignsInAndSeesTabShell() async throws {
        guard await backendReachable() else {
            throw XCTSkip("Paired backend not reachable at \(Self.baseURL) — start it per README to run the smoke.")
        }

        let app = await XCUIApplication()
        await MainActor.run {
            app.launchArguments = ["-apiBaseURL", Self.baseURL.absoluteString, "-uitest-reset"]
            app.launch()

            let email = app.textFields["Email"]
            XCTAssertTrue(email.waitForExistence(timeout: 10), "Login screen did not appear")
            email.tap()
            email.typeText("marco@demo.sightline.app")

            let password = app.secureTextFields["Password"]
            password.tap()
            password.typeText("demo1234")

            let logIn = app.buttons["Log In"]
            XCTAssertTrue(logIn.isEnabled, "Log In should enable once both fields are filled")
            logIn.tap()

            // Signed-in shell: tab bar with all three tabs.
            let scheduleTab = app.tabBars.buttons["Schedule"]
            XCTAssertTrue(scheduleTab.waitForExistence(timeout: 15), "Tab shell did not appear after login")
            XCTAssertTrue(app.tabBars.buttons["Jobs"].exists)
            XCTAssertTrue(app.tabBars.buttons["Work Logs"].exists)
        }
    }
}
