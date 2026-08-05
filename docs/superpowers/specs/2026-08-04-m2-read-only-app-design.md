# SightLine Field — M2 Read-Only App Design

Date: 2026-08-04
Status: Approved (user, this session)
Repos: `getdatasurge/SightLine` (branch `integration/field-app`, base `8223073c`) + `getdatasurge/SightLine-iOS` (`main`, post-skeleton)
Upstream: `SIGHTLINE-FIELD-APP-BRIEF.md` §5/§9-M2, skeleton spec `2026-08-04-m2-ios-skeleton-design.md` (+ its Deviations addendum), ADR-0010 (M1, live).

## Goal

The skeleton's shells fill with real, technician-scoped data: sign in → first sync → today's schedule, jobs, surfaces, work-log history — usable offline after first sync. Read-only: no writes besides auth (M3), no outbox (M4).

## Decisions (locked)

| Decision | Choice |
|---|---|
| App access | Capability-based: any ACTIVE member; price visibility gated on live `roleFlags['pricing.view']` (API projection + UI check). No Technician-role gate. |
| `technicianId=me` without a Technician row | Falls back to unfiltered (tenant-scoped) — owners see the whole board; technicians see theirs. |
| Sequencing | Backend endpoints first (curl-verifiable), then iOS sync. |
| Doc home | Specs/plans live in SightLine-iOS; web-repo work follows its house rules (module barrels, OpenAPI same commit, green gates before push). |

## Backend (web repo) — new v1 read surface

All routes: `withDeviceSession` bearer auth (M1), `{data}` envelope, cursor pagination, single error envelope, Zod at module boundaries, routes import module barrels only, OpenAPI `openapi/route.ts` entries in the same commit as each route.

| Endpoint | Source | Notes |
|---|---|---|
| `GET /technicians/me` | scheduling barrel | `{technician: {...} \| null, capabilities: string[]}` — capabilities = truthy roleFlags keys from the live membership read the session already performs. |
| `GET /work-types` | worklogs barrel `listWorkTypes` | Active first, then name. |
| `GET /work-logs` | **new** filtered/paginated barrel method (existing `listWorkLogs` returns the whole tenant set — brief §5.5) | Filters: `jobId`, `technicianId` (`me` sentinel), `status`, `updatedAfter`. |
| `GET /jobs`, `GET /jobs/{id}` | jobs barrel, **projection in the route adapter** | Price-blind: strip `total` and every money-bearing field unless `pricing.view`. Barrel untouched. |
| `GET /jobs/{id}/surfaces` | measurements barrel | Surface list: id, label, status (`SurfaceStatus`), notes, updatedAt. |
| `GET /appointments` | existing route + scheduling barrel's `technicianId` filter (`listByRange` already supports it) | Add `technicianId=me`; keep `start`/`end`/`status`. |
| `updatedAfter` filter | jobs / appointments / work-logs / surfaces lists | ISO-8601, compared against `updatedAt`, combinable with cursor pagination. |

`me` resolution: session accountId → unique `Technician.accountId` row for the session business; absent → unfiltered per decision above.

## iOS

- **Client:** refresh `openapi/openapi.json` (+ the `Core/ApiClient` copy) from a server running the grown branch; regenerate via the existing build plugin. Generated-name discipline unchanged (defensive naming documented in `AuthGateway.swift`).
- **`Core/Sync/SyncEngine`:** per-collection snapshot-then-delta:
  - Collections: jobs, appointments, work-types, work-logs, surfaces (surfaces fetched per known job).
  - Watermark = max `updatedAt` seen per collection, persisted (UserDefaults, non-secret). First sync or invalid watermark → full paged pull.
  - Inbound records upsert by id into SwiftData; deletions out of scope for M2 (no tombstones in the API yet — documented limitation).
  - Pure planning/merge logic isolated from I/O and unit-tested; network I/O through the generated client only.
  - Triggers: after login, app foreground, pull-to-refresh. Failures are silent-retryable (offline is normal); surfaced only as a "last synced" line.
- **AccountContext:** `/technicians/me` fetched at login + bootstrap fills `technicianId`/`capabilities` (skeleton left them empty — closes that deviation).
- **UI:** Schedule groups by day (Today first); Jobs list → detail (address, status, customer display name) + surfaces with `SurfaceStatus` chips (`DS.Color.surfaceStatus`); WorkLogs shows history read-only. Price fields render only with `pricing.view` capability (API already blinds them — UI check is defense-in-depth). Empty states remain for genuinely empty collections, copy drops the "(M2)" suffix.
- **Tests:** sync planner unit tests (watermark advance, full-vs-delta choice, upsert merge); login smoke UITest extends to assert a seeded job title renders after sync.

## Error handling

- Backend: existing v1 envelope; invalid `updatedAfter` → 400 `invalid_request`.
- iOS: sync errors never block UI (store-first rule); 401-after-refresh path unchanged (SessionManager). The known middleware gap (second 401 lacks forced sign-out — skeleton review Important #3) becomes live with these authenticated GETs: **M2 fixes it** — `BearerAuthMiddleware` signals `SessionManager` to sign out when the retried request 401s again.

## Out of scope

Writes (check-in/out, status advance, uploads) — M3. Outbox/conflicts/background refresh — M4. Deletion propagation, push notifications, capture — later. Logout UI ships in M2 (small, unblocks UITest isolation properly).

## Definition of done (brief §9-M2)

Seeded technician signs in on simulator → sees today's jobs and their surfaces; airplane-mode relaunch still shows them (offline-after-first-sync); no price visible for the Technician role; owner login sees full schedule + prices; both repos green (web: typecheck/lint/test + build; iOS: full suite incl. extended smoke); OpenAPI regenerated and committed in the same iOS change that consumes it.
