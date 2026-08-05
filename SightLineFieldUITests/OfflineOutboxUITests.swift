import XCTest

/// M4 offline-outbox smoke: proves a check-in performed while the outbox
/// drain is suppressed (i.e. the device never actually reaches the server)
/// still lands optimistically in the UI, and the pending write is visible in
/// Settings as a queued outbox item. Same live-backend contract as
/// `LoginSmokeUITests` — SKIPS when the paired server is unreachable, since
/// login must still succeed online before the outbox hold takes effect.
///
/// `-uitest-outbox-hold` (paired with `-uitest-reset`) tells the app to build
/// its outbox normally — queued writes are applied optimistically to local
/// state exactly as in production — but to suppress the background drain
/// that would otherwise flush those writes to the server. That isolates the
/// write path from the network entirely: this test proves the check-in
/// succeeds and is queued with zero network activity reaching the backend
/// for the write itself (only the login call touches the network).
final class OfflineOutboxUITests: XCTestCase {

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

    func testOfflineCheckInIsOptimisticAndQueued() async throws {
        guard await backendReachable() else {
            throw XCTSkip("Paired backend not reachable at \(Self.baseURL) — start it per README to run the smoke.")
        }

        let app = await XCUIApplication()
        await MainActor.run {
            // -uitest-outbox-hold: outbox writes go local-only, drain suppressed.
            app.launchArguments = ["-uitest-reset", "-uitest-outbox-hold", "-apiBaseURL", Self.baseURL.absoluteString]
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

            // Signed-in shell.
            let jobsTab = app.tabBars.buttons["Jobs"]
            XCTAssertTrue(jobsTab.waitForExistence(timeout: 15), "Tab shell did not appear after login")
            jobsTab.tap()

            // First job → detail → Check In → Confirm, entirely on-device.
            let firstJob = app.cells.firstMatch
            XCTAssertTrue(firstJob.waitForExistence(timeout: 10), "Job list did not populate")
            firstJob.tap()

            let checkIn = app.buttons["Check In"]
            XCTAssertTrue(checkIn.waitForExistence(timeout: 10), "Check In button did not appear on job detail")
            checkIn.tap()

            let confirm = app.buttons["Confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Check-in sheet did not appear")
            confirm.tap()

            // Optimistic: the session flips to Check Out immediately even though
            // the outbox drain is held and nothing has synced to the server.
            let checkOut = app.buttons["Check Out"]
            XCTAssertTrue(checkOut.waitForExistence(timeout: 10), "Check Out did not appear after offline check-in — optimistic write failed")

            // Settings: the pending write is visible in the outbox, proving the
            // check-in queued instead of silently vanishing or fake-succeeding.
            let settingsTab = app.tabBars.buttons["Settings"]
            XCTAssertTrue(settingsTab.waitForExistence(timeout: 5), "Settings tab not found")
            settingsTab.tap()

            let pending = app.descendants(matching: .any)["outbox-pending"]
            XCTAssertTrue(pending.waitForExistence(timeout: 10), "outbox-pending row did not appear in Settings")

            let label = pending.label.isEmpty ? (pending.value as? String ?? "") : pending.label
            XCTAssertFalse(label.isEmpty, "outbox-pending element has no label/value to report a count")
            let digits = label.compactMap { $0.wholeNumberValue }
            let pendingCount = digits.reduce(0) { $0 * 10 + $1 }
            XCTAssertGreaterThan(pendingCount, 0, "outbox-pending should reflect at least one queued item, got: \(label)")
        }
    }
}
