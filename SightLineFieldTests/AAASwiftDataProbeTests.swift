import XCTest
import SwiftData
@testable import SightLineField

/// Diagnostic (CI-only crash bisect): the unit suite is green on Xcode 15.4 (Swift 5.10) but
/// SIGTRAPs inside SwiftData on CI (Xcode 16.4, Swift 6) — the `#Predicate` macro expands
/// differently per compiler and some shape traps at runtime. This suite is named to run FIRST
/// and prints a PROBE marker before every SwiftData primitive; the last marker in the CI log
/// before the crash names the exact call + predicate shape that traps, for both store modes.
@MainActor
final class AAASwiftDataProbeTests: XCTestCase {
    func testProbeFileBacked() throws { try probe(inMemory: false) }
    func testProbeInMemory() throws { try probe(inMemory: true) }

    private func probe(inMemory: Bool) throws {
        let mode = inMemory ? "mem" : "file"
        print("PROBE[\(mode)]: make container")
        let context = try StoreContainer.make(inMemory: inMemory).mainContext

        print("PROBE[\(mode)]: insert")
        context.insert(SyncOutbox(clientUuid: "c1", endpoint: "checkIn", payload: Data()))
        print("PROBE[\(mode)]: save")
        try context.save()

        print("PROBE[\(mode)]: fetch all (no predicate)")
        let all = try context.fetch(FetchDescriptor<SyncOutbox>())
        print("PROBE[\(mode)]: fetched \(all.count)")

        print("PROBE[\(mode)]: fetchCount all (no predicate)")
        print("PROBE[\(mode)]: count \(try context.fetchCount(FetchDescriptor<SyncOutbox>()))")

        let pending = OutboxState.pending.rawValue
        print("PROBE[\(mode)]: fetchCount single-eq captured local")
        _ = try context.fetchCount(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate { $0.state == pending }
        ))

        let inFlight = OutboxState.inFlight.rawValue
        print("PROBE[\(mode)]: fetchCount OR two captured locals")
        _ = try context.fetchCount(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate { $0.state == pending || $0.state == inFlight }
        ))

        print("PROBE[\(mode)]: fetch single-eq captured local")
        _ = try context.fetch(FetchDescriptor<SyncOutbox>(
            predicate: #Predicate { $0.state == pending }
        ))

        let jobId = "job-1"
        print("PROBE[\(mode)]: fetch AND captured local + string literal")
        _ = try context.fetch(FetchDescriptor<WorkLog>(
            predicate: #Predicate { $0.jobId == jobId && $0.status == "CHECKED_IN" }
        ))

        print("PROBE[\(mode)]: done")
    }
}
