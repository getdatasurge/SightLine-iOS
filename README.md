# SightLine Field

SwiftUI iOS app skeleton for the SightLine field/installer app. See `PLAN.md`
for the milestone outline and `docs/superpowers/specs/2026-08-04-m2-ios-skeleton-design.md`
for the full design.

## Setup

1. Install XcodeGen:
   - **Xcode 15.x users: use XcodeGen ≤ 2.42.0** — 2.43+ emits an Xcode 16 project
     format (`objectVersion = 77`) that Xcode 15 refuses to open
     ("future Xcode project file format"). Grab 2.42.0 from
     https://github.com/yonaskolb/XcodeGen/releases/download/2.42.0/xcodegen.zip
   - Xcode 16+: `brew install xcodegen` (any version works)
2. Generate the Xcode project:
   ```
   xcodegen generate
   ```
3. Open `SightLineField.xcodeproj` in Xcode.
4. Select an iPhone simulator as the run destination.
5. Run (⌘R).

`SightLineField.xcodeproj` is gitignored — regenerate it with `xcodegen generate`
any time `project.yml` changes.

## Dev server pairing

The app talks to the M1 auth backend. Run the backend from the
`integration/field-app` branch of the SightLine web repo:

```
PORT=3005 npm run dev
```

In Debug builds the app defaults its API base URL to `http://localhost:3005`.
Override it with the `-apiBaseURL <url>` launch argument (Xcode scheme
"Arguments Passed On Launch", or `xcodebuild test`/`run` launch args) to point
at a different host.

## M2: read-only sync

`SyncEngine` pulls jobs, appointments, work-types, work-logs, and surfaces,
each with its own delta watermark (`updatedAt`-based; first run or invalid
watermark falls back to a full paged pull). Pull-to-refresh on Schedule
re-runs `syncAll()`. Identity (`technicianId`, capabilities) comes from
`GET /technicians/me` at login/bootstrap. Sign-out wipes the local
SwiftData cache.
