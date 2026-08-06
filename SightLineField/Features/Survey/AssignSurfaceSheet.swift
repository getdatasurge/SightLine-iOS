import SwiftData
import SwiftUI

/// Presented by `JobDetailView`'s per-surface "Assign to Elevation" action (M5c) — places an
/// already-synced or field-captured `Surface` onto a building/elevation face the technician
/// picks from this job's buildings tree. Optimistic (mirrors `AddElevationSheet`/
/// `CaptureSurfaceSheet`): `ElevationActions.assignSurface` never throws and never awaits the
/// network, so there's no `isSubmitting`/error state here — the local `Surface` row's
/// placement links update immediately and the outbox syncs it (through the `Elevation
/// .serverId` chain resolver, see `Core/Sync/OutboxWorker.swift`) whenever it next drains, even
/// when the picked elevation is itself a field-added row still pending its own sync.
///
/// The picker mirrors `JobElevationsView`'s building/elevation hierarchy (one `Section` per
/// building, one tappable row per elevation) rather than a two-step cascading `Picker`: the
/// number of buildings/elevations on a typical job is small enough that a flat, directly
/// tappable list reads faster on-site than a drill-down control, and it reuses the exact
/// grouping vocabulary the technician already knows from the Elevations tab. Elevations come
/// from one flat `@Query` grouped client-side by `buildingId` — the same single-observer shape
/// `JobElevationsView.elevationsByBuilding` uses (M5c UITest-determinism fix) rather than a
/// nested per-building `@Query`, since this sheet stays open across whatever background sync
/// lands while the technician is picking.
@MainActor
struct AssignSurfaceSheet: View {
    let jobId: String
    let surface: Surface

    @Environment(ElevationActions.self) private var elevationActions
    @Environment(\.dismiss) private var dismiss

    @Query private var buildings: [Building]
    @Query(sort: \Elevation.elevationNumber) private var allElevations: [Elevation]

    @State private var selection: Elevation?

    /// Mirrors `JobElevationsView.init(jobId:)`: the filter closure captures the plain
    /// `jobId` parameter (not `self.jobId`) so `#Predicate` doesn't need to capture `self`.
    init(jobId: String, surface: Surface) {
        self.jobId = jobId
        self.surface = surface
        _buildings = Query(filter: #Predicate<Building> { $0.jobId == jobId }, sort: [SortDescriptor(\.buildingIndex)])
    }

    private var elevationsByBuilding: [String: [Elevation]] {
        Dictionary(grouping: allElevations, by: \.buildingId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if buildings.isEmpty {
                    EmptyStateView(title: "Nothing here yet", detail: "Pull to refresh after signing in")
                } else {
                    List {
                        Section {
                            LabeledContent("Pane", value: surface.label)
                        }
                        ForEach(buildings) { building in
                            Section(building.name) {
                                BuildingElevationOptions(elevations: elevationsByBuilding[building.id] ?? [], selection: $selection)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Assign to Elevation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Assign") { confirm() }
                        .disabled(selection == nil)
                }
            }
        }
    }

    private func confirm() {
        guard let elevation = selection else { return }
        // Optimistic + queued: `elevationId` is the elevation's own local id — a field-added
        // row's `clientUuid`-as-`id` until its own create syncs, or an estimator-synced row's
        // real server id already. Either way `OutboxWorker.attempt()`'s chain resolver
        // (plan §2/§5) resolves it to a real server id at dispatch time, not here.
        elevationActions.assignSurface(surfaceId: surface.id, buildingId: elevation.buildingId, elevationId: elevation.id)
        dismiss()
    }
}

/// One building's selectable elevation rows — a plain array (M5c), not its own `@Query`:
/// grouping happens once at `AssignSurfaceSheet.elevationsByBuilding` from a single flat query,
/// so this view is just a renderer with no independent store observer of its own.
private struct BuildingElevationOptions: View {
    let elevations: [Elevation]
    @Binding var selection: Elevation?

    var body: some View {
        if elevations.isEmpty {
            Text("No elevations yet")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        } else {
            ForEach(elevations) { elevation in
                let isSelected = selection?.id == elevation.id
                Button {
                    selection = elevation
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(headline(for: elevation))
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.textPrimary)
                            if let facing = elevation.facing {
                                Text(facing)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.textSecondary)
                            }
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(DS.Color.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: DS.Layout.minTouchTarget)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    /// `numberLabel` (short field code, e.g. "1") prefixed onto `label` when present — same
    /// convention `JobElevationsView.ElevationRow.headline` uses for its own rows, so an
    /// elevation reads identically here and on the Elevations tab.
    private func headline(for elevation: Elevation) -> String {
        guard let numberLabel = elevation.numberLabel, !numberLabel.isEmpty else { return elevation.label }
        return "\(numberLabel) · \(elevation.label)"
    }
}
