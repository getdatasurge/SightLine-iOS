# SightLine Field — M4: Offline Outbox, Photos, Background & Biometric

Date: 2026-08-05 · Status: Draft (pending approval)
Repos: web `integration/field-app` + iOS `feat/m4-offline` (off `feat/m3-writes` head)
Upstream: PRD.md §4 F3/F4/F5 + §6 M4; brief PP.10; resolves PRD open-decision #1.

## Goal

Turn M3's online-only writes into offline-capable ones (PP.10): every mutation is applied
optimistically to the local store and drained from a durable outbox with idempotent replay;
append-only photo capture rides the same outbox; background refresh + biometric gate round it out.

## Resolved design decision (PRD open #1)

Photo upload = **API-passthrough multipart**, the repo's only convention (scout: every upload path
streams through `getStorage().putStream()`; no presigned flow exists). M4 adds a device-session v1
route reusing `uploadService.uploadStream()` verbatim.

## Keystone: clientUuid as cross-wire identity

Offline, a check-in has no server id, so its check-out can't reference one. Fix: the check-in's
`clientUuid` is the work-log's durable identity across the wire. Check-out keys by it; sync dedups
by it; the local row uses it as its `id` until reconciled. No id-remapping anywhere.

---

## M4a — Outbox foundation (keystone slice)

### Backend (web)
- **A-B1**: work-log projections (list + check-in/out responses) include `clientUuid`.
- **A-B2**: check-out keyed by the work-log's `clientUuid` (body `{workLogClientUuid, quantity?, notes?}`), **idempotent** — replay on an already-CHECKED_OUT log returns that row (200), never 404/409. Check-in idempotency already shipped (M3 B1).
- **A-B4**: gate + curl walk (offline-sequence replay: check-in then check-out by same clientUuid, replay both → single row, CHECKED_OUT).

### iOS
- **A-I1**: `SyncOutbox.createdAt: Date` (FIFO ordinal); contract refresh + regen.
- **A-I2**: `OutboxWorker` (@MainActor @Observable): `drain()` pulls pending/retryable items oldest-first, dispatches by `endpoint` to the typed gateway, 2xx → `done` + store reconcile, 4xx-conflict → `conflict`, network/5xx → `attempts++` + `lastError`, stop-on-offline (no hammering). Bounded attempts → `conflict` (surface, never silently drop).
- **A-I3**: refactor `WorkLogActions` — check-in/out now (a) optimistic store write (local `id` = clientUuid, status set locally), (b) enqueue outbox item; return immediately (works offline). Gateway moves behind the worker.
- **A-I4**: `syncWorkLogs` dedups by `clientUuid` (reconcile a local clientUuid-row to the server row in place; don't double-insert). Requires A-B1.
- **A-I5**: `Connectivity` (NWPathMonitor) + triggers: drain on foreground, on network-regained, after each enqueue.
- **A-I6**: Settings sync section shows pending-outbox count + conflict count + per-item retry.
- **A-I7**: full gate + **airplane-mode smoke**: toggle offline, check-in + check-out, reconnect, assert exactly one server WorkLog, CHECKED_OUT, no dupes (idempotency proven).

## M4b — Photos (append-only)

### Backend
- `POST /api/v1/uploads` (device-session, multipart) reusing `uploadService.uploadStream()`; polymorphic association (`entityType`/`entityId`) to a job/surface; append resulting URL to `Surface.photoUrls` when the holder is a surface. OpenAPI + tests same commit.

### iOS
- Camera capture (PhotosPicker + camera source) on JobDetail/Surface; persist bytes to app-support; enqueue outbox photo item (endpoint=`uploads`, payload = metadata + local file ref). Worker uploads multipart; append-only (never edits/deletes). Photo thumbnails read from the store.
- DoD: photo captured offline uploads on reconnect; visible in web.

## M4c — Background refresh + biometric

- `BGAppRefreshTask` registered; on wake drains outbox + `syncAll()`.
- Biometric gate (LocalAuthentication): Face ID/Touch ID over a persisted session on cold launch; opt-out falls back to the session as-is (non-blocking if unavailable). iPhone-only (iPad deferred to M7 per PRD).
- DoD: backgrounded app refreshes on schedule; biometric prompt gates a restored session.

## Non-goals (M4)

Per-field LWW survey merge (M5), status advance on jobs/surfaces beyond check-in/out, offline survey capture (M5, own brief), push (M6).

## Sequencing

A first (keystone; b/c depend on the worker). Within A: backend (A-B*) → snapshot regen → iOS (A-I*) parallel where files disjoint → airplane smoke. Then B, then C. Each slice lands with its own DoD; branches stay local (no push without go-ahead).
