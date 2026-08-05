import Foundation
import SwiftData

enum StoreContainer {
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
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
