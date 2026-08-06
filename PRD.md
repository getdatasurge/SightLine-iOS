# SightLine Field (iOS) — Product Requirements

**Status:** Living document. Written 2026-08-05 against web `staging-merge` + `integration/field-app`; the web app changes daily — re-audit triggers are defined in §2.
**Owner repos:** `getdatasurge/SightLine-iOS` (this repo) + `getdatasurge/SightLine` (v1 API surface, branch `integration/field-app`).
**Upstream:** `SIGHTLINE-FIELD-APP-BRIEF.md` (W27), ADR-0010, PP.10; parity audit appendices in `docs/audits/`.

---

## 1. Product stance

SightLine Field is the **technician's task-first tool**, not a pocket clone of the web app. The web app is the business's operating system (sales, estimating, procurement, admin); the iOS app is what a tech holds on a ladder.

Three rules derived from that stance:

1. **Mirror the brand, not the IA.** Design tokens (color, type, status vocabulary) come from web `DESIGN.md` and are already transcribed into `DS`. Screen structure is iOS-native: lists + push-in detail, pull-to-refresh, offline-first store. No dense tables, no multi-pane dashboards.
2. **The API projection is the parity boundary.** Technicians get price-blind, technician-scoped reads (server-enforced — money fields are stripped in the v1 projection unless `pricing.view`). Anything the projection excludes is *impossible* on iOS by design, not merely cramped.
3. **Offline-first is non-negotiable (PP.10).** Everything a tech sees renders from SwiftData; the network only fills the store. Shipped and proven in M2.

## 2. Concurrency doctrine — building against a moving web target

The web app changes daily/hourly (measured: 240+ commits in 30 days on `projects` alone). iOS development runs concurrently and must not chase churn. Mechanisms:

- **Contract-first seam.** iOS codes only against the committed OpenAPI snapshot (`openapi/openapi.json`), regenerated from a live server at each milestone start. Web-side UI churn is invisible to iOS unless the v1 contract moves. M2 proved this seam catches drift (5 real contract mismatches surfaced by the generated client + live smoke).
- **Volatility gates.** Each parity-matrix row carries a churn score (commits touching that area in the last 30 days, measured from git history — methodology in §5). Rule: **do not build an iOS surface against an area scoring HIGH (>120) unless the field-facing v1 contract for it is explicitly frozen.** Volatile areas sit in WATCH until they cool.
- **Re-audit triggers.** Refresh the matrix (re-run `docs/audits/` inventories + churn counts) at every milestone boundary, or when the web team lands a redesign touching any WATCH row.
- **v1 routes are the treaty.** Web-side refactors may not change v1 response shapes without a version bump; iOS pins behavior with the generated client + CI build against the committed snapshot.

## 3. Foundation shipped (M1–M4 done, M5a read + backend writes done, M5a iOS writes in progress)

- **M1 (web):** device-session auth (ADR-0010) — login/refresh/rotate/revoke, `slma_` tokens, per-account device sessions.
- **M2 (both repos, done):** read-only field app, verified end-to-end on simulator against the live backend:
  - v1 reads: `/technicians/me`, `/work-types`, `/work-logs`, price-blind `/jobs` + `/jobs/{id}/surfaces`, `/appointments?technicianId=me`, `updatedAfter` delta filters on all of them.
  - iOS: generated OpenAPI client + 401-refresh + theft-signal middleware; Keychain sessions; bootstrap identity (technicianId + capabilities); SwiftData store; SyncEngine with per-collection delta watermarks; Schedule/Jobs/Surfaces/WorkLogs/Settings screens; sign-out cache wipe; CI.
