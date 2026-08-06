import XCTest
import SwiftData
@testable import SightLineField

final class StubSyncBackend: SyncBackend, @unchecked Sendable {
    var jobsResult: Result<[JobDTO], Error> = .success([])
    var appointmentsResult: Result<[AppointmentDTO], Error> = .success([])
    var workTypesResult: Result<[WorkTypeDTO], Error> = .success([])
    var workLogsResult: Result<[WorkLogDTO], Error> = .success([])
    var surfacesResult: Result<[SurfaceRecord], Error> = .success([])
    /// Applied to every `jobId` this stub is asked about UNLESS overridden per-job via
    /// `buildingsResultByJob` — most scenarios seed one job and use this shared result.
    var buildingsResult: Result<[BuildingDTO], Error> = .success([])
    /// Per-job override for `fetchBuildings`, taking precedence over `buildingsResult` when a
    /// key matches. Lets a scenario fail one job's fetch while a sibling succeeds — exercising
    /// `syncBuildings`'s per-job fetch-failure isolation.
    var buildingsResultByJob: [String: Result<[BuildingDTO], Error>] = [:]

    /// Artificial delay inside `fetchJobs`, used to widen the overlap window for the
    /// reentrancy test.
    var jobsDelayNanoseconds: UInt64 = 0

    private(set) var jobsSinceCalls: [Date?] = []
    private(set) var appointmentsSinceCalls: [Date?] = []
    private(set) var workTypesSinceCalls: [Date?] = []
    private(set) var workLogsSinceCalls: [Date?] = []
    private(set) var surfacesSinceCalls: [Date?] = []
    private(set) var buildingsCalls: [(jobId: String, since: Date?)] = []

