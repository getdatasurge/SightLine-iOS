import SwiftData
import SwiftUI

/// Building/elevation hierarchy for one job (M5a/M5b). A job's buildings are almost always
/// estimator-created on the web before a technician arrives — this view surfaces what
/// `SyncEngine.syncBuildings()` has pulled down, lets a technician add a field-discovered
/// elevation per building (`AddElevationSheet` → `ElevationActions.addElevation`), and lets
/// them capture a measured pane onto an elevation (`CaptureSurfaceSheet` →
/// `SurfaceActions.captureSurface`, M5b). Pane assignment/listing beyond capture isn't here:
/// panes are listed in `JobDetailView`'s "Surfaces" section, not this one — that section (M5c)
/// is where the assign-existing-surface affordance now lives (`AssignSurfaceSheet` →
/// `ElevationActions.assignSurface`), picking a building/elevation from the same hierarchy this
/// view renders.
@MainActor
struct JobElevationsView: View {
    let jobId: String

    @Query private var buildings: [Building]
    @Query(sort: \Elevation.elevationNumber) private var allElevations: [Elevation]

    @State private var addElevationTarget: Building?
    @State private var captureTarget: Elevation?

    /// Mirrors `JobDetailView.init(job:)`: the filter closure captures the plain `jobId`
    /// parameter (not `self.jobId`) so `#Predicate` doesn't need to capture `self`.
    init(jobId: String) {
        self.jobId = jobId
        _buildings = Query(filter: #Predicate<Building> { $0.jobId == jobId }, sort: [SortDescriptor(\.buildingIndex)])
    }

    /// Elevations grouped by `buildingId`, computed from one flat, unfiltered `@Query` instead
    /// of a nested per-building query (M5c, UITest-determinism fix): a single `@Query` observer
    /// re-diffs once per store change instead of once per building, so a background
    /// `SyncEngine.syncBuildings()` save landing mid-`.sheet` transition no longer triggers N
    /// independent re-renders competing with the sheet's own dismiss animation. Grouping the
    /// whole local `Elevation` table client-side is cheap at this app's actual scale (one
    /// technician's currently-synced jobs, not a system-wide dataset) — `Dictionary(grouping:)`
    /// preserves `allElevations`' own sort order within each building's array.
    private var elevationsByBuilding: [String: [Elevation]] {
        Dictionary(grouping: allElevations, by: \.buildingId)
    }

    var body: some View {
        Group {
            if buildings.isEmpty {
                EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
            } else {
                List {
                    ForEach(buildings) { building in
                        Section(building.name) {
                            BuildingElevationRows(elevations: elevationsByBuilding[building.id] ?? []) { elevation in
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

/// One building's elevation rows — a plain array (M5c), not its own `@Query`: grouping happens
/// once at `JobElevationsView.elevationsByBuilding` from a single flat query, so this view is
/// just a renderer with no independent store observer of its own to re-diff mid-transition.
private struct BuildingElevationRows: View {
    let elevations: [Elevation]
    let onCapture: (Elevation) -> Void

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
            .accessibilityElement(children: .combine)
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
            .frame(minWidth: DS.Layout.minTouchTarget, minHeight: DS.Layout.minTouchTarget)
            .contentShape(Rectangle())
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
