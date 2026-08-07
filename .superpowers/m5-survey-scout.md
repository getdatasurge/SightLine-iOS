# M5 survey-capture scout (WEB read-only)

Sources: `src/modules/survey|measurements|takeoff` (worktree `field-app`, HEAD
7992faf4), `prisma/schema.prisma` (Surface/Room/Building/Elevation/OpeningType/
TakeoffSheet/GlassReading/Caulking), capture routes under
`src/app/(dashboard)/{projects/[id],proposals/[id]/intake}/capture` +
`old-measurements`, `SIGHTLINE-FIELD-APP-BRIEF.md` §5–6/§9 (M5 section),
`docs/superpowers/specs/2026-08-05-m4-offline-outbox.md` (clientUuid precedent).

## 1. Survey data hierarchy

```
Job (project, container — no Survey/Area entity, WinTracker has none)
 └─ Building            (schema.prisma:994)  businessId, projectId (denorm, no FK),
                          name, buildingIndex, address*, lat/lng, officeLat/officeLng,
                          footprint (GeoJSON Polygon string), mapZoom/mapHeading,
                          imageryDate, notes, createdById (denorm), archived
     └─ Elevation        (schema.prisma:1031) businessId, buildingId (FK cascade),
                          projectId (denorm), elevationNumber (auto max+1 per building),
                          numberLabel, label, geometry (GeoJSON LineString string),
                          bearing (int°), facing (16-pt compass, derived from bearing
                          via `measurements` orientation engine, overridable via
                          facingOverridden), fieldAdded (installer-discovered on-site),
                          pinLat/pinLng (field-added map pin), filmProductId (cascades
                          to panes), caulked (bool, cascades to every pane on face)
         └─ Surface      (schema.prisma:721) the pane/leaf — optionally FKs
                          buildingId/elevationId (nullable, SET NULL on delete) AND/OR
                          roomId (Room, flat grouping) AND exactly one of
                          vehicleId/propertyId. Fields: label, widthIn/heightIn (+
                          widthFraction/heightFraction eighth-inch), areaSqFt (derived),
                          quantity, status (SurfaceStatus enum: MEASURED→CUT→
                          FILM_CUT→INSTALLED→COMPLETED + NEEDS_REVIEW/PENDING/
                          UNDER_REVIEW), direction (16-pt compass), glassType,
                          buildingIdentifier, floor, roomLabel (free-text, =
                          WinTracker `location`), recordedById/Name,
                          approvedById/Name, isLocked, measurementDate,
                          caulkOverride (null=inherit elevation.caulked),
                          measurementType/glassStrength/removalRequired/roundUp,
                          inScope, isQuickSqft (lump-sqft, no W×H, flagged
                          everywhere, excluded from work order/cut sheet/optimizer),
                          filmProductId, priceOverride, photoUrls (String[]),
                          updatedAt (delta-sync watermark, `@updatedAt` — NOTE:
                          only auto-bumps via `.update()`, NOT `updateMany()`,
                          which the service uses throughout — same caveat as Job).
```
Related but siblings, not descendants:
- `Room` (schema.prisma ~840) — flat area grouping, `propertyId` nullable,
  `name`, `filmProductId`, `approved`; `Surface.roomId` optional. Independent
  of Building/Elevation (WinTracker has no Area table either).
- `GlassReading` (1129) — meter reading (VLT/solar/thickness), optionally
  linked `buildingId`/`elevationId`/`surfaceId` (all denormalized, no FK),
  `readingValue`/`readingUnit`/`meterType`/`makeup`/`mediaUrl` (single photo/
  video, not append-only array), `recordedById/Name`, `recordedAt`.
