import Foundation
import OpenAPIRuntime
import SwiftData
import SwiftUI

/// Read-only appointment detail ("Job Card") for one row tapped from `ScheduleView`. Unlike
/// `JobDetailView` (which reads its `JobSummary` straight out of the SwiftData store that
/// `SyncEngine` already owns), an appointment's full device-session projection — notes, site
/// line, linked job — has no local model to read: `Appointment` only carries the lean M2 sync
/// fields (see `AppointmentDTO`), not the Job Card projection `GET /appointments/{id}` adds.
/// So this view fetches its own detail directly on appear instead of going through the sync
/// pipeline; it never writes anything back to the store.
@MainActor
struct JobCardView: View {
    let appointmentId: String

    /// All synced jobs, used only to resolve whether the card's linked job has a local
    /// `JobSummary` to navigate into — mirrors `JobListView`'s unfiltered `@Query` rather than
    /// a per-id filter, since the id being looked up isn't known until the fetch completes.
    @Query(sort: \JobSummary.updatedAt, order: .reverse) private var jobSummaries: [JobSummary]

    @State private var phase: Phase = .loading

    /// The app's shared generated `Client`, injected from the composition root
    /// (`SightLineFieldApp` → `\.apiClient`) so this read goes through the same
    /// `BearerAuthMiddleware` refresh chain as every other call — no throwaway client.
    @Environment(\.apiClient) private var client: Client?

    private enum Phase {
        case loading
        case loaded(AppointmentDetailDTO)
        case failed(ApiError)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let detail):
                detailList(detail)
            case .failed(let error):
                VStack(spacing: 16) {
                    EmptyStateView(title: "Couldn't load", detail: message(for: error))
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.Color.accent)
                }
            }
        }
        .navigationTitle("Job Card")
        .task(id: appointmentId) { await load() }
    }

    @ViewBuilder
    private func detailList(_ detail: AppointmentDetailDTO) -> some View {
        List {
            Section("Appointment") {
                LabeledContent("Time", value: timeRange(detail))
                LabeledContent("Status") {
                    ScheduleStatusChip(status: detail.status)
                }
                LabeledContent("Notes", value: detail.notes ?? "No notes")
                LabeledContent("Site", value: detail.site ?? "No site")
            }
            if let job = detail.job {
                Section("Job") {
                    if let linkedJob = jobSummaries.first(where: { $0.id == job.id }) {
                        NavigationLink {
                            JobDetailView(job: linkedJob)
                        } label: {
                            jobRow(job)
                        }
                    } else {
                        jobRow(job)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func jobRow(_ job: AppointmentDetailDTO.Job) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title ?? job.number)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.textPrimary)
                if job.title != nil {
                    Text(job.number)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            Spacer()
            JobStatusChip(status: job.status)
        }
    }

    private func timeRange(_ detail: AppointmentDetailDTO) -> String {
        let start = detail.startsAt.formatted(date: .omitted, time: .shortened)
        let end = detail.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func message(for error: ApiError) -> String {
        switch error {
        case .network: "You're offline — check your connection and retry."
        case .unauthorized: "Your session has expired. Please sign in again."
        case .decoding: "The appointment data couldn't be read."
        case .server(let status) where status == 404: "This appointment could not be found."
        case .server(let status): "Server error (\(status))."
        }
    }

    // MARK: - Fetch

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await fetchAppointmentDetail())
        } catch let error as ApiError {
            phase = .failed(error)
        } catch {
            phase = .failed(.network(error))
        }
    }

    private func fetchAppointmentDetail() async throws -> AppointmentDetailDTO {
        guard let client else { throw ApiError.network(ClientNotInjectedError()) }
        let output: Operations.get_sol_appointments_sol__lcub_id_rcub_.Output
        do {
            output = try await client.get_sol_appointments_sol__lcub_id_rcub_(path: .init(id: appointmentId))
        } catch {
            throw ApiError.network(error)
        }
        switch output {
        case .ok(let ok):
            let payload = try ok.body.json
            return try decode(payload.data.additionalProperties, as: AppointmentDetailDTO.self)
        case .badRequest: throw ApiError.server(status: 400)
        case .unauthorized: throw ApiError.unauthorized
        case .forbidden: throw ApiError.server(status: 403)
        case .notFound: throw ApiError.server(status: 404)
        case .conflict: throw ApiError.server(status: 409)
        case .tooManyRequests: throw ApiError.server(status: 429)
        case .internalServerError: throw ApiError.server(status: 500)
        case .undocumented(let statusCode, _): throw ApiError.server(status: statusCode)
        }
    }

    // MARK: - Decoding

    /// Same round-trip-through-`Data` approach as `LiveSyncBackend`/`LiveAuthGateway`: the
    /// generated client models every `data` payload as undocumented `additionalProperties`,
    /// so this reuses `Decodable` synthesis instead of hand-parsing `OpenAPIObjectContainer`.
    private nonisolated func decode<T: Decodable>(_ container: OpenAPIObjectContainer, as type: T.Type) throws -> T {
        do {
            let data = try JSONEncoder().encode(container)
            return try Self.dtoDecoder.decode(T.self, from: data)
        } catch {
            throw ApiError.decoding
        }
    }

    private nonisolated static let dtoDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoWithFractionalSeconds.date(from: string) ?? isoWhole.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date, got \"\(string)\"")
        }
        return jsonDecoder
    }()

    private nonisolated static let isoWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated static let isoWhole = ISO8601DateFormatter()
}

/// Mirrors the device-session `GET /appointments/{id}` Job Card projection
/// (`schedulingService.AppointmentJobCard`, M3 B3) — deliberately leaner than
/// `AppointmentDTO`: no top-level `title`/`jobId`/`updatedAt` (the projection has neither;
/// `job` carries its own `id`), and `job`/`site` reflect the device branch's price-blind,
/// ownership-gated shape rather than the ApiToken branch's full `AppointmentWithContext`.
struct AppointmentDetailDTO: Decodable, Equatable, Sendable {
    struct Job: Decodable, Equatable, Sendable {
        struct Customer: Decodable, Equatable, Sendable {
            let name: String
        }
        let id: String
        let number: String
        let title: String?
        let status: String
        let customer: Customer
    }

    let id: String
    let startsAt: Date
    let endsAt: Date
    let status: String
    let notes: String?
    let site: String?
    let job: Job?
}

/// `\.apiClient` was never injected (composition-root wiring bug) — surfaced as a network
/// error so the card's Retry/error state renders instead of crashing.
struct ClientNotInjectedError: Error {}
