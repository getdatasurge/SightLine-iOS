import XCTest
import SwiftData
@testable import SightLineField

/// Fakes `WorkLogGateway` — the two-write-op seam `OutboxWorker` depends on — instead of
/// standing up the generated `Client`, mirroring `StubSyncBackend`/`SyncEngineTests`. As of M4,
/// `WorkLogActions` itself never calls this (it only enqueues); the tests below assert the
/// gateway is genuinely never touched synchronously from `checkIn`/`checkOut`. Drain-time
/// behavior (this stub actually being invoked) belongs to `OutboxWorkerTests`.
final class StubWorkLogGateway: WorkLogGateway, @unchecked Sendable {
    var checkInResult: Result<WorkLogDTO, Error> = .failure(ApiError.decoding)
    var checkOutResult: Result<WorkLogDTO, Error> = .failure(ApiError.decoding)

    private(set) var checkInCalls: [(jobId: String, workTypeId: String?, notes: String?, clientUuid: String)] = []
    private(set) var checkOutCalls: [(workLogClientUuid: String, quantity: Double?, notes: String?)] = []

    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO {
        checkInCalls.append((jobId, workTypeId, notes, clientUuid))
        return try checkInResult.get()
    }

    func checkOut(workLogClientUuid: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO {
        checkOutCalls.append((workLogClientUuid, quantity, notes))
        return try checkOutResult.get()
    }
}

@MainActor
final class WorkLogActionsTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    // MARK: - checkIn

    func testCheckInWritesOptimisticCheckedInRowAndEnqueuesOutboxItem() throws {
        let context = try makeContext()
        let gateway = StubWorkLogGateway()
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        let result = actions.checkIn(jobId: "job-1", workTypeId: "wt-1", notes: "started", technicianId: "tech-1")

        // A real, freshly-minted UUID — not empty, not server-sourced garbage.
        XCTAssertNotNil(UUID(uuidString: result.clientUuid))
        XCTAssertEqual(result.id, result.clientUuid, "the optimistic row's id is pinned to its own clientUuid")
        XCTAssertEqual(result.status, "CHECKED_IN")
        XCTAssertEqual(result.jobId, "job-1")
        XCTAssertEqual(result.workTypeId, "wt-1")
        XCTAssertEqual(result.notes, "started")
        XCTAssertEqual(result.technicianId, "tech-1", "must land on the optimistic row immediately (m4a-review Important #1) — not wait for the outbox to reconcile the server's row")

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1)
        XCTAssertEqual(workLogs.first?.id, result.clientUuid)

