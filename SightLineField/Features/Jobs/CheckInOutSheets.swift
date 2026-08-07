import SwiftData
import SwiftUI

/// Presented by `JobDetailView` (no open session on this job) to start one. Work type is
/// optional — a technician may not know it yet, or the job doesn't need one — matching
/// `WorkLogActions.checkIn`'s `workTypeId: String?`.
@MainActor
struct CheckInSheet: View {
    let jobId: String
    let technicianId: String?

    @Environment(WorkLogActions.self) private var workLogActions
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \WorkType.name) private var workTypes: [WorkType]

    @State private var selectedWorkTypeId: String?
    @State private var notes = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Work Type", selection: $selectedWorkTypeId) {
                        Text("None").tag(nil as String?)
                        ForEach(workTypes) { workType in
                            Text(workType.name).tag(workType.id as String?)
                        }
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .font(DS.Font.body)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.destructive)
                }
            }
            .navigationTitle("Check In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { confirm() }
                        .disabled(isSubmitting)
                }
            }
        }
    }

    private func confirm() {
        isSubmitting = true
        // Optimistic + queued (M4 A-I3): never throws, never awaits the network — the local
        // row flips immediately and the outbox syncs it whenever it next drains.
        workLogActions.checkIn(
            jobId: jobId,
            workTypeId: selectedWorkTypeId,
            notes: notes.isEmpty ? nil : notes,
            technicianId: technicianId
        )
        dismiss()
    }
}

/// Presented by `JobDetailView` (closing its own open session) and `WorkLogsView`'s banner
/// (closing whichever job the caller's open session belongs to) — the same sheet either way,
/// parameterized by the specific `WorkLog` row being closed.
@MainActor
struct CheckOutSheet: View {
    let workLog: WorkLog

    @Environment(WorkLogActions.self) private var workLogActions
    @Environment(\.dismiss) private var dismiss

    @Query private var workTypes: [WorkType]

    @State private var quantityText = ""
    @State private var notes = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    /// The open session's own work type, if it has one and it's still known locally — labels the
    /// quantity field with its unit (e.g. "Quantity (sq ft)") rather than a bare "Quantity".
    private var quantityLabel: String {
        guard let workTypeId = workLog.workTypeId,
              let workType = workTypes.first(where: { $0.id == workTypeId }) else {
            return "Quantity"
        }
        return "Quantity (\(workType.unit))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(quantityLabel, text: $quantityText)
                        .keyboardType(.decimalPad)
                        .font(DS.Font.body)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .font(DS.Font.body)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.destructive)
                }
            }
            .navigationTitle("Check Out")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { confirm() }
                        .disabled(isSubmitting)
                }
            }
        }
    }

    private func confirm() {
        isSubmitting = true
        let quantity = Double(quantityText)
        // Keyed by the work-log's clientUuid (M4 A-B2), optimistic + queued — no server id needed.
        workLogActions.checkOut(
            workLogClientUuid: workLog.clientUuid,
            quantity: quantity,
            notes: notes.isEmpty ? nil : notes
        )
        dismiss()
    }
}
