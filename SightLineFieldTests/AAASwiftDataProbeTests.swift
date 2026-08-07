import XCTest
import SwiftData
@testable import SightLineField

/// Diagnostic (CI-only crash bisect): the unit suite is green on Xcode 15.4 / iOS 17 sims but
/// SIGTRAPs inside SwiftData on CI — the probe's last marker before the trap is `insert` of a
/// model carrying `@Attribute(.unique)`, on both store modes. This suite runs FIRST and bisects
/// whether the unique attribute is the trigger: identical model shape with and without
/// `.unique`, same insert/save/fetch sequence, ephemeral file-backed stores. The last marker
/// before the CI crash names the culprit.
@Model
final class ProbePlain {
    var id: String
    var value: String
    init(id: String, value: String) {
        self.id = id
        self.value = value
    }
}

@Model
final class ProbeUnique {
    @Attribute(.unique) var id: String
    var value: String
    init(id: String, value: String) {
        self.id = id
        self.value = value
    }
}

@MainActor
final class AAASwiftDataProbeTests: XCTestCase {
    func testProbePlainModel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-plain-\(UUID().uuidString).store")
        let context = try ModelContainer(
            for: ProbePlain.self, configurations: ModelConfiguration(url: url)
        ).mainContext
        print("PROBE[plain]: insert")
        context.insert(ProbePlain(id: "p1", value: "v"))
        print("PROBE[plain]: save")
        try context.save()
        print("PROBE[plain]: fetch")
        print("PROBE[plain]: fetched \(try context.fetch(FetchDescriptor<ProbePlain>()).count) done")
    }

    func testProbeUniqueModel() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-unique-\(UUID().uuidString).store")
        let context = try ModelContainer(
            for: ProbeUnique.self, configurations: ModelConfiguration(url: url)
        ).mainContext
        print("PROBE[unique]: insert")
        context.insert(ProbeUnique(id: "u1", value: "v"))
        print("PROBE[unique]: save")
        try context.save()
        print("PROBE[unique]: fetch")
        print("PROBE[unique]: fetched \(try context.fetch(FetchDescriptor<ProbeUnique>()).count) done")
    }
}