- `Caulking` (schema.prisma ~1076) — separate linear-ft stream, `location`
  free text (not FK'd to Elevation), own `photoUrls[]`, `caulkingStatus`.
- `OpeningType`/`TakeoffSheet`/`TakeoffShape` (856/885/…) — third capture mode
  (PDF takeoff, Appendix BB); shapes commit into real Surface/Room rows.
  Independent of Building/Elevation; not in M5 scope unless PDF takeoff is
  wanted on-device (it isn't per brief — brief scopes M5 to Lane A capture).

**What the field app already syncs (M4 state):** `Surface` only, via
`GET /api/v1/jobs/{id}/surfaces` (`src/app/api/v1/jobs/[id]/surfaces/route.ts`)
— deliberately narrow projection **id/label/status/notes/updatedAt only** (no
money, no building/elevation link, no dimensions). `?updatedAfter=` delta
filter. Either-auth (API token `jobs:read` or device session, no extra
permission). SwiftData mirrors this as a `Surface` model per M4 spec §6.1.
**No Building/Elevation/Room/GlassReading sync exists at all today** — this is
the entire M5 gap.

## 2. Web capture workflow (what a tech does today, browser only)

- **Building walk / footprint trace** (office/estimator, Lane C, "walk mode"):
  `surveyService.traceBuilding` (`survey.service.ts:330`) takes ordered wall
  vertices in WALK ORDER + optional `northOffsetDeg`, derives Elevations from
  footprint sides via the `orientation` engine (bearing → 16-pt facing),
  creates Building + all Elevations in one call. `createBuilding` /
  `createElevation` exist as manual fallbacks (`AddElevationButton`
  component: label + bearing° + facing, auto-numbered server-side).
  `Elevation.fieldAdded` flags a face an installer discovers on-site (not
  estimator-planned) — the field workflow's own escape hatch already exists
  in the data model, just no field API/UI consumes it yet.
- **Pane-by-pane measurement** (the actual on-site capture, `CaptureScreen`
  under `projects/[id]/capture` and mirrored at `proposals/[id]/intake/
  capture`): ONE write path — `captureService.captureSurface` /
  `captureQuickSqft` (`capture.service.ts:63,75`) → delegates to
  `measurementsService.addSurface`/`addQuickSqft` (area engine + audit +
  tenancy), then `stampJobSite` if a jobId is present. Same action set
  (`capture`/`quickSqft`/`update`/`remove`/`createArea`/`createBuilding`/
  `createElevation`/`createSite`) is reused byte-identical between the
  accepted-job capture screen and the pre-accept proposal/intake screen (only
  difference: intake has no Building/Elevation — those are gated
  "added after the proposal is accepted", `actions.ts` stub returns an error).
  No building/elevation UI wired into the pane-capture form itself yet
  (`buildings={[]}` passed in `old-capture-tab.tsx`) — grouping a Surface onto
  a face is a separate action (`assignSurface`), not part of the capture flow.
- **Photo-per-elevation:** **does not exist.** `Elevation` has no photo field
  and no `ElevationPhoto` model; survey README explicitly lists
  `elevation_photos` under "Staged (faithful ports, later waves) — not yet
  built". Only `Surface.photoUrls[]` (pane photos), `Caulking.photoUrls[]`,
  `Inspection.photoUrls[]`, and `GlassReading.mediaUrl` (single) exist today.
- **Glass readings:** `GlassReading` model exists (meter value/unit, type,
  makeup, single media URL, optional building/elevation/surface link) but
  **no service/module wraps it** — no `glassReadings.service.ts` was found
  under `src/modules/`; it's schema-only, unconsumed. Same for `Inspection`
  (has its own `src/modules/inspections` per the brief's W27 table, separate
  from survey/measurements — QA pass, not glass capture).
- **Which services back it, summary:** `surveyService` (buildings/elevations
  CRUD + trace + assign + caulk toggles, `src/modules/survey`),
  `measurementsService`/`captureService`/`roomsService` (panes + rooms +
  one-write-path capture, `src/modules/measurements`), `takeoffService` (PDF
  mode, separate lane, not part of the tape-measure/walk flow).

## 3. v1 API gap for M5 (none of this exists today — enumerate)

Mirror the M2 device-session + M3/M4 clientUuid/idempotency patterns
(`withEitherAuth`, `{data}` envelope, cursor/`updatedAfter` pagination, Zod
boundary, OpenAPI same commit):

**Reads**
- `GET /jobs/{id}/buildings` — building list + rolled-up elevation count
  (mirrors `surveyService.listBuildings`/`listBuildingTrees`); `updatedAfter`.
- `GET /buildings/{id}/elevations` (or nest under buildings-with-elevations
  tree in one call, matching `getBuilding`'s `BuildingTree` shape) —
  elevation list per building; `updatedAfter`.
- Extend existing `GET /jobs/{id}/surfaces` projection to include
  `buildingId`/`elevationId`/`roomId` (currently stripped) — needed so the
  device can place a synced pane under its building/elevation locally.
- `GET /jobs/{id}/rooms` — currently no v1 room read at all.

**Writes** (all need `clientUuid` for offline idempotency, per M4 keystone
pattern — `WorkLog.clientUuid` precedent):
- `POST /jobs/{id}/buildings` — body mirrors `createBuildingInputSchema` +
  `clientUuid`; idempotent on `clientUuid` (unique constraint, same as
  WorkLog). Field techs won't trace footprints on a phone — this is a
  **manual add** (name/address only), not `traceBuilding`'s vertex path.
- `POST /buildings/{id}/elevations` — mirrors `createElevationInputSchema` +
  `clientUuid`; server auto-numbers `elevationNumber` same as web. This is
  the field's primary write: `fieldAdded: true` by default from this route.
- `PATCH /elevations/{id}` — label/bearing/facing/notes/caulked edits
  (LWW-eligible fields, see §4).
- `POST /surfaces/{id}/assign` — mirrors `assignSurfaceInputSchema` (place a
  captured pane onto a building/elevation).
- Reuse/extend M2's `POST /surfaces` capture write (M5 needs pane capture
  offline too — check whether M2/M3 already added a device-session surface
  **write** route; the only surfaces route found in this scan is the M2
  **read-only** `GET .../surfaces`. If no write route exists yet, M5 needs
  `POST /jobs/{id}/surfaces` wrapping `captureService.captureSurface`, plus
  `PATCH /surfaces/{id}` wrapping `measurementsService.updateSurface`).
- `POST /uploads` with a `SURFACE` holder — **already scoped for M4b**
  (`POST /api/v1/uploads`, device-session, multipart, `uploadService
  .uploadStream`, appends to `Surface.photoUrls`). M5 needs an
  **`ELEVATION` holder** added to the same route once `ElevationPhoto`
  (or an `Elevation.photoUrls[]` column) is built — today there is nowhere
  server-side to put an elevation photo.
- Building/elevation `clientUuid` column does not exist on either model yet —
  **additive migration required** before any offline write route, same as
  WorkLog's `clientUuid` was added for M4.

## 4. Offline-first considerations specific to survey (PP.10)

- **Client-UUID hierarchy creation.** Unlike WorkLog (single flat record),
  survey has a real 3-level parent chain created possibly all-offline in one
  visit: Building → Elevation → Surface, each referencing its not-yet-synced
  parent. The **outbox must preserve creation order and resolve
  `clientUuid`-typed parent refs before dispatch** — i.e. a queued
  `createElevation` payload must carry `buildingClientUuid` (not a server id)
  and the drain worker must confirm the building's outbox item reached
  `done` (or already resolve its own local-clientUuid-as-id, per M4's
  keystone pattern: "local row uses clientUuid as its id until reconciled")
  before firing the elevation create — otherwise the elevation 404s against
  a building that hasn't synced yet. This is strictly harder than M4a's flat
  WorkLog case; M4's `OutboxWorker.drain()` (oldest-first FIFO) is
  order-correct for a single chain but the **dispatch payload construction**
  needs a clientUuid→clientUuid reference resolver M4 didn't need (WorkLog
  has no parent).
- **Photo-per-surface append.** Reuse M4b's upload outbox item verbatim
  (endpoint=`uploads`, metadata + local file ref, worker uploads multipart,
  append-only, never edits/deletes). Elevation photos need the same pattern
  once the server side exists (§3) — no new client-side design, just a new
  `holder` value.
- **Per-field LWW conflict surface.** M4 spec explicitly lists "Per-field LWW
  survey merge" as an **M4 non-goal deferred to M5** — so this is new design
  work, not a port. Fields most likely to collide (edited both on-device and
  by an estimator in the office): `Elevation.label/bearing/facing/notes/
  caulked/filmProductId`, `Surface.notes/status/roomLabel/direction/
  glassType`. Recommend: `updatedAt`-compare LWW per field exactly as
  WorkLog's notes-only precedent, scoped narrow (edit metadata fields only,
  never geometry/footprint — those stay estimator/office-owned, consistent
  with the brief's "v1 scope keeps field edits minimal" stance for WorkLog).
  `Surface.status` should NOT be plain LWW — it's a state machine
  (`SurfaceStatus`); conflicting offline status advances need the same
  "the machine itself is the server's, app never invents a transition"
  discipline the brief already sets for M2's surface-status work, i.e.
  replay through the transition validator server-side and surface a
  `409`/conflict entry (not silently overwrite) if the transition is invalid
  against the current server state.
- **Immediately usable.** A building/elevation/surface created offline must
  render in the local hierarchy tree instantly (SwiftData insert with the
  clientUuid as primary key) — same "nothing in the UI awaits a request"
  discipline as M4a's WorkLog optimistic write.

## 5. Recommended M5 slicing (a/b/c)

**M5a — Field-added elevation + pane placement (smallest first shippable
slice).** Ride the existing hierarchy read-only for buildings (a job's
buildings/elevations are almost always estimator-created before the tech
arrives — office already ran the walk-mode trace or manual add on web); the
field app's job is to **add elevations the estimator missed** and **place
captured panes onto them**. Scope:
  - Backend: `Elevation.clientUuid` migration + unique index; `GET
    /jobs/{id}/buildings` (tree, read-only); `POST /buildings/{id}/elevations`
    (idempotent on clientUuid, `fieldAdded: true`); `POST /surfaces/{id}/assign`
    (idempotent — assign is naturally idempotent, no clientUuid needed).
  - iOS: SwiftData `Building`/`Elevation` (read-only sync, same delta-refresh
    pattern as `Surface`), "Add elevation" sheet (label/facing only — no
    bearing math on a phone), outbox item for elevation-create with
    buildingId resolved from the already-synced building (buildings are
    read-only in this slice, so no clientUuid-chain problem yet — this is
    what makes it the smallest slice), surface-assign action.
  - DoD: technician on-site adds a face the estimator missed, places 3
    already-captured panes onto it, works offline, syncs clean, no dupes on
    retry.

**M5b — Offline pane capture (the actual measure-and-write path).** Port
`captureService.captureSurface`/`captureQuickSqft` over v1 with
`Surface.clientUuid` (new migration) for idempotent replay; the outbox's
harder case (a pane created offline referencing an offline-created
Elevation from M5a) lands here once both parent and child can be created
offline — this is where the clientUuid-chain resolver (§4) is actually
needed. Includes photo-per-surface (reuse M4b upload outbox unchanged).

**M5c — Office-created buildings on-device + per-field LWW + glass
readings.** Full offline building creation (the elevated case: building →
elevation → surface all created offline in one visit, no server round-trip
until reconnect), per-field LWW for the notes/status-adjacent fields listed
in §4, and — only if PRD DD scope requires it on-device — `GlassReading`
capture (currently has no backing service on web at all; would need a new
`glass-readings` module written from scratch before any API/offline work,
making it the most expensive item in the whole M5 arc). Elevation-photo
upload (needs `ElevationPhoto` model or `Elevation.photoUrls[]` column,
neither exists) also lands here as it's genuinely new server-side scope, not
a port.

Rationale for ordering: M5a needs zero new offline-hierarchy-chain logic (the
one genuinely hard PP.10 problem for survey) and delivers a real field
capability (face discovery + pane placement) technicians already do on paper
today. M5b introduces the chain-resolver once, proven on the cheapest case.
M5c is genuinely new server + client feature work (LWW, glass readings
module, elevation photos) that should not gate the first two slices.
