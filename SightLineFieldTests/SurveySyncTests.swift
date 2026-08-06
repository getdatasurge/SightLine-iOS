import XCTest
import SwiftData
@testable import SightLineField

/// M5a: building/elevation read-only sync + the widened `Surface` placement links. Reuses
/// `StubSyncBackend` (`SyncEngineTests.swift`) — same test target, already `internal`, not
/// re-declared (mirrors `BackgroundRefresherTests.swift`/`OutboxWorkerTests.swift`'s own doc
/// comments on why).
@MainActor
final class SurveySyncTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SurveySyncTests.\(UUID().uuidString)")!
    }

    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    /// Seeds a `JobSummary` directly (bypassing `syncJobs`) — `syncBuildings()` enumerates job
    /// ids from the local store, not a live fetch, so this is what stands in for "a job already
    /// synced this device or an earlier pass."
    @discardableResult
    func seedJob(_ context: ModelContext, id: String, updatedAt: Date) -> JobSummary {
        let job = JobSummary(id: id, name: "Job \(id)", status: "OPEN", updatedAt: updatedAt)
        context.insert(job)
        return job
    }

    func testBuildingTreeUpsertsIntoStore() async throws {
        let stub = StubSyncBackend()
        let t1 = Date(timeIntervalSince1970: 5_000_000)
        let context = try makeContext()
        seedJob(context, id: "job-1", updatedAt: t1)

        stub.buildingsResult = .success([
            BuildingDTO(
                id: "bldg-1", name: "Main House", buildingIndex: 1, notes: "Corner lot", updatedAt: t1,
                elevations: [
                    ElevationDTO(id: "elev-1", buildingId: "bldg-1", elevationNumber: 1, numberLabel: "1", label: "North Wall", bearing: 10, facing: "North", fieldAdded: false, updatedAt: t1),
                    ElevationDTO(id: "elev-2", buildingId: "bldg-1", elevationNumber: 2, numberLabel: nil, label: "East Wall", bearing: nil, facing: nil, fieldAdded: true, updatedAt: t1),
                ]
            )
        ])
        let watermarks = SyncWatermarks(defaults: freshDefaults())
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: watermarks)

        await engine.syncAll()

        XCTAssertEqual(stub.buildingsCalls.map(\.jobId), ["job-1"])
        XCTAssertNil(stub.buildingsCalls.first?.since) // no watermark yet — full fetch

        let buildings = try context.fetch(FetchDescriptor<Building>())
        XCTAssertEqual(buildings.count, 1)
        XCTAssertEqual(buildings.first?.jobId, "job-1")
        XCTAssertEqual(buildings.first?.name, "Main House")
        XCTAssertEqual(buildings.first?.buildingIndex, 1)
        XCTAssertEqual(buildings.first?.notes, "Corner lot")

        let elevations = try context.fetch(FetchDescriptor<Elevation>(sortBy: [SortDescriptor(\.elevationNumber)]))
        XCTAssertEqual(elevations.count, 2)
        XCTAssertEqual(elevations[0].buildingId, "bldg-1")
        XCTAssertEqual(elevations[0].numberLabel, "1")
        XCTAssertEqual(elevations[0].label, "North Wall")
        XCTAssertEqual(elevations[0].bearing, 10)
        XCTAssertEqual(elevations[0].facing, "North")
        XCTAssertFalse(elevations[0].fieldAdded)
        XCTAssertNil(elevations[1].numberLabel)
        XCTAssertNil(elevations[1].bearing)
        XCTAssertNil(elevations[1].facing)
        XCTAssertTrue(elevations[1].fieldAdded)

        XCTAssertEqual(watermarks.get(.buildings), t1)
    }

    func testDeltaResyncUpdatesChangedRowsWithoutDuplicates() async throws {
        let stub = StubSyncBackend()
        let t1 = Date(timeIntervalSince1970: 5_100_000)
        let t2 = t1.addingTimeInterval(120)
        let context = try makeContext()
        seedJob(context, id: "job-1", updatedAt: t1)

        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House", buildingIndex: 1, notes: nil, updatedAt: t1, elevations: [
                ElevationDTO(id: "elev-1", buildingId: "bldg-1", elevationNumber: 1, numberLabel: nil, label: "North Wall", bearing: nil, facing: nil, fieldAdded: false, updatedAt: t1),
            ])
        ])
        let watermarks = SyncWatermarks(defaults: freshDefaults())
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: watermarks)
        await engine.syncAll()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Building>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Elevation>()), 1)

        // Second pass: same ids, changed fields, newer updatedAt — must update in place, not duplicate.
        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House Renamed", buildingIndex: 1, notes: "Now with notes", updatedAt: t2, elevations: [
                ElevationDTO(id: "elev-1", buildingId: "bldg-1", elevationNumber: 1, numberLabel: "1", label: "North Wall (repainted)", bearing: 15, facing: "North", fieldAdded: false, updatedAt: t2),
            ])
        ])
        await engine.syncAll()

        XCTAssertEqual(stub.buildingsCalls.map(\.since), [nil, t1]) // delta from the persisted watermark

        let buildings = try context.fetch(FetchDescriptor<Building>())
        XCTAssertEqual(buildings.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(buildings.first?.name, "Main House Renamed")
        XCTAssertEqual(buildings.first?.notes, "Now with notes")

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1, "must update in place, not duplicate")
        XCTAssertEqual(elevations.first?.label, "North Wall (repainted)")
        XCTAssertEqual(elevations.first?.bearing, 15)

        XCTAssertEqual(watermarks.get(.buildings), t2)
    }

    func testSurfaceUpsertCarriesLinkIds() async throws {
        let stub = StubSyncBackend()
        let t1 = Date(timeIntervalSince1970: 5_200_000)
        stub.surfacesResult = .success([
            SurfaceRecord(jobId: "job-1", surface: SurfaceDTO(id: "surf-1", label: "Front Window", status: "MEASURED", notes: nil, buildingId: "bldg-1", elevationId: "elev-1", roomId: nil, updatedAt: t1))
        ])
        let context = try makeContext()
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let surfaces = try context.fetch(FetchDescriptor<Surface>())
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(surfaces.first?.buildingId, "bldg-1")
        XCTAssertEqual(surfaces.first?.elevationId, "elev-1")
        XCTAssertNil(surfaces.first?.roomId)
    }

    /// The buildings watermark folds `updatedAt` from BOTH buildings and elevations — an
    /// elevation-only edit (the building itself untouched) must still move the watermark, or a
    /// later delta pass would ask for it again forever.
    func testWatermarkAdvancesFromElevationUpdatedAtEvenWhenNewerThanItsBuilding() async throws {
        let stub = StubSyncBackend()
        let buildingT = Date(timeIntervalSince1970: 5_300_000)
        let elevationT = buildingT.addingTimeInterval(600) // newer than the building
        let context = try makeContext()
        seedJob(context, id: "job-1", updatedAt: buildingT)
        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House", buildingIndex: 1, notes: nil, updatedAt: buildingT, elevations: [
                ElevationDTO(id: "elev-1", buildingId: "bldg-1", elevationNumber: 1, numberLabel: nil, label: "North Wall", bearing: nil, facing: nil, fieldAdded: true, updatedAt: elevationT),
            ])
        ])
        let watermarks = SyncWatermarks(defaults: freshDefaults())
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: watermarks)

        await engine.syncAll()

        XCTAssertEqual(watermarks.get(.buildings), elevationT)
    }

    func testFetchBuildingsCalledForEveryLocalJob() async throws {
        let stub = StubSyncBackend()
        let context = try makeContext()
        seedJob(context, id: "job-1", updatedAt: Date(timeIntervalSince1970: 5_400_000))
        seedJob(context, id: "job-2", updatedAt: Date(timeIntervalSince1970: 5_400_100))
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        XCTAssertEqual(Set(stub.buildingsCalls.map(\.jobId)), ["job-1", "job-2"])
    }

    func testBuildingsWatermarkNotAdvancedOnFailure() async throws {
        let stub = StubSyncBackend()
        stub.buildingsResult = .failure(ApiError.network(URLError(.notConnectedToInternet)))
        let context = try makeContext()
        seedJob(context, id: "job-1", updatedAt: Date(timeIntervalSince1970: 5_500_000))
        let watermarks = SyncWatermarks(defaults: freshDefaults())
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: watermarks)

        await engine.syncAll()
        XCTAssertNil(watermarks.get(.buildings))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Building>()), 0)

        // Recovery: this pass succeeds and should finally advance the watermark.
        let t1 = Date(timeIntervalSince1970: 5_600_000)
        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House", buildingIndex: 1, notes: nil, updatedAt: t1, elevations: [])
        ])
        await engine.syncAll()
        XCTAssertEqual(watermarks.get(.buildings), t1)
    }
}