        let outboxItems = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(outboxItems.count, 1)
        let item = try XCTUnwrap(outboxItems.first)
        XCTAssertEqual(item.endpoint, OutboxEndpoint.checkIn.rawValue)
        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 0)
        let payload = try JSONDecoder().decode(CheckInPayload.self, from: item.payload)
        XCTAssertEqual(payload.jobId, "job-1")
        XCTAssertEqual(payload.workTypeId, "wt-1")
        XCTAssertEqual(payload.notes, "started")
        XCTAssertEqual(payload.clientUuid, result.clientUuid)

        // Nothing about this call stack touches the network: the actual gateway call only ever
        // happens inside `outboxWorker.drain()`, kicked off fire-and-forget — since `checkIn`
        // itself has no `await` before this point, no task the MainActor scheduled on its behalf
        // can possibly have run yet.
        XCTAssertTrue(gateway.checkInCalls.isEmpty, "checkIn must not call the gateway synchronously")
    }

    func testCheckInMintsAFreshUuidPerCall() throws {
        let context = try makeContext()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        let first = actions.checkIn(jobId: "job-1", workTypeId: nil, notes: nil, technicianId: nil)
        let second = actions.checkIn(jobId: "job-1", workTypeId: nil, notes: nil, technicianId: nil)

        XCTAssertNotEqual(first.clientUuid, second.clientUuid)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLog>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncOutbox>()), 2)
    }

    // MARK: - checkOut

    func testCheckOutMutatesExistingRowOptimisticallyAndEnqueues() throws {
        let context = try makeContext()
        context.insert(WorkLog(
            id: "uuid-1", clientUuid: "uuid-1", jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 500), updatedAt: Date(timeIntervalSince1970: 500)
        ))
        try context.save()

        let gateway = StubWorkLogGateway()
        let actions = WorkLogActions(gateway: gateway, modelContext: context)

        let result = actions.checkOut(workLogClientUuid: "uuid-1", quantity: 12.5, notes: "done")

        let model = try XCTUnwrap(result)
        XCTAssertEqual(model.status, "CHECKED_OUT")
        XCTAssertEqual(model.quantity, 12.5)
        XCTAssertEqual(model.notes, "done")
        XCTAssertNotNil(model.checkOutAt)
        XCTAssertEqual(model.id, "uuid-1", "checking out never touches id/clientUuid")
        XCTAssertEqual(model.clientUuid, "uuid-1")

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1, "check-out must mutate, never duplicate")

        let outboxItems = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(outboxItems.count, 1)
        let item = try XCTUnwrap(outboxItems.first)
        XCTAssertEqual(item.endpoint, OutboxEndpoint.checkOut.rawValue)
        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        let payload = try JSONDecoder().decode(CheckOutPayload.self, from: item.payload)
        XCTAssertEqual(payload.workLogClientUuid, "uuid-1")
        XCTAssertEqual(payload.quantity, 12.5)
        XCTAssertEqual(payload.notes, "done")

        XCTAssertTrue(gateway.checkOutCalls.isEmpty, "checkOut must not call the gateway synchronously")
    }

    func testCheckOutReturnsNilAndStillEnqueuesWhenLocalRowMissing() throws {
        let context = try makeContext()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        // No local WorkLog row for "missing-uuid" — e.g. this device never saw the check-in.
        let result = actions.checkOut(workLogClientUuid: "missing-uuid", quantity: nil, notes: nil)

        XCTAssertNil(result, "nothing local to mutate optimistically")
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkLog>()).isEmpty, "checkOut never fabricates a row itself")

        let outboxItems = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(outboxItems.count, 1, "the enqueue still happens — a later drain reconciles whatever the server says")
        let payload = try JSONDecoder().decode(CheckOutPayload.self, from: try XCTUnwrap(outboxItems.first).payload)
        XCTAssertEqual(payload.workLogClientUuid, "missing-uuid")
    }

    // MARK: - openWorkLog

    func testOpenWorkLogReturnsCheckedInRowMatchingJob() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "open-1", clientUuid: "u1", jobId: "job-1", technicianId: "tech-1", status: "CHECKED_IN", checkInAt: Date(), updatedAt: Date()))
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

    /// With a `technicianId`, only the caller's own open session counts: a teammate's row on
    /// the same job and a pre-column row (`technicianId == nil`) are both excluded. With
    /// `nil` (account without a Technician row) the query falls back to job-wide.
    func testOpenWorkLogScopesToCallerTechnician() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "mine", clientUuid: "u1", jobId: "job-1", technicianId: "tech-1", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100)))
        context.insert(WorkLog(id: "teammate", clientUuid: "u2", jobId: "job-1", technicianId: "tech-2", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200)))
        context.insert(WorkLog(id: "legacy", clientUuid: "u3", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300)))
        try context.save()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        XCTAssertEqual(actions.openWorkLog(onJob: "job-1", technicianId: "tech-1")?.id, "mine")
        XCTAssertNil(actions.openWorkLog(onJob: "job-1", technicianId: "tech-3"))
        XCTAssertEqual(actions.openWorkLog(onJob: "job-1", technicianId: nil)?.id, "legacy")
    }

    /// The exact m4a-review Important #1 repro: offline, `checkIn` must write a row
    /// `openWorkLog(onJob:technicianId:)` can immediately see — otherwise the Check In → Check
    /// Out toggle never flips (the view keeps showing "Check In"), and a second tap mints a
    /// *second* clientUuid/WorkLog/outbox row, creating a duplicate open session once the
    /// outbox drains.
    func testCheckInRowIsImmediatelyVisibleToOpenWorkLogForTheSameTechnician() throws {
        let context = try makeContext()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        let checkedIn = actions.checkIn(jobId: "job-1", workTypeId: "wt-1", notes: nil, technicianId: "tech-1")

        let open = actions.openWorkLog(onJob: "job-1", technicianId: "tech-1")
        XCTAssertEqual(open?.id, checkedIn.id, "the just-created offline session must be visible without waiting for the outbox to reconcile")

        // A teammate's technicianId must still not see this caller's own session.
        XCTAssertNil(actions.openWorkLog(onJob: "job-1", technicianId: "tech-2"))
    }

    func testOpenWorkLogPicksMostRecentlyOpenedWhenMultipleMatch() async throws {
        let context = try makeContext()
        context.insert(WorkLog(id: "older", clientUuid: "u1", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100)))
        context.insert(WorkLog(id: "newer", clientUuid: "u2", jobId: "job-1", status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200)))
        try context.save()
        let actions = WorkLogActions(gateway: StubWorkLogGateway(), modelContext: context)

        XCTAssertEqual(actions.openWorkLog(onJob: "job-1", technicianId: nil)?.id, "newer")
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
