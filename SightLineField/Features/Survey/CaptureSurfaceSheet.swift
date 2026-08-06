import SwiftUI

/// Presented by `JobElevationsView`'s per-elevation "Capture Pane" action — captures a measured
/// glass pane (width × height, eighth-inch fractions) onto the elevation the technician tapped.
/// Optimistic (M5b, mirrors `AddElevationSheet`): `captureSurface` never throws and never awaits
/// the network, so there's no `isSubmitting`/error state here — the local `Surface` row (status
/// "MEASURED") appears immediately and the outbox syncs it (through the `Elevation.serverId`
/// chain resolver, see `Core/Sync/OutboxWorker.swift`) whenever it next drains.
///
/// Quick-sqft entry, the assign-existing-surface picker, and photo capture from this sheet are
/// all out of scope (plan §4) — this is measured (W×H) capture only.
@MainActor
struct CaptureSurfaceSheet: View {
    let jobId: String
    let buildingId: String?
    let elevationId: String?

    @Environment(SurfaceActions.self) private var surfaceActions
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var widthFraction = Self.fractionLabels[0]
    @State private var heightFraction = Self.fractionLabels[0]
    @State private var quantity = 1
    @State private var glassType = ""

    /// Eighth-inch vocabulary per the backend's `FRACTION_LABELS` enum (plan §4).
    private static let fractionLabels = ["0", "1/8", "1/4", "3/8", "1/2", "5/8", "3/4", "7/8"]

    private var isCaptureDisabled: Bool {
        label.trimmingCharacters(in: .whitespaces).isEmpty
            || !((Double(widthText) ?? 0) > 0)
            || !((Double(heightText) ?? 0) > 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                        .font(DS.Font.body)
                }
                Section {
                    TextField("Width (in)", text: $widthText)
                        .keyboardType(.decimalPad)
                        .font(DS.Font.body)
                    Picker("Width Fraction", selection: $widthFraction) {
                        ForEach(Self.fractionLabels, id: \.self) { fraction in
                            Text(fraction).tag(fraction)
                        }
                    }
                    TextField("Height (in)", text: $heightText)
                        .keyboardType(.decimalPad)
                        .font(DS.Font.body)
                    Picker("Height Fraction", selection: $heightFraction) {
                        ForEach(Self.fractionLabels, id: \.self) { fraction in
                            Text(fraction).tag(fraction)
                        }
                    }
                }
                Section {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                    TextField("Glass Type (optional)", text: $glassType)
                        .font(DS.Font.body)
                }
            }
            .navigationTitle("Capture Pane")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Capture") { confirm() }
                        .disabled(isCaptureDisabled)
                }
            }
        }
    }

    private func confirm() {
        guard let widthIn = Double(widthText), let heightIn = Double(heightText) else { return }
        // Optimistic + queued (M5b): mints `id == clientUuid` locally and enqueues
        // `.surfaceCapture` — never throws, never awaits the network. `elevationId`/`buildingId`
        // are the elevation's own local ids; the outbox chain-resolver resolves them to server
        // ids at dispatch time (`OutboxWorker.attempt()`), not here.
        surfaceActions.captureSurface(
            jobId: jobId,
            label: label,
            widthIn: widthIn,
            heightIn: heightIn,
            widthFraction: widthFraction,
            heightFraction: heightFraction,
            quantity: quantity,
            glassType: glassType.isEmpty ? nil : glassType,
            buildingId: buildingId,
            elevationId: elevationId
        )
        dismiss()
    }
}
