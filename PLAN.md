# PLAN

Current status: skeleton. See the full design at
`docs/superpowers/specs/2026-08-04-m2-ios-skeleton-design.md`.

## Milestone outline

- **M2** — read-only app: backend technician-scoped reads (web repo) + these shells filled in: schedule, job detail, surfaces, delta refresh. DoD: seeded technician signs in, sees today's jobs offline-after-first-sync, no prices without `pricing.view`.
- **M3** — check-in/out writes, online-only; photos; status advance.
- **M4** — offline outbox + sync worker, conflict UX, clock-skew flagging.
- **M5** — offline survey capture port (deferred, own brief).
