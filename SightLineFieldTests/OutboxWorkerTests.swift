import XCTest
import SwiftData
import Observation
@testable import SightLineField

/// Fakes `WorkLogGateway` for direct `OutboxWorker.drain()` testing — no `WorkLogActions`
/// involved, so there's no competing fire-and-forget drain to race against (unlike a real
/// enqueue, which also kicks one off). `callOrder` records `"checkIn:<clientUuid>"`/
/// `"checkOut:<clientUuid>"` in the order the gateway actually saw them, so ordering tests can
/// prove `drain()` really does replay oldest-first rather than merely happening to converge on
/// the right end state regardless of order.
final class FakeWorkLogGateway: WorkLogGateway, @unchecked Sendable {
    var checkInResult: Result<WorkLogDTO, Error> = .failure(ApiError.decoding)
    var checkOutResult: Result<WorkLogDTO, Error> = .failure(ApiError.decoding)

    /// Artificial delay inside `checkIn`, used to widen the overlap window for cancellation
    /// tests (mirrors `StubSyncBackend.jobsDelayNanoseconds`, `SyncEngineTests.swift`).
    var checkInDelayNanoseconds: UInt64 = 0

    /// Fires synchronously from inside `checkIn`, before it returns — used by the re-drain-loop
    /// test to insert a second outbox row on the same `ModelContext` while the first item's
    /// request is conceptually "in flight", mirroring a second `WorkLogActions` call landing on
    /// the shared context mid-pass. No real concurrency needed: everything here runs on the
    /// same `@MainActor`, so a synchronous side effect from this closure is already sequenced
    /// correctly relative to the rest of `drain()`.
    var onCheckIn: (() -> Void)?

    private(set) var checkInCalls: [(jobId: String, workTypeId: String?, notes: String?, clientUuid: String)] = []
    private(set) var checkOutCalls: [(workLogClientUuid: String, quantity: Double?, notes: String?)] = []
    private(set) var callOrder: [String] = []

    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO {
        checkInCalls.append((jobId, workTypeId, notes, clientUuid))
        callOrder.append("checkIn:\(clientUuid)")
        onCheckIn?()
        if checkInDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: checkInDelayNanoseconds)
        }
        return try checkInResult.get()
    }

    func checkOut(workLogClientUuid: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO {
        checkOutCalls.append((workLogClientUuid, quantity, notes))
        callOrder.append("checkOut:\(workLogClientUuid)")
        return try checkOutResult.get()
    }
}

/// Fakes `SurveyWriteGateway` for direct `OutboxWorker.drain()` testing (M5a) — mirrors
/// `FakeWorkLogGateway`'s shape/reasoning exactly: no `ElevationActions` involved, so there's no
/// competing fire-and-forget drain to race against.
final class FakeSurveyWriteGateway: SurveyWriteGateway, @unchecked Sendable {
    var createElevationResult: Result<ElevationDTO, Error> = .failure(ApiError.decoding)
    var assignSurfaceResult: Result<Void, Error> = .success(())

    private(set) var createElevationCalls: [(buildingId: String, label: String, facing: String?, clientUuid: String)] = []
    private(set) var assignSurfaceCalls: [(surfaceId: String, buildingId: String, elevationId: String)] = []

    func createElevation(buildingId: String, label: String, facing: String?, clientUuid: String) async throws -> ElevationDTO {
        createElevationCalls.append((buildingId, label, facing, clientUuid))
        return try createElevationResult.get()
    }

    func assignSurface(surfaceId: String, buildingId: String, elevationId: String) async throws {
        assignSurfaceCalls.append((surfaceId, buildingId, elevationId))
        _ = try assignSurfaceResult.get()
    }
}

