# SightLine Field — M3: First Write (online-only)

Date: 2026-08-05 · Status: Draft (pending user approval)
Repos: web `integration/field-app` + iOS `feat/m3-writes` (off `feat/m2-read-only` head)
Upstream: PRD.md §4 F1/F2/F6, §6 M3; brief §5.4; ADR-0010.

## Goal

A technician checks in on a job from the app, works, checks out with a work-type quantity — online-only, idempotent, visible in web `/work-logs` immediately. Plus: Job Card (appointment detail), sync-status UI, release plumbing groundwork.

## DoD (PRD M3)

Tech checks in on a real job from the app (simulator or TestFlight when signing exists); the work log appears in web `/work-logs`; check-out records quantity; a retried check-in (same clientUuid) does not duplicate.

## Backend (web repo)

- **B1 — Idempotency key.** `clientUuid` (uuid, optional) on `checkInInputSchema`; `WorkLog.clientUuid` column, unique per business (nullable), atomic migration + DOMAIN_MODEL/TENANT_MODELS lockstep. `checkIn` with an already-seen clientUuid returns the existing row (no duplicate).
- **B2 — Write routes.** `POST /v1/work-logs/check-in`, `POST /v1/work-logs/{id}/check-out` — device-session ONLY (no ApiToken path). technicianId is FORCED to the session's technician (resolve via account; 403 when the account has no Technician row); client-supplied technicianId rejected. Standard envelopes; OpenAPI same commit.
- **B3 — Job Card read.** `GET /v1/appointments/{id}` gains the dual-auth treatment (currently ApiToken-only → 401 for devices). Device scope: own (`technicianId=me`) or unassigned appointments; others 404. Projection adds Job Card fields: `notes`, location/site line, lean `job {id, number, title, status, customer{name}}` — price-blind rules apply.
- **B4 — Gate.** typecheck/lint/tests + live curl walk (idempotent double check-in, forced technician, foreign appointment 404).

## iOS

- **I1 — Contract refresh.** Snapshot regen + client rebuild after B-wave.
- **I2 — WorkLogActions.** Small service over the generated client: `checkIn(jobId:workTypeId:notes:)` (generates clientUuid, retries safely), `checkOut(workLogId:quantity:notes:)`. On success: upsert returned row into store, then targeted workLogs delta sync. Errors surface inline (online-only: offline = clear "You're offline — try again when connected" state, no outbox yet).
- **I3 — Check-in/out UX.** JobDetail gains state-aware action: no open log → "Check In" (work-type picker sheet, optional); my open log on this job → "Check Out" (quantity + notes sheet, unit label from work-type). WorkLogs tab: open-session banner at top.
- **I4 — Job Card.** Schedule row → appointment detail: time, status, notes, site line, linked job (→ JobDetail). New `Features/Schedule/JobCardView.swift`.
- **I5 — Sync status.** Settings section: last synced (relative), last error, "Sync Now" button driving `syncAll()`.
- **I6 — Release plumbing (partial).** Branded app-icon placeholder set; Release base URL stays TBD (staging API host unknown — flagged); TestFlight signing blocked on Apple Developer account (unchanged).
- **I7 — Verification.** Unit tests at seams (WorkLogActions against stub backend; check-in idempotency retry logic), full suite, live simulator smoke: check in → verify row via web API → check out with quantity → verify.

## Non-goals (M3)

Offline writes/outbox (M4), photos (M4), explicit timestamp entry (M4), background refresh (M4), status advance on jobs/surfaces (M4+), push (M6).

## Sequencing

B-wave first (parallel: B1+B2 one agent, B3 another), gate, snapshot refresh; then iOS wave (I2–I5 parallel where files are disjoint), integration, I7.
