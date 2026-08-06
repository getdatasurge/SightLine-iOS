import SwiftData
import SwiftUI

/// Building/elevation hierarchy for one job (M5a/M5b). A job's buildings are almost always
/// estimator-created on the web before a technician arrives — this view surfaces what
/// `SyncEngine.syncBuildings()` has pulled down, lets a technician add a field-discovered
/// elevation per building (`AddElevationSheet` → `ElevationActions.addElevation`), and lets
/// them capture a measured pane onto an elevation (`CaptureSurfaceSheet` →
/// `SurfaceActions.captureSurface`, M5b). Pane assignment/listing beyond capture isn't here:
/// panes are listed in `JobDetailView`'s "Surfaces" section, not this one, so the
/// assign-existing-surface affordance belongs there (deferred — see `SurveyModels.swift`'s file
/// doc comment).
@MainActor
struct JobElevationsView: View {
    let jobId: String

    @Query private var buildings: [Building]

    @State private var addElevationTarget: Building?
    @State private var captureTarget: Elevation?

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
                            BuildingElevationRows(buildingId: building.id) { elevation in
                                captureTarget = elevation
                            }
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
        .sheet(item: $captureTarget) { elevation in
            CaptureSurfaceSheet(jobId: jobId, buildingId: elevation.buildingId, elevationId: elevation.id)
        }
    }
}

/// One building's elevation rows, queried independently by `buildingId` so each section updates
/// on its own instead of the parent view holding every elevation across every building.
private struct BuildingElevationRows: View {
    @Query private var elevations: [Elevation]
    let onCapture: (Elevation) -> Void

    init(buildingId: String, onCapture: @escaping (Elevation) -> Void) {
        _elevations = Query(filter: #Predicate<Elevation> { $0.buildingId == buildingId }, sort: [SortDescriptor(\.elevationNumber)])
        self.onCapture = onCapture
    }

    var body: some View {
        if elevations.isEmpty {
            Text("No elevations yet")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        } else {
            ForEach(elevations) { elevation in
                ElevationRow(elevation: elevation, onCapture: onCapture)
            }
        }
    }
}

private struct ElevationRow: View {
    let elevation: Elevation
    let onCapture: (Elevation) -> Void

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
            Button {
                onCapture(elevation)
            } label: {
                Label("Capture Pane", systemImage: "plus.viewfinder")
                    .labelStyle(.iconOnly)
                    .font(DS.Font.body)
            }
            .buttonStyle(.borderless)
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