@MainActor
final class OutboxWorkerTests: XCTestCase {
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
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        clientUuid: String? = nil
    ) -> WorkLogDTO {
        WorkLogDTO(
            id: id, jobId: jobId, technicianId: technicianId, workTypeId: workTypeId,
            checkInAt: checkInAt, checkOutAt: checkOutAt, quantity: quantity, notes: notes,
            status: status, updatedAt: updatedAt, clientUuid: clientUuid
        )
    }

    @discardableResult
    private func insertCheckInItem(
        context: ModelContext, workLogClientUuid: String, jobId: String = "job-1",
        workTypeId: String? = "wt-1", notes: String? = nil, attempts: Int = 0,
        state: OutboxState = .pending, createdAt: Date
    ) -> SyncOutbox {
        let payload = CheckInPayload(jobId: jobId, workTypeId: workTypeId, notes: notes, clientUuid: workLogClientUuid)
        let item = SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.checkIn.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: attempts, state: state.rawValue, createdAt: createdAt
        )
        context.insert(item)
        return item
    }

    @discardableResult
    private func insertCheckOutItem(
        context: ModelContext, workLogClientUuid: String, quantity: Double? = nil, notes: String? = nil,
        attempts: Int = 0, state: OutboxState = .pending, createdAt: Date
    ) -> SyncOutbox {
        let payload = CheckOutPayload(workLogClientUuid: workLogClientUuid, quantity: quantity, notes: notes)
        let item = SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.checkOut.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: attempts, state: state.rawValue, createdAt: createdAt
        )
        context.insert(item)
        return item
    }

    // MARK: - drain(): happy path

    func testDrainHappyPathPurgesRowAndReconcilesLocalRow() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, notes: "started", createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(
            id: "server-1", notes: "started", status: "CHECKED_IN",
            updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: workLogClientUuid
        ))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "a successfully-synced row is purged (Minor #4), never left `.done`")

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1, "reconcile must update in place, never duplicate")
        XCTAssertEqual(workLogs.first?.id, workLogClientUuid, "id stays pinned to clientUuid, never remapped to the server's own id")
        XCTAssertEqual(workLogs.first?.updatedAt, Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(worker.pendingCount, 0)
        XCTAssertEqual(worker.conflictCount, 0)
        XCTAssertFalse(worker.isDraining)
    }

    func testDrainInsertsRowWhenNoLocalOptimisticWriteExists() async throws {
        // Simulates an outbox item that landed without going through `WorkLogActions` (or the
        // local row was somehow lost) — reconcile must still create it, keyed by clientUuid.
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: workLogClientUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1)
        XCTAssertEqual(workLogs.first?.id, workLogClientUuid)
        XCTAssertEqual(workLogs.first?.clientUuid, workLogClientUuid)
    }

    // MARK: - drain(): stop-on-offline

    func testDrainOnNetworkErrorLeavesRowPendingAndStopsBeforeLaterRows() async throws {
        let context = try makeContext()
        let first = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 100))
        let second = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        struct Offline: Error {}
        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.network(Offline()))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 1, "must stop after the first network failure, never touch the second row")
        XCTAssertEqual(first.state, OutboxState.pending.rawValue)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertNotNil(first.lastError)
        XCTAssertEqual(second.state, OutboxState.pending.rawValue)
        XCTAssertEqual(second.attempts, 0, "never even attempted")
        XCTAssertEqual(worker.pendingCount, 2)
    }

    func testDrainOnUnauthorizedAlsoStopsThePass() async throws {
        let context = try makeContext()
        let first = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 100))
        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.unauthorized)
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 1, "an invalid session fails every remaining item the same way — stop rather than burn their attempts")
        XCTAssertEqual(first.state, OutboxState.pending.rawValue)
        XCTAssertEqual(first.attempts, 1)
    }

    // MARK: - drain(): idempotent re-drain

    func testDrainTwiceIsIdempotentNoDuplicateWorkLogsOrGatewayCalls() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: workLogClientUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()
        XCTAssertEqual(gateway.checkInCalls.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLog>()), 1)

        await worker.drain()
        XCTAssertEqual(gateway.checkInCalls.count, 1, "a done row is never replayed")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLog>()), 1, "still exactly one row, no duplicate")
    }

    // MARK: - drain(): check-in -> check-out sequencing

    func testDrainProcessesCheckInBeforeCheckOutForTheSameClientUuidOldestFirst() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        // Both enqueued while offline, in this order: check-in first, check-out second.
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, createdAt: Date(timeIntervalSince1970: 500))
        insertCheckOutItem(context: context, workLogClientUuid: workLogClientUuid, quantity: 9.5, notes: "done", createdAt: Date(timeIntervalSince1970: 600))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(
            id: "server-1", status: "CHECKED_IN", updatedAt: Date(timeIntervalSince1970: 1_500), clientUuid: workLogClientUuid
        ))
        gateway.checkOutResult = .success(dto(
            id: "server-1", checkOutAt: Date(timeIntervalSince1970: 2_000), quantity: 9.5, notes: "done",
            status: "CHECKED_OUT", updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: workLogClientUuid
        ))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(gateway.callOrder, ["checkIn:\(workLogClientUuid)", "checkOut:\(workLogClientUuid)"], "must replay oldest-first")

        let items = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertTrue(items.isEmpty, "both rows succeed and are purged (Minor #4), never retained as `.done`")

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1, "both reconciles target the same row, never duplicating")
        let workLog = try XCTUnwrap(workLogs.first)
        XCTAssertEqual(workLog.id, workLogClientUuid)
        XCTAssertEqual(workLog.status, "CHECKED_OUT")
        XCTAssertEqual(workLog.quantity, 9.5)
    }

    // MARK: - drain(): maxAttempts -> conflict

    func testTransientFailureBelowMaxAttemptsStaysPending() async throws {
        let context = try makeContext()
        let item = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, attempts: 4, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.server(status: 500))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(item.attempts, 5)
        XCTAssertEqual(item.state, OutboxState.pending.rawValue, "below maxAttempts (6): stays pending for a future retry")
    }

    func testTransientFailureAtMaxAttemptsBecomesConflict() async throws {
        let context = try makeContext()
        let item = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, attempts: 5, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.server(status: 500))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(item.attempts, 6)
        XCTAssertEqual(item.state, OutboxState.conflict.rawValue, "maxAttempts reached: surfaced as a conflict, never silently dropped")
        XCTAssertNotNil(item.lastError)
        XCTAssertEqual(worker.conflictCount, 1)
    }

    // MARK: - drain(): 4xx-conflict is immediate, not gated by attempts

    func testPermanentServerRejectionBecomesConflictImmediatelyRegardlessOfAttempts() async throws {
        let context = try makeContext()
        let item = insertCheckOutItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkOutResult = .failure(ApiError.server(status: 409))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(item.state, OutboxState.conflict.rawValue)
        XCTAssertEqual(item.attempts, 0, "a 4xx rejection never even burns an attempt — it's not a bounded-retry situation")
    }

    // MARK: - retry(clientUuid:)

    func testRetryResetsConflictRowToPendingWithFreshAttemptBudget() throws {
        let context = try makeContext()
        let item = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, attempts: 6, state: .conflict, createdAt: Date(timeIntervalSince1970: 500))
        item.lastError = "server 409"
        try context.save()

        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.retry(clientUuid: item.clientUuid)

        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 0)
        XCTAssertNil(item.lastError)
    }

    func testRetryIsANoOpForARowNotInConflict() throws {
        let context = try makeContext()
        let item = insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, attempts: 2, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.retry(clientUuid: item.clientUuid)

        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 2, "not conflicted — retry does nothing")
    }

    func testRetryIsANoOpForAnUnknownClientUuid() throws {
        let context = try makeContext()
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)

        worker.retry(clientUuid: "does-not-exist") // must not crash

        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty)
    }

    func testRetryThenDrainSucceeds() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        let item = insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, attempts: 6, state: .conflict, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: workLogClientUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        worker.retry(clientUuid: item.clientUuid)
        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "succeeded — purged (Minor #4), not left `.done`")
    }

    // MARK: - pendingCount / conflictCount

    func testPendingAndConflictCountsAcrossStates() throws {
        let context = try makeContext()
        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, state: .pending, createdAt: Date(timeIntervalSince1970: 100))
        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, state: .inFlight, createdAt: Date(timeIntervalSince1970: 200))
        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, state: .conflict, createdAt: Date(timeIntervalSince1970: 300))
        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, state: .done, createdAt: Date(timeIntervalSince1970: 400))
        try context.save()

        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)

        XCTAssertEqual(worker.pendingCount, 2, "pending + inFlight")
        XCTAssertEqual(worker.conflictCount, 1)
    }

    // MARK: - drain(): defensive handling

    func testDrainMarksUnrecognizedEndpointAsConflictAndContinuesToLaterRows() async throws {
        let context = try makeContext()
        let bogus = SyncOutbox(clientUuid: UUID().uuidString, endpoint: "bogus", payload: Data(), createdAt: Date(timeIntervalSince1970: 100))
        context.insert(bogus)
        let workLogClientUuid = UUID().uuidString
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: workLogClientUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(bogus.state, OutboxState.conflict.rawValue)
        XCTAssertNotNil(bogus.lastError)
        // A permanent failure never stops the pass — the second, valid row still gets processed.
        XCTAssertEqual(gateway.checkInCalls.count, 1)
    }

    // MARK: - drain(): dependent check-out defers when its check-in fails transiently (m4a-review Important #2)

    /// If check-in returns a transient failure (429/5xx, doesn't stop the pass) and stays
    /// `.pending`, the dependent check-out for the *same* work-log must never be attempted this
    /// pass — replaying it against a work-log the server hasn't created yet would 404 into a
    /// `.conflict` the check-in's later success can never un-stick (the exact bug m4a-review
    /// Important #2 describes). Both rows then succeed together on the very next `drain()` call.
    func testDependentCheckOutDefersWhenCheckInFailsTransientlyThenBothSucceedNextPass() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, createdAt: Date(timeIntervalSince1970: 100))
        insertCheckOutItem(context: context, workLogClientUuid: workLogClientUuid, quantity: 5, notes: "done", createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .failure(ApiError.server(status: 429))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 1)
        XCTAssertTrue(gateway.checkOutCalls.isEmpty, "the dependent check-out must be deferred, never attempted against a not-yet-created work log")

        let itemsAfterFirstPass = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(itemsAfterFirstPass.count, 2, "both rows are still queued — nothing was wrongly conflicted")
        let checkInRow = try XCTUnwrap(itemsAfterFirstPass.first { $0.endpoint == OutboxEndpoint.checkIn.rawValue })
        let checkOutRow = try XCTUnwrap(itemsAfterFirstPass.first { $0.endpoint == OutboxEndpoint.checkOut.rawValue })
        XCTAssertEqual(checkInRow.state, OutboxState.pending.rawValue)
        XCTAssertEqual(checkInRow.attempts, 1)
        XCTAssertEqual(checkOutRow.state, OutboxState.pending.rawValue, "deferred, never conflicted")
        XCTAssertEqual(checkOutRow.attempts, 0, "never even attempted")

        // Next pass: check-in now succeeds, unblocking the check-out within the same later call.
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: workLogClientUuid))
        gateway.checkOutResult = .success(dto(
            id: "server-1", checkOutAt: Date(timeIntervalSince1970: 2_000), quantity: 5, notes: "done",
            status: "CHECKED_OUT", updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: workLogClientUuid
        ))
        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 2)
        XCTAssertEqual(gateway.checkOutCalls.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "both rows now succeed and are purged")

        let workLog = try XCTUnwrap(try context.fetch(FetchDescriptor<WorkLog>()).first)
        XCTAssertEqual(workLog.status, "CHECKED_OUT")
    }

    // MARK: - reconcile(): guards against clobbering an optimistic CHECKED_OUT row (m4a-review Minor #3)

    /// A check-in replay's response DTO is always still CHECKED_IN — the server hasn't
    /// processed the queued check-out yet, or this call wouldn't be happening. Applying it
    /// unconditionally would revert an already-optimistic CHECKED_OUT local row back to
    /// CHECKED_IN whenever the check-out hasn't *also* landed in the same pass (here: it fails
    /// with a network error right after, stopping the pass before its own reconcile can
    /// re-establish CHECKED_OUT) — the exact repro from the finding.
    func testCheckInReconcileDoesNotClobberOptimisticCheckedOutRowWhileCheckOutStillQueued() async throws {
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        // Mirrors WorkLogActions.checkIn() then .checkOut() on the same row while offline: both
        // optimistic mutations already applied before either outbox row has synced.
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_OUT", checkInAt: Date(timeIntervalSince1970: 1_000),
            checkOutAt: Date(timeIntervalSince1970: 1_500), quantity: 9.5, notes: "done",
            updatedAt: Date(timeIntervalSince1970: 1_500)
        ))
        insertCheckInItem(context: context, workLogClientUuid: workLogClientUuid, createdAt: Date(timeIntervalSince1970: 500))
        insertCheckOutItem(context: context, workLogClientUuid: workLogClientUuid, quantity: 9.5, notes: "done", createdAt: Date(timeIntervalSince1970: 600))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(
            id: "server-1", status: "CHECKED_IN", updatedAt: Date(timeIntervalSince1970: 1_100), clientUuid: workLogClientUuid
        ))
        struct Offline: Error {}
        gateway.checkOutResult = .failure(ApiError.network(Offline()))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 1)
        XCTAssertEqual(gateway.checkOutCalls.count, 1, "check-out must still be attempted right after check-in succeeds")

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1)
        XCTAssertEqual(
            workLogs.first?.status, "CHECKED_OUT",
            "the check-in replay's stale CHECKED_IN DTO must not clobber the optimistic CHECKED_OUT row while its check-out is still queued"
        )

        let remaining = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(remaining.count, 1, "the check-in row succeeded and was purged")
        XCTAssertEqual(remaining.first?.endpoint, OutboxEndpoint.checkOut.rawValue)
        XCTAssertEqual(remaining.first?.state, OutboxState.pending.rawValue)
    }

    // MARK: - drain(): purges succeeded rows instead of retaining `.done` (m4a-review Minor #4)

    /// Nothing ever reads a `.done` `SyncOutbox` row again — leaving it around just grows the
    /// table unbounded across the app's life. A successful replay must delete its row.
    func testDrainDeletesOutboxRowsOnSuccessInsteadOfRetainingThemAsDone() async throws {
        let context = try makeContext()
        let firstUuid = UUID().uuidString
        let secondUuid = UUID().uuidString
        insertCheckInItem(context: context, workLogClientUuid: firstUuid, createdAt: Date(timeIntervalSince1970: 100))
        insertCheckOutItem(context: context, workLogClientUuid: secondUuid, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: firstUuid))
        gateway.checkOutResult = .success(dto(id: "server-2", status: "CHECKED_OUT", clientUuid: secondUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        await worker.drain()

        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "a successfully-synced row must be purged, never retained as `.done`")
    }

    // MARK: - drain(): re-fetches until stable, picking up rows enqueued mid-pass (m4a-review Minor #5)

    /// A row that lands on the shared context *while* a pass is mid-request (its own
    /// fire-and-forget `Task { drain() }` no-ops on the re-entrancy guard) must still be picked
    /// up by this same `drain()` call, not stranded until the next external trigger.
    func testDrainPicksUpARowEnqueuedMidPassWithoutNeedingAnExternalTrigger() async throws {
        let context = try makeContext()
        let firstUuid = UUID().uuidString
        insertCheckInItem(context: context, workLogClientUuid: firstUuid, createdAt: Date(timeIntervalSince1970: 100))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: firstUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        let secondUuid = UUID().uuidString
        var didEnqueueSecond = false
        gateway.onCheckIn = { [weak context] in
            // Simulate a second check-in landing on the same context while the first item's
            // own request is conceptually still in flight — mirrors `WorkLogActions.enqueue`'s
            // direct insert onto the shared `ModelContext`.
            guard !didEnqueueSecond, let context else { return }
            didEnqueueSecond = true
            let payload = CheckInPayload(jobId: "job-2", workTypeId: nil, notes: nil, clientUuid: secondUuid)
            context.insert(SyncOutbox(
                clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.checkIn.rawValue,
                payload: try! JSONEncoder().encode(payload), createdAt: Date(timeIntervalSince1970: 999)
            ))
            try? context.save()
        }

        await worker.drain()

        XCTAssertEqual(gateway.checkInCalls.count, 2, "the mid-pass row must be picked up by this same drain() call")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "both rows succeed and are purged")
    }

    // MARK: - isHeld (C2)

    /// An external pause switch (set by a UI-test hook, per the pinned contract) makes `drain()`
    /// a complete no-op — nothing is fetched, nothing is attempted.
    func testDrainNoOpsWhenIsHeld() async throws {
        let context = try makeContext()
        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 100))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN"))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)
        worker.isHeld = true

        await worker.drain()

        XCTAssertTrue(gateway.checkInCalls.isEmpty, "isHeld must make drain() a complete no-op")
        XCTAssertEqual(worker.pendingCount, 1)
        XCTAssertFalse(worker.isDraining)
    }

    // MARK: - drain(): cooperative cancellation (ios-units-review Important / C4)

    /// `Task.isCancelled` is checked between items: an already-in-flight request is allowed to
    /// finish, but a not-yet-started one must never begin once cancelled.
    func testDrainStopsAtTheNextItemBoundaryWhenTaskIsCancelled() async throws {
        let context = try makeContext()
        let firstUuid = UUID().uuidString
        let secondUuid = UUID().uuidString
        insertCheckInItem(context: context, workLogClientUuid: firstUuid, createdAt: Date(timeIntervalSince1970: 100))
        let second = insertCheckInItem(context: context, workLogClientUuid: secondUuid, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        let gateway = FakeWorkLogGateway()
        gateway.checkInDelayNanoseconds = 150_000_000
        gateway.checkInResult = .success(dto(id: "server-1", status: "CHECKED_IN", clientUuid: firstUuid))
        let worker = OutboxWorker(gateway: gateway, modelContext: context)

        let task = Task { await worker.drain() }
        try await Task.sleep(nanoseconds: 20_000_000) // well inside the 150ms delay: the first item is in flight
        task.cancel()
        await task.value

        XCTAssertEqual(gateway.checkInCalls.count, 1, "the already-in-flight first item finishes, but the second must never start once cancelled")
        XCTAssertEqual(second.state, OutboxState.pending.rawValue)
        XCTAssertEqual(second.attempts, 0)
        XCTAssertFalse(worker.isDraining)
    }

    // MARK: - pendingCount / conflictCount are @Observable-tracked, stored properties (ios-units-review Minor / C3)

    /// The old `pendingCount`/`conflictCount` were computed properties reading `modelContext
    /// .fetchCount` directly — SwiftUI's `@Observable` machinery only tracks *reads of stored
    /// properties* during `withObservationTracking`'s closure, so a computed property backed by
    /// an external fetch registers no dependency at all and `onChange` would never fire
    /// (ios-units-review: `SettingsSheet` never refreshed while open). Now a stored property
    /// reassigned by `refreshCounts()`, reading it inside `withObservationTracking` must
    /// register a trackable dependency that fires when it's reassigned.
    func testPendingCountMutationIsObservationTrackable() async throws {
        let context = try makeContext()
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)

        let changed = expectation(description: "pendingCount mutation observed")
        withObservationTracking {
            _ = worker.pendingCount
        } onChange: {
            changed.fulfill()
        }

        insertCheckInItem(context: context, workLogClientUuid: UUID().uuidString, createdAt: Date())
        try context.save()
        worker.refreshCounts()

        await fulfillment(of: [changed], timeout: 1.0)
    }

    // MARK: - drain(): .elevationCreate (M5a)

    private func elevationDto(
        id: String,
        buildingId: String = "bldg-1",
        elevationNumber: Int = 1,
        numberLabel: String? = nil,
        label: String = "North Wall",
        bearing: Int? = nil,
        facing: String? = nil,
        fieldAdded: Bool = true,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        clientUuid: String? = nil
    ) -> ElevationDTO {
        ElevationDTO(
            id: id, buildingId: buildingId, elevationNumber: elevationNumber, numberLabel: numberLabel,
            label: label, bearing: bearing, facing: facing, fieldAdded: fieldAdded, updatedAt: updatedAt, clientUuid: clientUuid
        )
    }

    @discardableResult
    private func insertElevationCreateItem(
        context: ModelContext, buildingId: String = "bldg-1", label: String = "North Wall", facing: String? = nil,
        clientUuid: String, attempts: Int = 0, state: OutboxState = .pending, createdAt: Date
    ) -> SyncOutbox {
        let payload = ElevationCreatePayload(buildingId: buildingId, label: label, facing: facing, clientUuid: clientUuid)
        let item = SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.elevationCreate.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: attempts, state: state.rawValue, createdAt: createdAt
        )
        context.insert(item)
        return item
    }

    @discardableResult
    private func insertSurfaceAssignItem(
        context: ModelContext, surfaceId: String, buildingId: String = "bldg-1", elevationId: String = "elev-1",
        attempts: Int = 0, state: OutboxState = .pending, createdAt: Date
    ) -> SyncOutbox {
        let payload = SurfaceAssignPayload(surfaceId: surfaceId, buildingId: buildingId, elevationId: elevationId)
        let item = SyncOutbox(
            clientUuid: UUID().uuidString, endpoint: OutboxEndpoint.surfaceAssign.rawValue,
            payload: try! JSONEncoder().encode(payload), attempts: attempts, state: state.rawValue, createdAt: createdAt
        )
        context.insert(item)
        return item
    }

    func testDrainElevationCreateHappyPathPurgesRowAndReconcilesLocalElevation() async throws {
        let context = try makeContext()
        let clientUuid = UUID().uuidString
        context.insert(Elevation(
            id: clientUuid, buildingId: "bldg-1", elevationNumber: 99, label: "North Wall", fieldAdded: true,
            clientUuid: clientUuid, updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        insertElevationCreateItem(context: context, clientUuid: clientUuid, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.createElevationResult = .success(elevationDto(
            id: "server-elev-1", elevationNumber: 3, updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: clientUuid
        ))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        XCTAssertEqual(surveyGateway.createElevationCalls.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "a successfully-synced row is purged, never left `.done`")

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1, "reconcile must update in place, never duplicate")
        XCTAssertEqual(elevations.first?.id, clientUuid, "id stays pinned to clientUuid, never remapped to the server's own id")
        XCTAssertEqual(elevations.first?.elevationNumber, 3, "the server's authoritative elevationNumber replaces the local provisional one")
        XCTAssertEqual(elevations.first?.updatedAt, Date(timeIntervalSince1970: 2_000))
    }

    func testDrainElevationCreateInsertsRowWhenNoLocalOptimisticWriteExists() async throws {
        let context = try makeContext()
        let clientUuid = UUID().uuidString
        insertElevationCreateItem(context: context, clientUuid: clientUuid, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.createElevationResult = .success(elevationDto(id: "server-elev-1", clientUuid: clientUuid))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1)
        XCTAssertEqual(elevations.first?.id, clientUuid)
        XCTAssertEqual(elevations.first?.clientUuid, clientUuid)
    }

    func testDrainElevationCreateTwiceIsIdempotentNoDuplicateElevationsOrGatewayCalls() async throws {
        let context = try makeContext()
        let clientUuid = UUID().uuidString
        context.insert(Elevation(
            id: clientUuid, buildingId: "bldg-1", elevationNumber: 1, label: "North Wall", fieldAdded: true,
            clientUuid: clientUuid, updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        insertElevationCreateItem(context: context, clientUuid: clientUuid, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.createElevationResult = .success(elevationDto(id: "server-elev-1", clientUuid: clientUuid))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()
        XCTAssertEqual(surveyGateway.createElevationCalls.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Elevation>()), 1)

        await worker.drain()
        XCTAssertEqual(surveyGateway.createElevationCalls.count, 1, "a done row is never replayed")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Elevation>()), 1, "still exactly one row, no duplicate")
    }

    func testDrainElevationCreatePermanentServerRejectionBecomesConflict() async throws {
        let context = try makeContext()
        let item = insertElevationCreateItem(context: context, clientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.createElevationResult = .failure(ApiError.server(status: 400))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        XCTAssertEqual(item.state, OutboxState.conflict.rawValue)
        XCTAssertEqual(item.attempts, 0, "a 4xx rejection never even burns an attempt")
    }

    func testDrainElevationCreateNetworkErrorLeavesRowPendingAndStopsBeforeLaterRows() async throws {
        let context = try makeContext()
        let first = insertElevationCreateItem(context: context, clientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 100))
        let second = insertElevationCreateItem(context: context, clientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        struct Offline: Error {}
        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.createElevationResult = .failure(ApiError.network(Offline()))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        XCTAssertEqual(surveyGateway.createElevationCalls.count, 1, "must stop after the first network failure, never touch the second row")
        XCTAssertEqual(first.state, OutboxState.pending.rawValue)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertEqual(second.state, OutboxState.pending.rawValue)
        XCTAssertEqual(second.attempts, 0, "never even attempted")
    }

    func testDrainElevationCreateWithNoSurveyGatewayConfiguredStaysPendingWithoutStoppingThePass() async throws {
        // Mirrors `.photoUpload`'s identical guard: a `.elevationCreate` row enqueued before the
        // composition root wires `surveyGateway` (or a test/preview `OutboxWorker` that never
        // wires one at all) must stay queued rather than crash or wrongly conflict.
        let context = try makeContext()
        let item = insertElevationCreateItem(context: context, clientUuid: UUID().uuidString, createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        // `surveyGateway` deliberately left nil.

        await worker.drain()

        XCTAssertEqual(item.state, OutboxState.pending.rawValue)
        XCTAssertEqual(item.attempts, 1)
    }

    // MARK: - drain(): .surfaceAssign (M5a)

    func testDrainSurfaceAssignHappyPathPurgesRow() async throws {
        let context = try makeContext()
        context.insert(Surface(id: "surf-1", jobId: "job-1", label: "Front door glass", status: "MEASURED", updatedAt: Date(timeIntervalSince1970: 1_000)))
        insertSurfaceAssignItem(context: context, surfaceId: "surf-1", createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.assignSurfaceResult = .success(())
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        XCTAssertEqual(surveyGateway.assignSurfaceCalls.count, 1)
        XCTAssertEqual(surveyGateway.assignSurfaceCalls.first?.surfaceId, "surf-1")
        XCTAssertEqual(surveyGateway.assignSurfaceCalls.first?.buildingId, "bldg-1")
        XCTAssertEqual(surveyGateway.assignSurfaceCalls.first?.elevationId, "elev-1")
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty, "a successfully-synced row is purged")
    }

    func testDrainSurfaceAssignIsIdempotentOnReplay() async throws {
        let context = try makeContext()
        insertSurfaceAssignItem(context: context, surfaceId: "surf-1", createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()
        XCTAssertEqual(surveyGateway.assignSurfaceCalls.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncOutbox>()).isEmpty)

        await worker.drain()
        XCTAssertEqual(surveyGateway.assignSurfaceCalls.count, 1, "a done row is never replayed")
    }

    func testDrainSurfaceAssignPermanentServerRejectionBecomesConflict() async throws {
        let context = try makeContext()
        let item = insertSurfaceAssignItem(context: context, surfaceId: "surf-1", createdAt: Date(timeIntervalSince1970: 500))
        try context.save()

        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.assignSurfaceResult = .failure(ApiError.server(status: 404))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        XCTAssertEqual(item.state, OutboxState.conflict.rawValue)
        XCTAssertEqual(item.attempts, 0)
    }

    func testDrainSurfaceAssignNetworkErrorStaysPendingAndStopsPass() async throws {
        let context = try makeContext()
        let first = insertSurfaceAssignItem(context: context, surfaceId: "surf-1", createdAt: Date(timeIntervalSince1970: 100))
        let second = insertSurfaceAssignItem(context: context, surfaceId: "surf-2", createdAt: Date(timeIntervalSince1970: 200))
        try context.save()

        struct Offline: Error {}
        let surveyGateway = FakeSurveyWriteGateway()
        surveyGateway.assignSurfaceResult = .failure(ApiError.network(Offline()))
        let worker = OutboxWorker(gateway: FakeWorkLogGateway(), modelContext: context)
        worker.surveyGateway = surveyGateway

        await worker.drain()

        XCTAssertEqual(surveyGateway.assignSurfaceCalls.count, 1)
        XCTAssertEqual(first.state, OutboxState.pending.rawValue)
        XCTAssertEqual(first.attempts, 1)
        XCTAssertEqual(second.state, OutboxState.pending.rawValue)
        XCTAssertEqual(second.attempts, 0)
    }
}

// MARK: - SyncEngine.syncWorkLogs clientUuid dedup (M4 A-I4)

/// `SyncEngine.syncWorkLogs`'s new clientUuid-based dedup lives here rather than in
/// `SyncEngineTests.swift` (outside this task's file scope), reusing that file's
/// `StubSyncBackend` — same test target, already `internal`, not re-declared.
@MainActor
final class SyncEngineWorkLogDedupTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SyncEngineWorkLogDedupTests.\(UUID().uuidString)")!
    }

    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    func testSyncWorkLogsReconcilesLocallyCreatedRowByClientUuidInsteadOfDuplicating() async throws {
        let stub = StubSyncBackend()
        let workLogClientUuid = UUID().uuidString
        // A row this device created via an offline check-in and already reconciled once: `id` is
        // pinned to `clientUuid`, distinct from whatever the server's own row id turns out to be.
        let context = try makeContext()
        context.insert(WorkLog(
            id: workLogClientUuid, clientUuid: workLogClientUuid, jobId: "job-1", workTypeId: "wt-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try context.save()

        // The server's own projection of that same row: a DIFFERENT `id` (its real primary key),
        // the same `clientUuid`, now CHECKED_OUT.
        stub.workLogsResult = .success([
            WorkLogDTO(
                id: "server-real-id-999", jobId: "job-1", technicianId: "tech-1", workTypeId: "wt-1",
                checkInAt: Date(timeIntervalSince1970: 1_000), checkOutAt: Date(timeIntervalSince1970: 2_000),
                quantity: 4.5, notes: "done", status: "CHECKED_OUT", updatedAt: Date(timeIntervalSince1970: 2_000),
                clientUuid: workLogClientUuid
            )
        ])
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1, "must reconcile the existing clientUuid row, never insert a duplicate")
        let workLog = try XCTUnwrap(workLogs.first)
        XCTAssertEqual(workLog.id, workLogClientUuid, "id is never remapped to the server's own row id")
        XCTAssertEqual(workLog.status, "CHECKED_OUT")
        XCTAssertEqual(workLog.quantity, 4.5)
        XCTAssertEqual(workLog.technicianId, "tech-1")
    }

    func testSyncWorkLogsFallsBackToIdMatchWhenDtoHasNoClientUuid() async throws {
        // An office-created row never went through a clientUuid-keyed check-in, so its wire
        // projection's `clientUuid` is nil — must still dedup, by `id`, exactly like before M4.
        let stub = StubSyncBackend()
        let context = try makeContext()
        context.insert(WorkLog(
            id: "office-row-1", clientUuid: "office-row-1", jobId: "job-1",
            status: "CHECKED_IN", checkInAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try context.save()

        stub.workLogsResult = .success([
            WorkLogDTO(
                id: "office-row-1", jobId: "job-1", technicianId: nil, workTypeId: nil,
                checkInAt: Date(timeIntervalSince1970: 1_000), checkOutAt: Date(timeIntervalSince1970: 2_000),
                quantity: nil, notes: nil, status: "CHECKED_OUT", updatedAt: Date(timeIntervalSince1970: 2_000),
                clientUuid: nil
            )
        ])
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1)
        XCTAssertEqual(workLogs.first?.id, "office-row-1")
        XCTAssertEqual(workLogs.first?.status, "CHECKED_OUT")
    }

    func testSyncWorkLogsInsertsFreshRowKeyedByClientUuidNotServerRowId() async throws {
        // A row this device has never seen before, originated via a DIFFERENT device's
        // clientUuid-keyed check-in — a fresh insert must still key by `clientUuid`, not the
        // server's own row id, so a later sync of the same row matches it instead of duplicating.
        let stub = StubSyncBackend()
        let context = try makeContext()
        let workLogClientUuid = UUID().uuidString
        stub.workLogsResult = .success([
            WorkLogDTO(
                id: "server-real-id-1", jobId: "job-1", technicianId: "tech-2", workTypeId: nil,
                checkInAt: Date(timeIntervalSince1970: 1_000), checkOutAt: nil,
                quantity: nil, notes: nil, status: "CHECKED_IN", updatedAt: Date(timeIntervalSince1970: 1_000),
                clientUuid: workLogClientUuid
            )
        ])
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let workLogs = try context.fetch(FetchDescriptor<WorkLog>())
        XCTAssertEqual(workLogs.count, 1)
        XCTAssertEqual(workLogs.first?.id, workLogClientUuid, "fresh insert keys by clientUuid, not the server's row id")
        XCTAssertEqual(workLogs.first?.clientUuid, workLogClientUuid)
    }
}
