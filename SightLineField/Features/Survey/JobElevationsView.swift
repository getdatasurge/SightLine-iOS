import SwiftData
import SwiftUI

/// Building/elevation hierarchy for one job (M5a). A job's buildings are almost always
/// estimator-created on the web before a technician arrives — this view surfaces what
/// `SyncEngine.syncBuildings()` has pulled down, plus lets a technician add a field-discovered
/// elevation per building (`AddElevationSheet` → `ElevationActions.addElevation`). Pane→elevation
/// assignment isn't here: panes are listed in `JobDetailView`'s "Surfaces" section, not this one,
/// so that's where the assign affordance belongs (deferred — see `SurveyModels.swift`'s file doc
/// comment).
@MainActor
struct JobElevationsView: View {
    let jobId: String

    @Query private var buildings: [Building]

    @State private var addElevationTarget: Building?

    /// Mirrors `JobDetailView.init(job:)`: the filter closure captures the plain `jobId`
    /// parameter (not `self.jobId`) so `#Predicate` doesn't need to capture `self`.
    init(jobId: String) {
        self.jobId = jobId
        _buildings = Query(filter: #Predicate<Building> { $0.jobId == jobId }, sort: [SortDescriptor(\.buildingIndex)])
    }

    var body: some View {
        Group {
            if buildings.isEmpty {
                EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
            } else {
                List {
                    ForEach(buildings) { building in
                        Section(building.name) {
                            BuildingElevationRows(buildingId: building.id)
                            Button {
                                addElevationTarget = building
                            } label: {
                                Label("Add Elevation", systemImage: "plus")
                                    .font(DS.Font.body)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Buildings")
        .sheet(item: $addElevationTarget) { building in
            AddElevationSheet(buildingId: building.id)
        }
    }
}

/// One building's elevation rows, queried independently by `buildingId` so each section updates
/// on its own instead of the parent view holding every elevation across every building.
private struct BuildingElevationRows: View {
    @Query private var elevations: [Elevation]

    init(buildingId: String) {
        _elevations = Query(filter: #Predicate<Elevation> { $0.buildingId == buildingId }, sort: [SortDescriptor(\.elevationNumber)])
    }

    var body: some View {
        if elevations.isEmpty {
            Text("No elevations yet")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        } else {
            ForEach(elevations) { elevation in
                ElevationRow(elevation: elevation)
            }
        }
    }
}

private struct ElevationRow: View {
    let elevation: Elevation

    /// `numberLabel` (short field code, e.g. "1") prefixed onto `label` (the descriptive name)
    /// when present; `label` alone otherwise — `label` is always there, `numberLabel` isn't.
    private var headline: String {
        guard let numberLabel = elevation.numberLabel, !numberLabel.isEmpty else { return elevation.label }
        return "\(numberLabel) · \(elevation.label)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                if let facing = elevation.facing {
                    Text(facing)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            Spacer()
            if elevation.fieldAdded {
                FieldAddedBadge()
            }
        }
    }
}

/// Flags an elevation an installer discovered on-site rather than one the estimator planned
/// ahead of time (`Elevation.fieldAdded`) — neutral capsule, same construction as
/// `JobStatusChip`/`SurfaceStatusChip`, no dedicated `DS.Color` token needed for a single marker.
private struct FieldAddedBadge: View {
    var body: some View {
        Text("Field-added")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.Color.accent.opacity(0.15), in: Capsule())
    }
}
