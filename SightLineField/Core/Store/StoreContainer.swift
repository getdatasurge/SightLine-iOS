import Foundation
import SwiftData

enum StoreContainer {
    /// `inMemory` asks for a throwaway store that outlives nothing past the test. It is
    /// implemented as a per-call ephemeral FILE-backed store rather than
    /// `isStoredInMemoryOnly`: on the newer SwiftData stack (Xcode 16 / iOS 18+, i.e. CI) the
    /// in-memory store traps (SIGTRAP) inside fetch/insert against this schema's
    /// `@Attribute(.unique)` columns — a known SwiftData sharp edge — while the file-backed
    /// path (the same one production uses) handles them correctly. Each call mints its own
    /// temp file, so tests stay isolated; the OS reaps tmp.
    static func make(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            JobSummary.self,
            Appointment.self,
            WorkType.self,
            WorkLog.self,
            Surface.self,
            Building.self,
            Elevation.self,
            SyncOutbox.self,
        ])
        let configuration: ModelConfiguration
        if inMemory {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("SightLineFieldTests-\(UUID().uuidString).store")
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
