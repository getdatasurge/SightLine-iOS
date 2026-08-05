import Foundation

/// How a collection should be fetched for a sync pass.
enum FetchMode: Equatable {
    /// No watermark yet (or it was cleared) — fetch everything.
    case full
    /// Fetch only records updated at or after `since`.
    case delta(since: Date)
}

/// A remote record identified by id with a server-reported `updatedAt`, as returned by a
/// sync page (independent of any particular model/DTO type).
struct SyncRecord: Equatable {
    let id: String
    let updatedAt: Date
}

/// A single upsert decision: the deduped record to write, and whether it's new locally.
struct UpsertPlan: Equatable {
    let record: SyncRecord
    let isNew: Bool
}

/// Pure, stateless sync decision logic — no I/O, no UI, no generated client types.
/// Consumed by `SyncEngine` (client-facing fetch/persist layer, built separately).
enum SyncPlanner {
    /// Picks full vs. delta fetch based on the collection's current watermark.
    static func decide(watermark: Date?) -> FetchMode {
        guard let watermark else { return .full }
        return .delta(since: watermark)
    }

    /// Folds newly seen `updatedAt` values into the current watermark, taking the max.
    /// Handles out-of-order pages (a later page with older dates doesn't regress the result)
    /// and simply returns `current` unchanged when `seen` is empty.
    static func advance(current: Date?, seen: [Date]) -> Date? {
        seen.reduce(current) { latest, date in
            guard let latest else { return date }
            return max(latest, date)
        }
    }

    /// Dedupes `incoming` by id, keeping the newest `updatedAt` per id, and marks each result
    /// as new (not in `existingIds`) or an update. Output order follows each id's first
    /// appearance in `incoming`.
    static func planUpserts(incoming: [SyncRecord], existingIds: Set<String>) -> [UpsertPlan] {
        var order: [String] = []
        var newestById: [String: SyncRecord] = [:]

        for record in incoming {
            if newestById[record.id] == nil {
                order.append(record.id)
            }
            if let current = newestById[record.id], current.updatedAt >= record.updatedAt {
                continue
            }
            newestById[record.id] = record
        }

        return order.compactMap { id in
            guard let record = newestById[id] else { return nil }
            return UpsertPlan(record: record, isNew: !existingIds.contains(id))
        }
    }
}
