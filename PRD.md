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

## 3. Foundation shipped (M1–M2, done)

- **M1 (web):** device-session auth (ADR-0010) — login/refresh/rotate/revoke, `slma_` tokens, per-account device sessions.
- **M2 (both repos):** read-only field app, verified end-to-end on simulator against the live backend:
  - v1 reads: `/technicians/me`, `/work-types`, `/work-logs`, price-blind `/jobs` + `/jobs/{id}/surfaces`, `/appointments?technicianId=me`, `updatedAfter` delta filters on all of them.
  - iOS: generated OpenAPI client + 401-refresh + theft-signal middleware; Keychain sessions; bootstrap identity (technicianId + capabilities); SwiftData store; SyncEngine with per-collection delta watermarks; Schedule/Jobs/Surfaces/WorkLogs/Settings screens; sign-out cache wipe; CI; 65 unit tests + login smoke UITest.

## 4. Foundational elements remaining

In dependency order; these precede feature buildout.

| # | Element | Repo(s) | Why foundational | Milestone |
|---|---|---|---|---|
| F1 | **Write path, online-only**: check-in/out (`POST /work-logs/check-in\|out`), work-log status advance | both | First mutation; establishes idempotency keys (client UUIDs), error UX, optimistic store updates | M3 |
| F2 | **Sync status surfacing**: `lastSyncedAt`/`lastSyncError` UI in Settings + offline banner | iOS | Sync failures are currently invisible (os_log only) | M3 |
| F3 | **Outbox worker**: drain `SyncOutbox`, background retry, idempotent replay, per-record dirty flags, LWW conflict handling + audit trail, clock-skew flagging | both | PP.10 core; turns M3's online writes into offline-capable writes | M4 |
| F4 | **Photo pipeline**: capture → local persist → append-only upload; needs backend media endpoint decision (presigned direct-to-storage vs API passthrough) | both | Photos are append-only per PP.10; nothing exists on either side | M4 |
| F5 | **Background refresh**: `BGAppRefreshTask` scheduling around SyncEngine | iOS | Currently foreground-only | M4 |
| F6 | **Release plumbing**: staging base URL (currently a placeholder), app icon, TestFlight signing, versioning | iOS | Blocks any human trial | M3 |
| F7 | **Push notifications (APNs)**: dispatch-driven schedule changes | both | Needs backend notification fan-out; `notifications` module has no v1 surface | M6 |

## 5. Parity matrix

**Method.** 104 web routes (`docs/audits/audit-routes.md`) and 62 domain modules (`docs/audits/audit-modules.md`) aggregated into feature areas. **Churn** = commits touching the area's `src/app` + `src/modules` dirs in the 30 days before 2026-08-05 (`git log --since="30 days ago" --name-only`), bucketed LOW <60, MED 60–120, HIGH >120. **Verdicts:** `ADAPT` (iOS-native version), `MIRROR` (close translation), `WATCH` (field-relevant but mid-redesign — re-audit before building), `DROP` (deliberately web-only).

### Field core — build

