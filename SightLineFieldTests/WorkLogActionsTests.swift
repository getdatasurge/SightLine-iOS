import XCTest
import SwiftData
@testable import SightLineField

/// Fakes `WorkLogGateway` — the two-write-op seam `WorkLogActions` depends on — instead of
/// standing up the generated `Client`, mirroring `StubSyncBackend`/`SyncEngineTests`.
final class StubWorkLogGateway: WorkLogGateway, @unchecked Sendable {
    var checkInResult: Result<WorkLogDTO, Error> = .failure(ApiError.decoding)
    var checkOutResult: Result<WorkLogDTO, Error> = .failure(ApiError.decoding)

    private(set) var checkInCalls: [(jobId: String, workTypeId: String?, notes: String?, clientUuid: String)] = []
    private(set) var checkOutCalls: [(workLogId: String, quantity: Double?, notes: String?)] = []

    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO {
        checkInCalls.append((jobId, workTypeId, notes, clientUuid))
        return try checkInResult.get()
    }

    func checkOut(workLogId: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO {
        checkOutCalls.append((workLogId, quantity, notes))
        return try checkOutResult.get()
    }
}

@MainActor
final class WorkLogActionsTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    private func dto(
        id: String,
        jobId: String = "job-1",
        technicianId: String? = "tech-1",
        workTypeId: String? = "wt-1",
        checkInAt: Date = Date(timeIntervalSince1970: 1_000),
        checkOutAt: Date? = nil,
        quantity: Double? = nil,
        notes: String? = nil,
        status: String = "CHECKED_IN",
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> WorkLogDTO {
        WorkLogDTO(
            id: id,
            jobId: jobId,
            technicianId: technicianId,
            workTypeId: workTypeId,
            checkInAt: checkInAt,
            checkOutAt: checkOutAt,
            quantity: quantity,
            notes: notes,
            status: status,
            updatedAt: updatedAt
        )
    }

    // MARK: - checkIn

    func testCheckInSendsGeneratedClientUuidAndUpsertsNewRow() async throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "wl-1", notes: "started"))
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        let result = try await actions.checkIn(jobId: "job-1", workTypeId: "wt-1", notes: "started")

        XCTAssertEqual(result.id, "wl-1")
        XCTAssertEqual(gateway.checkInCalls.count, 1)
        let call = try XCTUnwrap(gateway.checkInCalls.first)
        XCTAssertEqual(call.jobId, "job-1")
        XCTAssertEqual(call.workTypeId, "wt-1")
        XCTAssertEqual(call.notes, "started")
        // A real, freshly-minted UUID — not empty, not the server row id, not reused garbage.
        XCTAssertNotNil(UUID(uuidString: call.clientUuid))

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<WorkLog>()).first)
        XCTAssertEqual(stored.id, "wl-1")
        XCTAssertEqual(stored.clientUuid, call.clientUuid, "a fresh check-in keeps the locally-minted idempotency key, not the server id")
        XCTAssertEqual(stored.status, "CHECKED_IN")
        XCTAssertEqual(stored.jobId, "job-1")
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkLog>()).count, 1)
    }

    func testCheckInReplayMutatesExistingRowInPlaceWithoutDuplicating() async throws {
        let context = try makeContext()
        context.insert(WorkLog(
            id: "wl-1", clientUuid: "prior-uuid", jobId: "job-1", workTypeId: "wt-old",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 500), updatedAt: Date(timeIntervalSince1970: 500)
        ))
        try context.save()

        let gateway = StubWorkLogGateway()
        // Idempotent replay: server returns the SAME row id it already had (clientUuid collision).
        gateway.checkInResult = .success(dto(id: "wl-1", notes: "replayed", updatedAt: Date(timeIntervalSince1970: 900)))
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        _ = try await actions.checkIn(jobId: "job-1", workTypeId: "wt-1", notes: "replayed")

        let rows = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(rows.count, 1, "replay must mutate, never duplicate")
        XCTAssertEqual(rows[0].clientUuid, "prior-uuid", "an existing row's local clientUuid is never overwritten by a fresh mint")
        XCTAssertEqual(rows[0].notes, "replayed")
        XCTAssertEqual(rows[0].workTypeId, "wt-1")
    }

    // MARK: - checkOut

    func testCheckOutUpsertsExistingRowAndFlipsStatus() async throws {
        let context = try makeContext()
        context.insert(WorkLog(
            id: "wl-1", clientUuid: "uuid-1", jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 500), updatedAt: Date(timeIntervalSince1970: 500)
        ))
        try context.save()

        let gateway = StubWorkLogGateway()
        gateway.checkOutResult = .success(dto(
            id: "wl-1", checkInAt: Date(timeIntervalSince1970: 500), checkOutAt: Date(timeIntervalSince1970: 900),
            quantity: 12.5, notes: "done", status: "CHECKED_OUT", updatedAt: Date(timeIntervalSince1970: 900)
        ))
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        let result = try await actions.checkOut(workLogId: "wl-1", quantity: 12.5, notes: "done")

        XCTAssertEqual(gateway.checkOutCalls.count, 1)
        XCTAssertEqual(gateway.checkOutCalls.first?.workLogId, "wl-1")
        XCTAssertEqual(gateway.checkOutCalls.first?.quantity, 12.5)
        XCTAssertEqual(result.status, "CHECKED_OUT")
        XCTAssertEqual(result.quantity, 12.5)
        XCTAssertEqual(result.clientUuid, "uuid-1", "checking out an existing row never touches its clientUuid")

        let rows = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(rows.count, 1, "check-out must mutate, never duplicate")
    }

    func testCheckOutInsertsFallbackRowWhenLocalCopyMissing() async throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        gateway.checkOutResult = .success(dto(id: "wl-remote", checkOutAt: Date(timeIntervalSince1970: 900), status: "CHECKED_OUT"))
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        // No local WorkLog row for "wl-remote" — e.g. this device never synced it locally.
        let result = try await actions.checkOut(workLogId: "wl-remote", quantity: nil, notes: nil)

        XCTAssertEqual(result.id, "wl-remote")
        XCTAssertEqual(result.clientUuid, "wl-remote", "fallback insert reuses the server id, mirroring SyncEngine.syncWorkLogs")
    }

    // MARK: - openWorkLog

    func testOpenWorkLogReturnsCheckedInRowMatchingJob() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "open-1", clientUuid: "u1", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(), updatedAt: Date()))
        context.insert(WorkLog(id: "closed-1", clientUuid: "u2", jobId: "job-1", status: "CHECKED_OUT", checkInAt: Date(), checkOutAt: Date(), updatedAt: Date()))
        context.insert(WorkLog(id: "open-2", clientUuid: "u3", jobId: "job-2", status: "CHECKED_IN", checkInAt: Date(), updatedAt: Date()))
        try context.save()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        let openLog = actions.openWorkLog(onJob: "job-1", technicianId: "tech-1")

        XCTAssertEqual(openLog?.id, "open-1", "only the CHECKED_IN row for the requested job, never a CHECKED_OUT row or another job's")
    }

    func testOpenWorkLogReturnsNilWhenNoOpenSessionOnJob() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "closed-1", clientUuid: "u1", jobId: "job-1", status: "CHECKED_OUT", checkInAt: Date(), checkOutAt: Date(), updatedAt: Date()))
        try context.save()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        XCTAssertNil(actions.openWorkLog(onJob: "job-1", technicianId: "tech-1"))
    }

    /// `WorkLog` (`Models.swift`) has no persisted `technicianId` column today — see
    /// `WorkLogActions.openWorkLog`'s doc comment. This pins the *current, honest* behavior
    /// (job + status only) so a future column addition changes this test deliberately instead
    /// of silently.
    func testOpenWorkLogAcceptsTechnicianIdButCannotYetFilterByIt() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "open-1", clientUuid: "u1", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(), updatedAt: Date()))
        try context.save()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        XCTAssertEqual(actions.openWorkLog(onJob: "job-1", technicianId: "some-other-tech")?.id, "open-1")
        XCTAssertEqual(actions.openWorkLog(onJob: "job-1", technicianId: nil)?.id, "open-1")
    }

    func testOpenWorkLogPicksMostRecentlyOpenedWhenMultipleMatch() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "older", clientUuid: "u1", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100)))
        context.insert(WorkLog(id: "newer", clientUuid: "u2", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200)))
        try context.save()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        XCTAssertEqual(actions.openWorkLog(onJob: "job-1", technicianId: nil)?.id, "newer")
    }

    // MARK: - Error mapping

    func testCheckInPropagatesUnauthorized() async throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.unauthorized)
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        do {
            _ = try await actions.checkIn(jobId: "job-1", workTypeId: nil, notes: nil)
            XCTFail("expected ApiError.unauthorized")
        } catch ApiError.unauthorized {
            // expected
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkLog>()).isEmpty, "a failed check-in must not write a row")
    }

    func testCheckOutPropagatesServerError500() async throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        gateway.checkOutResult = .failure(ApiError.server(status: 500))
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        do {
            _ = try await actions.checkOut(workLogId: "wl-1", quantity: nil, notes: nil)
            XCTFail("expected ApiError.server(status: 500)")
        } catch ApiError.server(let status) {
            XCTAssertEqual(status, 500)
        }
    }

    func testCheckInPropagatesNetworkError() async throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        struct DummyError: Error {}
        gateway.checkInResult = .failure(ApiError.network(DummyError()))
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        do {
            _ = try await actions.checkIn(jobId: "job-1", workTypeId: nil, notes: nil)
            XCTFail("expected ApiError.network")
        } catch ApiError.network {
            // expected
        }
    }

    // MARK: - ApiError.userMessage (sheet-facing copy)

    func testUserMessageForNetworkIsOfflineCopy() {
        struct DummyError: Error {}
        XCTAssertEqual(ApiError.network(DummyError()).userMessage, "You're offline — try again when connected.")
    }

    func testUserMessageForOtherCasesIsNonEmptyAndCaseSpecific() {
        XCTAssertEqual(ApiError.unauthorized.userMessage, "Your session expired. Please sign in again.")
        XCTAssertEqual(ApiError.server(status: 500).userMessage, "Server error (500). Please try again.")
        XCTAssertFalse(ApiError.decoding.userMessage.isEmpty)
    }
}