    func fetchJobs(since: Date?) async throws -> [JobDTO] {
        jobsSinceCalls.append(since)
        if jobsDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: jobsDelayNanoseconds)
        }
        return try jobsResult.get()
    }

    func fetchAppointments(since: Date?) async throws -> [AppointmentDTO] {
        appointmentsSinceCalls.append(since)
        return try appointmentsResult.get()
    }

    func fetchWorkTypes(since: Date?) async throws -> [WorkTypeDTO] {
        workTypesSinceCalls.append(since)
        return try workTypesResult.get()
    }

    func fetchWorkLogs(since: Date?) async throws -> [WorkLogDTO] {
        workLogsSinceCalls.append(since)
        return try workLogsResult.get()
    }

    func fetchSurfaces(since: Date?) async throws -> [SurfaceRecord] {
        surfacesSinceCalls.append(since)
        return try surfacesResult.get()
    }

    func fetchBuildings(jobId: String, since: Date?) async throws -> [BuildingDTO] {
        buildingsCalls.append((jobId: jobId, since: since))
        if let perJob = buildingsResultByJob[jobId] { return try perJob.get() }
        return try buildingsResult.get()
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SyncEngineTests.\(UUID().uuidString)")!
    }

    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    func testFullThenDeltaWatermarkHandoff() async throws {
        let stub = StubSyncBackend()
        let t1 = Date(timeIntervalSince1970: 1_000_000)
        let t2 = Date(timeIntervalSince1970: 1_000_500)
        stub.jobsResult = .success([
            JobDTO(id: "job-1", title: "Acme HQ", number: "J-0000", status: "OPEN", customer: nil, updatedAt: t1),
            JobDTO(id: "job-2", title: "Beta Site", number: "J-0000", status: "OPEN", customer: JobDTO.Customer(name: "Beta Co"), updatedAt: t2),
        ])
        let watermarks = SyncWatermarks(defaults: freshDefaults())
        let engine = SyncEngine(backend: stub, modelContext: try makeContext(), watermarks: watermarks)

        await engine.syncAll()
        XCTAssertEqual(stub.jobsSinceCalls, [nil]) // no watermark yet — full fetch
        XCTAssertEqual(watermarks.get(.jobs), t2) // advanced to the max updatedAt seen

        stub.jobsResult = .success([
            JobDTO(id: "job-3", title: "Gamma", number: "J-0000", status: "OPEN", customer: nil, updatedAt: t2.addingTimeInterval(60))
        ])
        await engine.syncAll()
        XCTAssertEqual(stub.jobsSinceCalls, [nil, t2]) // delta from the persisted watermark
    }

    func testNewestWinsUpsertNoDuplicates() async throws {
        let stub = StubSyncBackend()
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        let t2 = t1.addingTimeInterval(10)
        // Same id twice in one page (e.g. a cursor-page overlap) — the newer one must win, no dupe row.
        stub.jobsResult = .success([
            JobDTO(id: "job-1", title: "Stale", number: "J-0000", status: "OPEN", customer: nil, updatedAt: t1),
            JobDTO(id: "job-1", title: "Fresh", number: "J-0000", status: "OPEN", customer: nil, updatedAt: t2),
        ])
        let context = try makeContext()
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()
        var jobs = try context.fetch(FetchDescriptor<JobSummary>())
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.name, "Fresh")

        // Second pass: server reports an update to the same id — must update in place, not duplicate.
        stub.jobsResult = .success([
            JobDTO(id: "job-1", title: "Updated Again", number: "J-0000", status: "CLOSED", customer: JobDTO.Customer(name: "42 Main Co"), updatedAt: t2.addingTimeInterval(10))
        ])
        await engine.syncAll()
        jobs = try context.fetch(FetchDescriptor<JobSummary>())
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.name, "Updated Again")
        XCTAssertEqual(jobs.first?.status, "CLOSED")
    }

    func testPerCollectionErrorIsolatesFailureAndContinues() async throws {
        let stub = StubSyncBackend()
        let now = Date(timeIntervalSince1970: 3_000_000)
        stub.jobsResult = .success([JobDTO(id: "job-1", title: "Acme", number: "J-0000", status: "OPEN", customer: nil, updatedAt: now)])
        stub.workTypesResult = .success([WorkTypeDTO(id: "wt-1", name: "Tint", unit: "sqft", isActive: true, updatedAt: now)])
        stub.workLogsResult = .failure(ApiError.server(status: 500))
        let context = try makeContext()
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        XCTAssertNotNil(engine.lastSyncError)
        XCTAssertTrue(engine.lastSyncError?.contains("workLogs") ?? false)
        XCTAssertNotNil(engine.lastSyncedAt) // jobs/appointments/workTypes/surfaces still landed
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<JobSummary>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkType>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkLog>()), 0)
    }

    func testIsSyncingReentrancyGuard() async throws {
        let stub = StubSyncBackend()
        stub.jobsDelayNanoseconds = 50_000_000 // 50ms: wide enough for the second call to observe isSyncing
        let engine = SyncEngine(backend: stub, modelContext: try makeContext(), watermarks: SyncWatermarks(defaults: freshDefaults()))

        async let first: Void = engine.syncAll()
        async let second: Void = engine.syncAll()
        _ = await (first, second)

        XCTAssertEqual(stub.jobsSinceCalls.count, 1) // the second call observed isSyncing and no-opped
        XCTAssertFalse(engine.isSyncing)
    }

    // MARK: - Task.isCancelled between collections (ios-units-review Important / C4)

    /// `Task.isCancelled` is checked at the top of every collection loop iteration: a
    /// `BackgroundRefresher` expiry must stop `syncAll()` before it starts the *next*
    /// collection, not run all six to completion regardless. The collection already `await`ing
    /// when cancellation lands is allowed to finish (matches `OutboxWorker.drain()`'s identical
    /// "between items" contract).
    func testSyncAllStopsBeforeTheNextCollectionOnceTaskIsCancelled() async throws {
        let stub = StubSyncBackend()
        stub.jobsDelayNanoseconds = 150_000_000 // wide margin over the 20ms cancel below
        let engine = SyncEngine(backend: stub, modelContext: try makeContext(), watermarks: SyncWatermarks(defaults: freshDefaults()))

        let task = Task { await engine.syncAll() }
        try await Task.sleep(nanoseconds: 20_000_000) // well inside the 150ms delay: .jobs is in flight
        task.cancel()
        await task.value

        XCTAssertEqual(stub.jobsSinceCalls.count, 1, "jobs had already started before cancellation landed")
        XCTAssertTrue(stub.appointmentsSinceCalls.isEmpty, "must not start the next collection once cancelled")
        XCTAssertTrue(stub.workTypesSinceCalls.isEmpty)
        XCTAssertTrue(stub.workLogsSinceCalls.isEmpty)
        XCTAssertFalse(engine.isSyncing)
    }

    func testWatermarkNotAdvancedOnFailedCollection() async throws {
        let stub = StubSyncBackend()
        stub.workLogsResult = .failure(ApiError.network(URLError(.notConnectedToInternet)))
        let watermarks = SyncWatermarks(defaults: freshDefaults())
        let engine = SyncEngine(backend: stub, modelContext: try makeContext(), watermarks: watermarks)

        await engine.syncAll()
        XCTAssertNil(watermarks.get(.workLogs))
        XCTAssertEqual(stub.workLogsSinceCalls, [nil])

        // Still failing on the second pass: since the watermark never advanced, this must be
        // asked for in full mode again, not delta from a phantom date.
        await engine.syncAll()
        XCTAssertEqual(stub.workLogsSinceCalls, [nil, nil])
        XCTAssertNil(watermarks.get(.workLogs))

        // Recovery: this pass succeeds and should finally advance the watermark.
        let t1 = Date(timeIntervalSince1970: 4_000_000)
        stub.workLogsResult = .success([
            WorkLogDTO(id: "wl-1", jobId: "job-1", technicianId: nil, workTypeId: nil, checkInAt: t1, checkOutAt: nil, quantity: nil, notes: nil, status: "CHECKED_IN", updatedAt: t1)
        ])
        await engine.syncAll()
        XCTAssertEqual(stub.workLogsSinceCalls, [nil, nil, nil])
        XCTAssertEqual(watermarks.get(.workLogs), t1)
    }
}
