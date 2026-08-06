import XCTest

/// M5a offline-elevation-create smoke: proves adding a field-discovered elevation while the
/// outbox drain is suppressed still lands optimistically in `JobElevationsView`, and the pending
/// write is visible in Settings as a queued outbox item. Same live-backend contract as
/// `OfflineOutboxUITests` — SKIPS when the paired server is unreachable, since login must still
/// succeed online before the outbox hold takes effect.
///
/// `-uitest-outbox-hold` (paired with `-uitest-reset`) tells the app to build its outbox
/// normally — the elevation is inserted locally exactly as in production — but to suppress the
/// background drain that would otherwise flush the `.elevationCreate` write to the server. That
/// isolates the write path from the network entirely: this test proves the add succeeds and is
/// queued with zero network activity reaching the backend for the write itself (only the login
/// call, plus whatever building/elevation sync already ran, touches the network).
final class OfflineElevationUITests: XCTestCase {

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

    func testOfflineElevationCreateIsOptimisticAndQueued() async throws {
        guard await backendReachable() else {
            throw XCTSkip("Paired backend not reachable at \(Self.baseURL) — start it per README to run the smoke.")
        }

        let app = await XCUIApplication()
        await MainActor.run {
            // -uitest-outbox-hold: outbox writes go local-only, drain suppressed.
            app.launchArguments = ["-uitest-reset", "-uitest-outbox-hold", "-apiBaseURL", Self.baseURL.absoluteString]
            app.launch()

            let email = app.textFields["Email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15), "Login screen did not appear")
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

            // First job → detail → "Elevations" nav entry (JobDetailView's Surfaces section,
            // per commit 2ff9e22) → JobElevationsView.
            // All seed jobs share one `updatedAt`, so `@Query(sort: updatedAt desc)` ties and
            // `cells.firstMatch` is nondeterministic — three seed jobs have no buildings. Target
            // the commercial job (seed-demo-job-02, "Office glass…", 4 buildings / 8 elevations)
            // deterministically by its list title so this smoke always lands on synced buildings.
            XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 15), "Job list did not populate")
            let seedJob = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Office glass")).firstMatch
            XCTAssertTrue(seedJob.waitForExistence(timeout: 15), "Seed job with buildings ('Office glass') did not appear")
            seedJob.tap()

            let elevationsEntry = app.buttons["Elevations"]
            XCTAssertTrue(elevationsEntry.waitForExistence(timeout: 15), "Elevations nav entry did not appear on job detail")
            elevationsEntry.tap()

            // JobElevationsView: each synced building has its own "Add Elevation" row action
            // (Label(\"Add Elevation\", systemImage: \"plus\")) — first building is enough for
            // this smoke.
            // Wait generously: a cold `-uitest-reset` launch runs a full sequential syncAll with
            // buildings pulled LAST, so the first building Section (hence its Add Elevation row)
            // can take well over 15s to land on a fresh store.
            let addElevation = app.buttons["Add Elevation"].firstMatch
            XCTAssertTrue(addElevation.waitForExistence(timeout: 45), "Add Elevation action did not appear — no synced building on this job?")
            addElevation.tap()

            // AddElevationSheet: TextField("Label", ...) + toolbar "Add" confirmation action.
            let labelField = app.textFields["Label"]
            XCTAssertTrue(labelField.waitForExistence(timeout: 10), "Add Elevation sheet did not appear")
            labelField.tap()
            let elevationLabel = "UITest Elevation \(Int(Date().timeIntervalSince1970))"
            labelField.typeText(elevationLabel)

            let add = app.buttons["Add"]
            XCTAssertTrue(add.isEnabled, "Add should enable once a label is entered")
            add.tap()

            // Optimistic: the sheet dismisses and the new elevation appears in the list
            // immediately even though the outbox drain is held and nothing has synced to the
            // server (ElevationRow's headline == the entered label, since a field-added row has
            // no server-assigned numberLabel yet).
            let newElevation = app.staticTexts[elevationLabel]
            XCTAssertTrue(newElevation.waitForExistence(timeout: 10), "New elevation did not appear optimistically in the list — offline create failed")

            // Settings: the pending write is visible in the outbox, proving the elevation create
            // queued instead of silently vanishing or fake-succeeding.
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
