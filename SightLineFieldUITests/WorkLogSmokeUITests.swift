import XCTest

/// End-to-end M3 smoke: check in on a job through the real UI, verify the row
/// server-side, then check out with a quantity. Same live-backend contract as
/// `LoginSmokeUITests` — SKIPS when the paired server is unreachable.
final class WorkLogSmokeUITests: XCTestCase {

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

    /// Device-session token for server-side verification, minted by the test itself.
    private func deviceToken() async throws -> String {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/v1/device-auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"email":"marco@demo.sightline.app","password":"demo1234","device":{"name":"m3-smoke-verify"}}"#.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let token = (json["data"] as! [String: Any])["accessToken"] as! String
        return token
    }

    private func myOpenWorkLog(token: String) async throws -> [String: Any]? {
        var request = URLRequest(url: Self.baseURL.appending(path: "api/v1/work-logs").appending(queryItems: [URLQueryItem(name: "technicianId", value: "me"), URLQueryItem(name: "status", value: "CHECKED_IN")]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rows = json["data"] as! [[String: Any]]
        return rows.first
    }

    func testTechnicianChecksInAndOutOnAJob() async throws {
        guard await backendReachable() else {
            throw XCTSkip("Paired backend not reachable at \(Self.baseURL) — start it per README to run the smoke.")
        }
        let token = try await deviceToken()

        // Start clean: no lingering CHECKED_IN session for this technician.
        if let open = try await myOpenWorkLog(token: token) {
            var request = URLRequest(url: Self.baseURL.appending(path: "api/v1/work-logs/\(open["id"] as! String)/check-out"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            _ = try await URLSession.shared.data(for: request)
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
            app.buttons["Log In"].tap()

            // Jobs tab → first job → Check In.
            XCTAssertTrue(app.tabBars.buttons["Jobs"].waitForExistence(timeout: 15), "Tab shell did not appear")
            app.tabBars.buttons["Jobs"].tap()
            let firstJob = app.cells.firstMatch
            XCTAssertTrue(firstJob.waitForExistence(timeout: 10), "Job list did not populate")
            firstJob.tap()

            let checkIn = app.buttons["Check In"]
            XCTAssertTrue(checkIn.waitForExistence(timeout: 10), "Check In button did not appear on job detail")
            checkIn.tap()

            let confirm = app.buttons["Confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Check-in sheet did not appear")
            confirm.tap()

            // Success flips the action to Check Out.
            let checkOut = app.buttons["Check Out"]
            XCTAssertTrue(checkOut.waitForExistence(timeout: 10), "Check Out did not appear after check-in")
        }

        // Server-side: the UI's check-in landed with the session's technician.
        let open = try await myOpenWorkLog(token: token)
        XCTAssertNotNil(open, "check-in visible in web API after UI action")
        XCTAssertEqual(open?["technicianId"] as? String, "seed-demo-tech-1")

        // Check out through the UI with a quantity.
        await MainActor.run {
            app.buttons["Check Out"].tap()
            let confirm = app.buttons["Confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Check-out sheet did not appear")
            let quantity = app.textFields.firstMatch
            if quantity.waitForExistence(timeout: 2) {
                quantity.tap()
                quantity.typeText("7.5")
            }
            confirm.tap()

            let checkInAgain = app.buttons["Check In"]
            XCTAssertTrue(checkInAgain.waitForExistence(timeout: 10), "Check In should return after check-out")
        }

        // Server-side: the session is closed with the quantity.
        var request = URLRequest(url: Self.baseURL.appending(path: "api/v1/work-logs").appending(queryItems: [URLQueryItem(name: "technicianId", value: "me")]))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rows = json["data"] as! [[String: Any]]
        let closed = rows.first { $0["id"] as? String == open?["id"] as? String }
        XCTAssertEqual(closed?["status"] as? String, "CHECKED_OUT")
        XCTAssertEqual(closed?["quantity"] as? Double, 7.5)
    }
}
