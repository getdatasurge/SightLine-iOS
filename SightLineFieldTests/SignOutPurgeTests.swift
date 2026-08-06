import XCTest
import SwiftData
@testable import SightLineField

/// The `onSignedOut` purge is a shared-installer-device correctness path: when one technician
/// signs out, none of the prior account's synced rows — and crucially none of its *queued outbox
/// writes* — may survive into the next technician's session. `SessionManagerTests` only proves the
/// closure fires; this proves what it actually does, against the real closure `AppDependencies`
/// wires (not a reimplementation), including the `SyncOutbox` purge that stops a prior account's
/// queued writes replaying under the next login.
@MainActor
final class SignOutPurgeTests: XCTestCase {
    func testSignOutPurgesEverySyncedModelAndTheOutbox() throws {
        let deps = AppDependencies(inMemoryStore: true)
        let ctx = deps.modelContainer.mainContext

        ctx.insert(JobSummary(id: "j1", name: "Acme", status: "OPEN", updatedAt: Date()))
        ctx.insert(Appointment(id: "a1", title: "Site visit", start: Date(), end: Date(), status: "SCHEDULED", updatedAt: Date()))
        ctx.insert(WorkType(id: "wt1", name: "Caulking", unit: "LINEAR_FT", isActive: true, updatedAt: Date()))
        ctx.insert(WorkLog(id: "wl1", clientUuid: "wl-uuid", jobId: "j1", status: "CHECKED_IN", checkInAt: Date(), updatedAt: Date()))
        ctx.insert(Surface(id: "s1", jobId: "j1", label: "Pane 1", status: "MEASURED", updatedAt: Date()))
        ctx.insert(Building(id: "b1", jobId: "j1", name: "Main", buildingIndex: 1, updatedAt: Date()))
        ctx.insert(Elevation(id: "e1", buildingId: "b1", elevationNumber: 1, label: "North", fieldAdded: true, updatedAt: Date()))
        ctx.insert(SyncOutbox(clientUuid: "o1", endpoint: OutboxEndpoint.checkIn.rawValue, payload: Data()))
        try ctx.save()

        // Precondition: the rows really are in the store, so the assertions below can't pass vacuously.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<JobSummary>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SyncOutbox>()), 1)

        // Fire the exact closure `AppDependencies` handed `SessionManager` for sign-out.
        deps.session.onSignedOut?()

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<JobSummary>()), 0, "JobSummary not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Appointment>()), 0, "Appointment not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WorkType>()), 0, "WorkType not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<WorkLog>()), 0, "WorkLog not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Surface>()), 0, "Surface not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Building>()), 0, "Building not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Elevation>()), 0, "Elevation not purged on sign-out")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SyncOutbox>()), 0, "SyncOutbox not purged on sign-out — a prior account's queued writes would replay under the next technician")
    }
}
