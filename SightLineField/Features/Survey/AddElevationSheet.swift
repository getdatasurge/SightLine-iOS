import SwiftUI

/// Presented by `JobElevationsView`'s per-building "Add Elevation" action — mints a field-added
/// elevation on the given building. Optimistic (M5a, mirrors `CheckInSheet`): `addElevation`
/// never throws and never awaits the network, so there's no `isSubmitting`/error state here —
/// the local row (with its `fieldAdded` badge) appears immediately and the outbox syncs it
/// whenever it next drains.
@MainActor
struct AddElevationSheet: View {
    let buildingId: String

    @Environment(ElevationActions.self) private var elevationActions
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var selectedFacing: String?

    private var isAddDisabled: Bool {
        label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 16-point compass. `Elevation.facing` is a free-form string server-side (see
    /// `openapi.json`'s `facing` schema — plain `string`, no enum), so this is a picker
    /// vocabulary for the field tech rather than a validated set the model enforces.
    private static let compassPoints = [
        "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
        "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                        .font(DS.Font.body)
                        .submitLabel(.done)
                    Picker("Facing", selection: $selectedFacing) {
                        Text("None").tag(nil as String?)
                        ForEach(Self.compassPoints, id: \.self) { point in
                            Text(point).tag(point as String?)
                        }
                    }
                }
            }
            .navigationTitle("Add Elevation")
            .onSubmit {
                if !isAddDisabled { confirm() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { confirm() }
                        .disabled(isAddDisabled)
                }
            }
        }
    }

    private func confirm() {
        // Optimistic + queued (M5a): mints `id == clientUuid` locally and enqueues
        // `.elevationCreate` — never throws, never awaits the network.
        elevationActions.addElevation(buildingId: buildingId, label: label, facing: selectedFacing)
        dismiss()
    }
}
