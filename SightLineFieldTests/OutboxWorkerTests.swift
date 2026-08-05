import XCTest
import SwiftData
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

    private(set) var checkInCalls: [(jobId: String, workTypeId: String?, notes: String?, clientUuid: String)] = []
    private(set) var checkOutCalls: [(workLogClientUuid: String, quantity: Double?, notes: String?)] = []
    private(set) var callOrder: [String] = []

    func checkIn(jobId: String, workTypeId: String?, notes: String?, clientUuid: String) async throws -> WorkLogDTO {
        checkInCalls.append((jobId, workTypeId, notes, clientUuid))
        callOrder.append("checkIn:\(clientUuid)")
        return try checkInResult.get()
    }

    func checkOut(workLogClientUuid: String, quantity: Double?, notes: String?) async throws -> WorkLogDTO {
        checkOutCalls.append((workLogClientUuid, quantity, notes))
        callOrder.append("checkOut:\(workLogClientUuid)")
        return try checkOutResult.get()
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

    func testDrainHappyPathMarksDoneAndReconcilesLocalRow() async throws {
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
        let items = try context.fetch(FetchDescriptor<SyncOutbox>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.state, OutboxState.done.rawValue)
        XCTAssertNil(items.first?.lastError)

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
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.state == OutboxState.done.rawValue })

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
        XCTAssertEqual(item.state, OutboxState.done.rawValue)
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