// MARK: - SyncEngine.syncBuildings elevation clientUuid dedup (M5a write lane)

/// `SyncEngine.syncBuildings`'s clientUuid-based elevation dedup — mirrors
/// `SyncEngineWorkLogDedupTests` (`OutboxWorkerTests.swift`) exactly, including why it lives in
/// its own class rather than folded into `SurveySyncTests` above: keeps the M5a write lane's
/// specific acceptance criterion ("create an elevation offline, then a buildings sync returns
/// it — exactly ONE local row") independently readable.
@MainActor
final class SyncEngineElevationDedupTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SyncEngineElevationDedupTests.\(UUID().uuidString)")!
    }

    func makeContext() throws -> ModelContext {
        try StoreContainer.make(inMemory: true).mainContext
    }

    func testSyncBuildingsReconcilesLocallyCreatedElevationByClientUuidInsteadOfDuplicating() async throws {
        let stub = StubSyncBackend()
        let context = try makeContext()
        context.insert(JobSummary(id: "job-1", name: "Job job-1", status: "OPEN", updatedAt: Date(timeIntervalSince1970: 1_000)))

        // A row this device created via an offline field-add and already reconciled once
        // (`OutboxWorker.reconcileElevation`): `id` is pinned to `clientUuid`, distinct from
        // whatever the server's own row id turns out to be.
        let clientUuid = UUID().uuidString
        context.insert(Elevation(
            id: clientUuid, buildingId: "bldg-1", elevationNumber: 3, label: "New Wall", fieldAdded: true,
            clientUuid: clientUuid, updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try context.save()

        // The server's own projection of that same row, nested in its building's tree: a
        // DIFFERENT `id` (its real primary key), the same `clientUuid`, an updated label.
        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House", buildingIndex: 1, notes: nil, updatedAt: Date(timeIntervalSince1970: 2_000), elevations: [
                ElevationDTO(
                    id: "server-real-elev-999", buildingId: "bldg-1", elevationNumber: 3, numberLabel: nil,
                    label: "New Wall (confirmed)", bearing: nil, facing: "North", fieldAdded: true,
                    updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: clientUuid
                ),
            ])
        ])
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1, "must reconcile the existing clientUuid row, never insert a duplicate")
        let elevation = try XCTUnwrap(elevations.first)
        XCTAssertEqual(elevation.id, clientUuid, "id is never remapped to the server's own row id")
        XCTAssertEqual(elevation.label, "New Wall (confirmed)")
        XCTAssertEqual(elevation.facing, "North")

        let buildings = try context.fetch(FetchDescriptor<Building>())
        XCTAssertEqual(buildings.count, 1, "the building itself upserts normally, unaffected by the elevation's dedup key")
    }

    func testSyncBuildingsFallsBackToIdMatchForElevationWhenDtoHasNoClientUuid() async throws {
        // An estimator-created elevation never went through a field-add, so its wire
        // projection's `clientUuid` is nil — must still dedup by `id`, exactly like before the
        // M5a write lane.
        let stub = StubSyncBackend()
        let context = try makeContext()
        context.insert(JobSummary(id: "job-1", name: "Job job-1", status: "OPEN", updatedAt: Date(timeIntervalSince1970: 1_000)))
        context.insert(Elevation(
            id: "office-elev-1", buildingId: "bldg-1", elevationNumber: 1, label: "North Wall", fieldAdded: false,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try context.save()

        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House", buildingIndex: 1, notes: nil, updatedAt: Date(timeIntervalSince1970: 2_000), elevations: [
                ElevationDTO(
                    id: "office-elev-1", buildingId: "bldg-1", elevationNumber: 1, numberLabel: nil, label: "North Wall (repainted)",
                    bearing: nil, facing: nil, fieldAdded: false, updatedAt: Date(timeIntervalSince1970: 2_000), clientUuid: nil
                ),
            ])
        ])
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1)
        XCTAssertEqual(elevations.first?.id, "office-elev-1")
        XCTAssertEqual(elevations.first?.label, "North Wall (repainted)")
    }

    func testSyncBuildingsInsertsFreshElevationKeyedByClientUuidNotServerRowId() async throws {
        // An elevation this device has never seen before, originated via a DIFFERENT device's
        // field-add — a fresh insert must still key by `clientUuid`, not the server's own row
        // id, so a later sync of the same row matches it instead of duplicating.
        let stub = StubSyncBackend()
        let context = try makeContext()
        context.insert(JobSummary(id: "job-1", name: "Job job-1", status: "OPEN", updatedAt: Date(timeIntervalSince1970: 1_000)))
        try context.save()

        let clientUuid = UUID().uuidString
        stub.buildingsResult = .success([
            BuildingDTO(id: "bldg-1", name: "Main House", buildingIndex: 1, notes: nil, updatedAt: Date(timeIntervalSince1970: 1_000), elevations: [
                ElevationDTO(
                    id: "server-real-elev-1", buildingId: "bldg-1", elevationNumber: 4, numberLabel: nil, label: "Garage Wall",
                    bearing: nil, facing: nil, fieldAdded: true, updatedAt: Date(timeIntervalSince1970: 1_000), clientUuid: clientUuid
                ),
            ])
        ])
        let engine = SyncEngine(backend: stub, modelContext: context, watermarks: SyncWatermarks(defaults: freshDefaults()))

        await engine.syncAll()

        let elevations = try context.fetch(FetchDescriptor<Elevation>())
        XCTAssertEqual(elevations.count, 1)
        XCTAssertEqual(elevations.first?.id, clientUuid, "fresh insert keys by clientUuid, not the server's row id")
        XCTAssertEqual(elevations.first?.clientUuid, clientUuid)
    }
}