- **M3 (both repos, done):** first write, online-only. `clientUuid` idempotency keystone (check-in retried on the same key never duplicates); `POST /work-logs/check-in|check-out`, device-session only, technicianId forced server-side; Job Card (`GET /appointments/{id}`) gains device-session access + price-blind projection; iOS `WorkLogActions` + check-in/out UX on Job Detail, sync-status section in Settings ("last synced" + "Sync Now"). DoD proven live: UI check-in → row in web `/work-logs` (`seed-demo-tech-1`) → UI check-out qty 7.5 → server `CHECKED_OUT`.
- **M4 (both repos, done):** offline outbox — turns M3's online-only writes into PP.10-compliant offline-capable ones.
  - **Optimistic clientUuid writes:** check-in/out write the local `WorkLog` immediately (local `id == clientUuid` forever, no id-remapping) and enqueue a durable `SyncOutbox` row; `OutboxWorker` drains oldest-first, dispatches by `endpoint`, classifies outcomes (4xx → conflict, network/401 → stop-the-pass, 429/5xx → bump attempts without stopping), reconciles by `clientUuid` never server `id`.
  - **Idempotent check-out:** backend `check-out` re-keyed off `workLogClientUuid` (was path `{id}`, which offline has none of yet) — replay on an already-checked-out log returns the same row.
  - **Photo capture + upload outbox:** `PhotosPicker`-driven capture on Job Detail, JPEG re-encode, append-only `POST /uploads` (multipart passthrough, resolving PRD open-decision #1); rides the same outbox/drain machinery via a settable `OutboxWorker.photoGateway`. Camera-source capture (vs. library picker) is not yet wired — flagged as a follow-up, not a blocker.
  - **Drain triggers:** connectivity-regained (`NWPathMonitor` edge detection, fires once per offline→online transition), foreground (`scenePhase == .active`), and background (`BGAppRefreshTask` via SwiftUI's `.backgroundTask(.appRefresh(...))` hook, `+15min` earliest-begin, cooperative cancellation on expiry).
  - **Biometric unlock gate:** Face ID over a restored session on cold launch/foreground-return; non-blocking fallback when biometrics are unavailable or disabled (simulator, opted-out devices).
  - Reviewed (`ios-units-review.md`, `m4a-review.md`): one Important (background-refresh cancellation propagation) and two Minor findings from the units review, plus two Important core-outbox bugs from the outbox-specific review (offline check-in's local row was invisible to the technician-scoped query, and a queued check-out could permanently conflict when its check-in transient-failed) — all fixed in the integration wave (`ddb22b6`), independently re-verified with RED-mutation tests per fix.
- **M5a (both repos, read + backend writes done; iOS field-added-elevation writes in progress):**
  - Read (done): `GET /jobs/{id}/buildings` (price-blind building/elevation tree, `updatedAfter` delta at the building level); `Surface` projection widened with `buildingId`/`elevationId`/`roomId`; iOS `Building`/`Elevation` SwiftData mirrors + `SyncEngine.syncBuildings()` + `JobElevationsView` read screen.
  - Backend writes (done, reviewed clean): `POST /buildings/{id}/elevations` (device-session, idempotent on a required `clientUuid`, server auto-numbers `elevationNumber`, `fieldAdded: true`); `POST /surfaces/{id}/assign` (device-session, naturally idempotent pane→building/elevation assignment).
  - iOS writes (in progress): `OutboxWorker` gains `.elevationCreate`/`.surfaceAssign` endpoint cases behind a settable `surveyGateway`, a new `ElevationActions` (optimistic add-elevation + assign-surface mirroring the `WorkLogActions`/M4 clientUuid pattern), and Job Elevations UI to add an elevation / assign a surface in the field. Not yet composition-root-wired or committed as of this status update.

**Verification status.** 131 unit tests green (`SightLineFieldTests`, full suite). Login, M3 write-flow, and M4 offline-outbox UITest smokes green against the paired local dev server (`localhost:3005`) — retry-tolerant, since they run against a live backend + seed data rather than mocks. Per house rule, no `xcodebuild` runs during the parallel M4/M5a build wave (would clash across concurrent agents); every task instead verified via scratch-SPM TDD (RED-mutation-checked) + `swiftc -typecheck` against the real generated OpenAPI client, with `xcodebuild`/full-suite runs reserved for the controller's own integration passes.

**External blockers (unchanged, tracked since M3):** Apple Developer account for TestFlight signing — blocks any real-device or TestFlight distribution. Staging API base URL is still a placeholder in the Release configuration (F6 partially done: app-icon placeholder + release plumbing exist; the actual staging host is unknown pending web-side infra).

## 4. Foundational elements

In dependency order; F1–F6 are delivered (F6 partially — see table). F7 remains, targeted for M6.

| # | Element | Repo(s) | Why foundational | Milestone |
|---|---|---|---|---|
| F1 | **Write path, online-only**: check-in/out (`POST /work-logs/check-in\|out`), work-log status advance | both | First mutation; establishes idempotency keys (client UUIDs), error UX, optimistic store updates | M3 ✅ |
| F2 | **Sync status surfacing**: `lastSyncedAt`/`lastSyncError` UI in Settings + offline banner | iOS | Sync failures are currently invisible (os_log only) | M3 ✅ |
| F3 | **Outbox worker**: drain `SyncOutbox`, retry, idempotent replay, per-record dirty flags, reconcile-by-clientUuid | both | PP.10 core; turns M3's online writes into offline-capable writes | M4 ✅ |
| F4 | **Photo pipeline**: capture → local persist → append-only upload; resolved on API-passthrough multipart | both | Photos are append-only per PP.10 | M4 ✅ (library picker only; camera source not yet wired) |
| F5 | **Background refresh**: `BGAppRefreshTask` scheduling around SyncEngine | iOS | Currently foreground-only | M4 ✅ |
| F6 | **Release plumbing**: staging base URL (currently a placeholder), app icon, TestFlight signing, versioning | iOS | Blocks any human trial | M3 partial — app-icon placeholder shipped; staging base URL + TestFlight signing (Apple Developer account) still blocked |
| F7 | **Push notifications (APNs)**: dispatch-driven schedule changes | both | Needs backend notification fan-out; `notifications` module has no v1 surface | M6 |

## 5. Parity matrix

**Method.** 104 web routes (`docs/audits/audit-routes.md`) and 62 domain modules (`docs/audits/audit-modules.md`) aggregated into feature areas. **Churn** = commits touching the area's `src/app` + `src/modules` dirs in the 30 days before 2026-08-05 (`git log --since="30 days ago" --name-only`), bucketed LOW <60, MED 60–120, HIGH >120. **Verdicts:** `ADAPT` (iOS-native version), `MIRROR` (close translation), `WATCH` (field-relevant but mid-redesign — re-audit before building), `DROP` (deliberately web-only).

### Field core — build

| Feature area (web source) | Churn | Verdict | iOS shape | Milestone |
|---|---|---|---|---|
| Schedule / calendar (`/calendar`, scheduling mod) | HIGH (202+48) | ADAPT — *contract frozen at v1* | Done (M2): day-grouped list. Add: job-card push-in | M2 ✅ / M3 |
| Appointment "Job Card" (`/appointments/[id]` — built "for a visiting tech") | MED (70) | MIRROR | Done (M3): access notes, site contacts, notes on appointment detail | M3 ✅ |
| Work logs check-in/out (`/work-logs`, worklogs mod) | LOW | ADAPT | Done (M2 read, M3 online write, M4 offline write): check-in/out buttons, work-type picker, quantity entry, optimistic clientUuid outbox | M2 ✅ / M3 ✅ / M4 ✅ |
| Jobs list/detail (jobs mod; *not* `/projects` hub) | MED (94) | ADAPT | Done (M2): price-blind list + surfaces. Add: status advance where capability allows | M2 ✅ / M3 |
| Surfaces + statuses (measurements mod) | MED (118) | ADAPT | Done (M2 read; M5a: building/elevation/room links). Status advance offline still open | M2 ✅ / M5a ✅ (links) |
| Installer view (`/projects/[id]/install` checklist) | HIGH (242, projects hub) | WATCH | Field checklist is wanted, but the projects hub is the highest-churn area in the repo — freeze a lean v1 read first | M5+ |
| Glass readings (`/glass-readings`) | LOW | ADAPT | Simple reading log against a job; natural M3/M5 add-on | M5 |
| Inspections (`/inspections`) | LOW | ADAPT | Field QA record; pairs with work-log mechanism | M5 |
| Caulking (`/caulking`, linear-ft) | LOW | ADAPT | Work-type quantity entry (linear-ft) — largely falls out of M3 work-log UX | M3/M5 |
| On-site capture (`/projects/[id]/capture`, survey mod) | HIGH (161 takeoff + survey) | WATCH — *deferred by brief (M5, own planning doc)* | Building/elevation read sync + field-added-elevation writes done (M5a); full offline survey/elevation capture port remains M5b/M5c | M5a ✅ (read + writes) / M5b–c |
| Photos / uploads (uploads mod) | MED (77) | ADAPT | Done (M4): capture (library picker) + append-only upload outbox | M4 ✅ |
| Notifications inbox (`/notifications`) | LOW–MED (57) | ADAPT | Push + lean inbox; needs v1 surface | M6 |
| Work order (print) (`/projects/[id]/work-order`) | HIGH (projects) | WATCH | Tech is the *consumer* — a read-only "today's work order" view may replace print | M5+ |

### Deliberately web-only — DROP (non-goals)

| Feature area | Churn | Rationale |
|---|---|---|
| Estimating: proposals, quotes, bids, takeoff (`/proposals`, `/bids`, `/estimates`, takeoff) | HIGH (223/226/161/138) | Owner/office persona; highest churn in repo; price-blind API excludes the data by design |
| Financial: invoices, billing, costing, contracts, customer POs | MED | Office persona; money data excluded from device sessions |
| Inventory & procurement: catalog, rolls, optimizer, POs, suppliers, reservations | MED (72/67) | Warehouse/office workflows; cut optimizer is a desktop math tool |
| CRM admin: contacts (+merge/import), buildings, lead forms, notes feed, subcontractors | HIGH (customers 180) | Office persona. *Read-only site/contact info reaches techs via the Job Card instead* |
| Admin/settings: teams, pricing, business, org, integrations, API tokens, automations, audit, data export | HIGH (137/130) | Admin persona, desktop-appropriate |
| Reporting: dashboard, analytics, measurement rollup, search | LOW–MED | Office persona; cross-entity search needs no mobile answer yet |
| Marketplace (12 routes, cross-tenant) + installer profiles | MED (94/84) | Separate persona and product surface; if mobile demand emerges it is its **own app/PRD**, not Field scope |
| Public/customer pages (`/p`, `/review`, `/f`, `/appt`, `/world`), help center, support | LOW | Web links serve these; no app needed |
| Documents/warranties vault, e-sign | LOW–MED | Office persona; doc *viewing* on iOS only if Job Card attachments demand it (M3 will tell) |

### iOS-native (no web equivalent)

| Feature | Milestone |
|---|---|
| Offline banner + sync status (F2) | M3 ✅ |
| Background refresh (F5) | M4 ✅ |
| Biometric unlock (Face ID gate on stored session) | M4 ✅ |
| Camera-first photo capture (F4) | M4 partial ✅ (library picker; camera source not yet wired) |
| Push notifications for schedule changes (F7) | M6 |

## 6. Milestones

- **M3 — First write (online-only). Done.** F1 + F2 + partial F6. Check-in/out from appointment/job, work-type + quantity entry, Job Card detail, sync status UI. *DoD proven live: check-in on a job from the simulator; work log appears in web `/work-logs`.* TestFlight distribution itself remains blocked on F6 (below).
- **M4 — Offline writes. Done.** F3 + F4 + F5 + biometrics. Outbox drains on reconnect/foreground/background; photos upload append-only; idempotent replay via clientUuid (no LWW/audit-trail/clock-skew layer built — not needed yet, single-writer-per-record so far). *DoD proven: check-in/out + photo captured while offline (outbox held) lands correctly once drained, no duplicates — unit-tested + UITest smoke; 2 Important core-outbox bugs found in review and fixed before this status.*
- **M5 — Field records. In progress.** M5a: building/elevation read sync + surface links (done) and field-added-elevation + pane-assignment writes (backend done; iOS write UI in progress). Glass readings, inspections, caulking flows, full survey/elevation capture port (M5b/M5c), installer-view/work-order re-audit remain. *DoD: per-flow.*
- **M6 — Awareness.** APNs push for schedule changes, notifications inbox, delta-sync tightening (server-push invalidation hints).
- **M7 — Hardening & launch.** Perf pass, accessibility, iPad size classes (decide: support or lock to iPhone), App Store metadata, staging→prod cutover per `sightline-staging-flow`.

Sequencing follows §2 volatility gates: M3/M4 build exclusively on LOW-churn, contract-frozen areas; WATCH rows re-audit at each boundary.

## 7. Open decisions

1. **Media upload architecture (F4): resolved.** API passthrough (`POST /uploads`, multipart, reusing `uploadService.uploadStream()`) — the repo's only existing upload convention; no presigned-storage flow exists. Shipped in M4b.
2. **iPad:** support with size classes or lock to iPhone at launch? (Recommend: iPhone-only until M7.)
3. **Supervisor mode:** capability-gated pricing/oversight views exist server-side (`pricing.view` already flows). Explicitly out of scope until after M4; revisit with real field feedback.
4. **Web root/marketing (`/world`) and marketplace onboarding** are unresolved on the web side — irrelevant to Field, tracked only as audit anomalies.
5. **`/old-measurements`** is a live-but-hidden retired wizard on web — flagged upstream; not parity surface.

## 8. Appendices

- `docs/audits/audit-routes.md` — 104-route inventory (screen, purpose, persona, domains).
- `docs/audits/audit-modules.md` — 62-module inventory (services, models, v1 exposure). *Note:* audited against `staging-merge`; the flagged work-logs/work-types/measurements v1 "gaps" are already closed on `integration/field-app` (M1/M2) and merge with it.
- `docs/superpowers/specs/2026-08-04-m2-read-only-app-design.md` — M2 spec incl. deviations.
- `docs/superpowers/specs/2026-08-05-m3-first-write.md` — M3 spec.
- `docs/superpowers/specs/2026-08-05-m4-offline-outbox.md` — M4 spec (outbox keystone, photos, background/biometric).
- `.superpowers/sdd/progress.md` — M1–M3 execution ledger (local, gitignored).
- `.superpowers/sdd/{m4a-corewrite,m4b-photos,m4c-bgrefresh,m4c-biometric,m4-intg-a,m4-intg-b,m4-intg-c,m4-offline-uitest,m5a-readsync,m5a-backend}-report.md`, `ios-units-review.md`, `m4a-review.md` — per-slice implementation/verification reports and reviews behind this status update (local, gitignored).
