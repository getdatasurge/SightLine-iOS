import Foundation
import SwiftData

@Model
final class JobSummary {
    @Attribute(.unique) var id: String
    var name: String
    var address: String?
    var status: String
    var updatedAt: Date

    init(id: String, name: String, address: String? = nil, status: String, updatedAt: Date) {
        self.id = id
        self.name = name
        self.address = address
        self.status = status
        self.updatedAt = updatedAt
    }
}

@Model
final class Appointment {
    @Attribute(.unique) var id: String
    var jobId: String?
    var title: String
    var start: Date
    var end: Date
    var status: String
    var updatedAt: Date

    init(id: String, jobId: String? = nil, title: String, start: Date, end: Date, status: String, updatedAt: Date) {
        self.id = id
        self.jobId = jobId
        self.title = title
        self.start = start
        self.end = end
        self.status = status
        self.updatedAt = updatedAt
    }
}

@Model
final class WorkType {
    @Attribute(.unique) var id: String
    var name: String
    var unit: String
    var isActive: Bool
    var updatedAt: Date

    init(id: String, name: String, unit: String, isActive: Bool, updatedAt: Date) {
        self.id = id
        self.name = name
        self.unit = unit
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

@Model
final class WorkLog {
    @Attribute(.unique) var id: String
    var clientUuid: String
    var jobId: String
    var technicianId: String?
    var workTypeId: String?
    var status: String
    var checkInAt: Date
    var checkOutAt: Date?
    var quantity: Double?
    var notes: String?
    var updatedAt: Date

    init(
        id: String,
        clientUuid: String,
        jobId: String,
        technicianId: String? = nil,
        workTypeId: String? = nil,
        status: String,
        checkInAt: Date,
        checkOutAt: Date? = nil,
        quantity: Double? = nil,
        notes: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.clientUuid = clientUuid
        self.jobId = jobId
        self.technicianId = technicianId
        self.workTypeId = workTypeId
        self.status = status
        self.checkInAt = checkInAt
        self.checkOutAt = checkOutAt
        self.quantity = quantity
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

@Model
final class Surface {
    @Attribute(.unique) var id: String
    var jobId: String
    var label: String
    var status: String
    var updatedAt: Date

    init(id: String, jobId: String, label: String, status: String, updatedAt: Date) {
        self.id = id
        self.jobId = jobId
        self.label = label
        self.status = status
        self.updatedAt = updatedAt
    }
}

enum OutboxState: String, Codable {
    case pending
    case inFlight
    case conflict
    case done
}

@Model
final class SyncOutbox {
    @Attribute(.unique) var clientUuid: String
    var endpoint: String
    var payload: Data
    var attempts: Int
    var lastError: String?
    var state: String

    init(clientUuid: String, endpoint: String, payload: Data, attempts: Int = 0, lastError: String? = nil, state: String = OutboxState.pending.rawValue) {
        self.clientUuid = clientUuid
        self.endpoint = endpoint
        self.payload = payload
        self.attempts = attempts
        self.lastError = lastError
        self.state = state
    }
}