| Feature area (web source) | Churn | Verdict | iOS shape | Milestone |
|---|---|---|---|---|
| Schedule / calendar (`/calendar`, scheduling mod) | HIGH (202+48) | ADAPT — *contract frozen at v1* | Done (M2): day-grouped list. Add: job-card push-in | M2 ✅ / M3 |
| Appointment "Job Card" (`/appointments/[id]` — built "for a visiting tech") | MED (70) | MIRROR | Access notes, site contacts, notes, attachments on appointment detail | M3 |
| Work logs check-in/out (`/work-logs`, worklogs mod) | LOW | ADAPT | Done (M2 read). M3: check-in/out buttons, work-type picker, quantity entry | M3 |
| Jobs list/detail (jobs mod; *not* `/projects` hub) | MED (94) | ADAPT | Done (M2): price-blind list + surfaces. Add: status advance where capability allows | M2 ✅ / M3 |
| Surfaces + statuses (measurements mod) | MED (118) | ADAPT | Done (M2 read). M4+: status advance offline | M2 ✅ / M4 |
| Installer view (`/projects/[id]/install` checklist) | HIGH (242, projects hub) | WATCH | Field checklist is wanted, but the projects hub is the highest-churn area in the repo — freeze a lean v1 read first | M5+ |
| Glass readings (`/glass-readings`) | LOW | ADAPT | Simple reading log against a job; natural M3/M5 add-on | M5 |
| Inspections (`/inspections`) | LOW | ADAPT | Field QA record; pairs with work-log mechanism | M5 |
| Caulking (`/caulking`, linear-ft) | LOW | ADAPT | Work-type quantity entry (linear-ft) — largely falls out of M3 work-log UX | M3/M5 |
| On-site capture (`/projects/[id]/capture`, survey mod) | HIGH (161 takeoff + survey) | WATCH — *deferred by brief (M5, own planning doc)* | Offline survey/elevation capture port | M5 (own brief) |
| Photos / uploads (uploads mod) | MED (77) | ADAPT | Capture + append-only upload (F4) | M4 |
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
| Offline banner + sync status (F2) | M3 |
| Background refresh (F5) | M4 |
| Biometric unlock (Face ID gate on stored session) | M4 |
| Camera-first photo capture (F4) | M4 |
| Push notifications for schedule changes (F7) | M6 |

## 6. Milestones

- **M3 — First write (online-only).** F1 + F2 + F6. Check-in/out from appointment/job, work-type + quantity entry, Job Card detail, sync status UI, TestFlight build against staging. *DoD: tech checks in on a real job from TestFlight; work log appears in web `/work-logs`.*
- **M4 — Offline writes.** F3 + F4 + F5 + biometrics. Outbox drains after airplane mode; photos upload append-only; conflicts LWW + audited. *DoD: check-in/out + photo captured in airplane mode lands correctly after reconnect, no duplicates (idempotency proven).*
- **M5 — Field records.** Glass readings, inspections, caulking flows; survey capture port kicks off under its own brief; installer-view/work-order re-audit (projects hub churn permitting). *DoD: per-flow.*
- **M6 — Awareness.** APNs push for schedule changes, notifications inbox, delta-sync tightening (server-push invalidation hints).
- **M7 — Hardening & launch.** Perf pass, accessibility, iPad size classes (decide: support or lock to iPhone), App Store metadata, staging→prod cutover per `sightline-staging-flow`.

Sequencing follows §2 volatility gates: M3/M4 build exclusively on LOW-churn, contract-frozen areas; WATCH rows re-audit at each boundary.

## 7. Open decisions

1. **Media upload architecture (F4):** presigned direct-to-storage vs API passthrough — needs a web-repo ADR before M4.
2. **iPad:** support with size classes or lock to iPhone at launch? (Recommend: iPhone-only until M7.)
3. **Supervisor mode:** capability-gated pricing/oversight views exist server-side (`pricing.view` already flows). Explicitly out of scope until after M4; revisit with real field feedback.
4. **Web root/marketing (`/world`) and marketplace onboarding** are unresolved on the web side — irrelevant to Field, tracked only as audit anomalies.
5. **`/old-measurements`** is a live-but-hidden retired wizard on web — flagged upstream; not parity surface.

## 8. Appendices

- `docs/audits/audit-routes.md` — 104-route inventory (screen, purpose, persona, domains).
- `docs/audits/audit-modules.md` — 62-module inventory (services, models, v1 exposure). *Note:* audited against `staging-merge`; the flagged work-logs/work-types/measurements v1 "gaps" are already closed on `integration/field-app` (M1/M2) and merge with it.
- `docs/superpowers/specs/2026-08-04-m2-read-only-app-design.md` — M2 spec incl. deviations.
- `.superpowers/sdd/progress.md` — M1–M2 execution ledger.
