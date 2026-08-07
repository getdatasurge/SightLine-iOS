import XCTest

/// M5b offline-pane-capture smoke: proves capturing a measured glass pane onto an elevation
/// while the outbox drain is suppressed still lands optimistically (the sheet dismisses with no
/// error state — `CaptureSurfaceSheet.confirm()` calls the never-throwing, never-awaiting
/// `SurfaceActions.captureSurface`), and the pending write is visible in Settings as a queued
/// `.surfaceCapture` outbox item. Same live-backend contract as `OfflineElevationUITests` /
/// `OfflineOutboxUITests` — SKIPS when the paired server is unreachable, since login must still
/// succeed online before the outbox hold takes effect.
///
/// `-uitest-outbox-hold` (paired with `-uitest-reset`) tells the app to build its outbox
/// normally — the pane is inserted locally exactly as in production — but to suppress the
/// background drain that would otherwise flush the `.surfaceCapture` write to the server. That
/// isolates the write path from the network entirely: this test proves the capture succeeds and
/// is queued with zero network activity reaching the backend for the write itself (only the
/// login call, plus whatever building/elevation sync already ran, touches the network).
final class OfflinePaneCaptureUITests: XCTestCase {

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

    func testOfflinePaneCaptureIsOptimisticAndQueued() async throws {
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
            // deterministically by its list title so this smoke always lands on synced elevations.
            XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 15), "Job list did not populate")
            let seedJob = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Office glass")).firstMatch
            XCTAssertTrue(seedJob.waitForExistence(timeout: 15), "Seed job with buildings ('Office glass') did not appear")
            seedJob.tap()

            let elevationsEntry = app.buttons["Elevations"]
            XCTAssertTrue(elevationsEntry.waitForExistence(timeout: 15), "Elevations nav entry did not appear on job detail")
            elevationsEntry.tap()

            // JobElevationsView: each elevation row has a per-row "Capture Pane" icon-only
            // action (Label("Capture Pane", systemImage: "plus.viewfinder").labelStyle(.iconOnly)
            // — the accessibility name stays "Capture Pane" since SwiftUI's iconOnly label style
            // only hides the visible title, not the accessibility label). First elevation on
            // the first building is enough for this smoke; requires a synced building with at
            // least one elevation on this job.
            // Wait generously: a cold `-uitest-reset` launch runs a full sequential syncAll with
            // buildings/elevations pulled LAST, so on a fresh store the first elevation row can
            // take well over 15s to land (the reactive @Query surfaces it the moment it does).
            let capturePane = app.buttons["Capture Pane"].firstMatch
            XCTAssertTrue(capturePane.waitForExistence(timeout: 45), "Capture Pane action did not appear — no elevation on this job's first synced building?")
            capturePane.tap()

            // CaptureSurfaceSheet: Label / Width (in) / Height (in) TextFields, a Quantity
            // Stepper, and the toolbar "Capture" confirmation action.
            let labelField = app.textFields["Label"]
            XCTAssertTrue(labelField.waitForExistence(timeout: 10), "Capture Pane sheet did not appear")
            labelField.tap()
            let paneLabel = "UITest Pane \(Int(Date().timeIntervalSince1970))"
            labelField.typeText(paneLabel)

            let widthField = app.textFields["Width (in)"]
            XCTAssertTrue(widthField.waitForExistence(timeout: 5), "Width field did not appear in Capture Pane sheet")
            widthField.tap()
            widthField.typeText("36")

            let heightField = app.textFields["Height (in)"]
            XCTAssertTrue(heightField.waitForExistence(timeout: 5), "Height field did not appear in Capture Pane sheet")
            heightField.tap()
            heightField.typeText("48")

            // Quantity Stepper defaults to 1 (already valid for capture); bump it once to
            // exercise the control, same non-blocking style as WorkLogSmokeUITests' optional
            // quantity field — a missing "Increment" child wouldn't fail the capture itself.
            let quantityStepper = app.steppers.firstMatch
            if quantityStepper.waitForExistence(timeout: 2) {
                let increment = quantityStepper.buttons["Increment"]
                if increment.waitForExistence(timeout: 2) {
                    increment.tap()
                }
            }

            let capture = app.buttons["Capture"]
            XCTAssertTrue(capture.isEnabled, "Capture should enable once label, width, and height are entered")
            capture.tap()

            // Optimistic: the sheet dismisses immediately even though the outbox drain is held
            // and nothing has synced to the server (CaptureSurfaceSheet.confirm() never throws
            // or awaits the network). The captured pane itself isn't listed in this view (panes
            // surface in JobDetailView's "Surfaces" section instead — see JobElevationsView's
            // file doc comment), so sheet dismissal plus the queued outbox row below is the
            // observable proof.
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: labelField)
            XCTAssertEqual(XCTWaiter().wait(for: [dismissed], timeout: 10), .completed, "Capture Pane sheet did not dismiss after Capture — offline capture failed")

            // Settings: the pending write is visible in the outbox, proving the pane capture
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
