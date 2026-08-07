# M4 Uploads Scout — offline outbox + photo upload backend

Repo scouted: `SightLine/.worktrees/field-app` (web monorepo).

## 1. How uploads work TODAY

- **Route**: `POST /api/uploads` (`src/app/api/uploads/route.ts`). Also a near-identical
  sibling pattern at `POST /api/proposals/[id]/files` and `POST /api/takeoff/sheets`
  (same streaming convention, different holder).
- **Auth**: session-cookie ONLY. Handler wraps in `withPermission('jobs.manage', ...)`
  → `withSessionTenant` → `tenantContextFromSession()` (NextAuth session cookie).
  No API-token (`slk_`) or device-session (`slma_`) path exists on this route today.
  Missing/expired session → thrown `Error` matched by `/sign in required/i` → 401.
- **Request shape**: `multipart/form-data`, NOT JSON/base64. Fields:
  - `file` (required, non-empty `File`)
  - `entityType` — one of `BUSINESS | CUSTOMER | JOB | MEASUREMENT | QUOTE | SURFACE` (default `BUSINESS`)
  - `entityId` — holder record id (required for record holder types)
  - `tags` — optional comma-separated labels
  Route rejects non-multipart bodies with 415.
- **Where bytes land**: the `file` field's `ReadableStream` (`file.stream()`) is piped
  straight through `uploadService.uploadStream()` → `getStorage().putStream()` — O(chunk)
  memory, never buffered. `getStorage()` (`src/lib/storage/index.ts`) picks `S3Storage`
  when all four `S3_*` env vars are set, else `LocalStorage` (writes under
  `public/uploads/`, dev/local-only path). Same storage port is reused by
  `/api/proposals/[id]/files` and `/api/takeoff/sheets`.
- **Response**: `200 { url, uploadId, filename }`. Errors: `{ error: string }` with
  401 (no session) / 403 (`PermissionDeniedError`) / 413 (`StorageLimitError`) /
  415 (wrong content-type) / 422 (`UploadError` — bad MIME/holder/cap) / 400 (malformed) / 500.

## 2. Presigned-URL flow?

**No.** Repo-wide grep for `presign|getSignedUrl|createPresignedPost|PutObjectCommand`
returns zero matches anywhere in `src/` or `prisma/`. There is no presign-request →
presign-response → direct-to-bucket → commit/notify handshake in this codebase at all.
Every upload path (generic uploads, proposal files, takeoff sheets, esign PDF landing)
is server-mediated: bytes always transit the Next.js server via `Storage.put`/`putStream`,
whether the backend is `LocalStorage` or `S3Storage`. `S3Storage.putStream` does a
plain authenticated `PUT` from the server using the configured IAM creds — the client
never touches S3 directly.

## 3. Upload model

`model Upload` (`prisma/schema.prisma` ~line 2879):

```
id           String    @id @default(cuid())
businessId   String
entityType   String?   // customer | job | measurement | business
entityId     String?
url          String
filename     String
mimeType     String?
sizeBytes    Int?
tags         String[]
archivedAt   DateTime?
uploadedById String?
createdAt    DateTime  @default(now())
@@index([businessId, entityType, entityId])
@@index([businessId, archivedAt])
```

- **Association is polymorphic**, not a real FK: `entityType` + `entityId` string pair
  (`BUSINESS | CUSTOMER | JOB | MEASUREMENT | QUOTE | SURFACE` per the service's
  `UploadHolderType`), existence-checked per-tenant in `requireHolder()` (queries
  `Customer`/`Job`/`Quote`/`Surface` by id — `MEASUREMENT` and `SURFACE` both resolve
  against the `Surface` table). Same pattern used elsewhere (`Taggable`, `Note`,
  `PlanAnnotation`) — this is the house convention for "attach a file/tag/note to
  any of several record types."
- **Separately**, `Surface.photoUrls String[]` and `WorkLog`'s neighbor models
  (`GlassReading.mediaUrl`, and a `photoUrls String[] @default([])` on the
  ~line-1104 and ~line-1177 models — inspection/appointment-adjacent records) already
  carry photo URL arrays directly as denormalized string columns, separate from the
  `Upload` table. `WorkLog` itself (line 2595) has **no** photo/attachment field of
  its own today — only `Surface.photoUrls` and the two other models do. So there are
  two existing photo patterns in the schema: (a) generic `Upload` rows keyed by
  polymorphic holder, and (b) a raw `photoUrls: String[]` column directly on some
  domain models (Surface being the relevant one for field-app work).

## 4. VERDICT

**House convention = API-passthrough (server-mediated multipart streaming), NOT
presigned-direct-to-storage.** No presigned flow exists anywhere in this codebase to
extend; every existing upload surface (`/api/uploads`, `/api/proposals/[id]/files`,
`/api/takeoff/sheets`) streams bytes through the Next.js server into the `Storage`
port. M4's iOS photo pipeline should mirror this exactly: multipart POST from the
device straight to a new v1 route, streamed server-side into `uploadService.uploadStream`
(or a thin wrapper), never a client-side PUT to S3.

**What M4 backend must add** (nothing exists yet under `/api/v1` for media):
- A new route, e.g. `POST /api/v1/uploads` (or scoped as
  `POST /api/v1/jobs/{id}/surfaces/{surfaceId}/photos` if you want it pane-scoped
  rather than generic-holder), built on **`withDeviceSession`** (`src/app/api/v1/_lib/auth.ts`)
  — the device-session combinator already used by device-auth routes — not
  `withApiToken`/`withEitherAuth`, since this is device-only, and not the
  session-cookie `withPermission` the non-v1 route uses today.
  - Body: `multipart/form-data`, same `file`/`entityType`/`entityId`/`tags` shape,
    validated against `UPLOAD_HOLDER_TYPES`.
  - Handler calls the same `uploadService.uploadStream()` used by `/api/uploads` —
    reuse the module wholesale, don't reimplement holder/cap/MIME validation.
  - Response: v1's standard `{ data: { url, uploadId, filename } }` envelope
    (via `withDeviceSession`'s wrapping), not the bare `{ url, uploadId, filename }`
    the legacy route returns.
- If photos should also land on `Surface.photoUrls` directly (matching the existing
  denormalized-array pattern other inspection-like models use), the route/service
  needs an explicit append step after `uploadService.uploadStream` succeeds — that
  join does not happen automatically today; `Upload` rows and `Surface.photoUrls`
  are two independent stores with no code path linking them currently.

**Flag for device-session auth**: today `/api/uploads` is **unreachable** from a
device-session (`slma_`) bearer token — it only accepts the NextAuth session cookie
via `withPermission`. There is no existing v1 media endpoint at all (confirmed:
`src/app/api/v1` has no uploads/media/photos/attachments route — only
`work-logs`, `jobs`, `appointments`, `device-auth`, etc.). M4 must build the v1 route
from scratch; it cannot reuse the legacy route's auth path as-is for the mobile client.
