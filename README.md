# SightLine Field

SwiftUI iOS app skeleton for the SightLine field/installer app. See `PLAN.md`
for the milestone outline and `docs/superpowers/specs/2026-08-04-m2-ios-skeleton-design.md`
for the full design.

## Setup

1. Install XcodeGen:
   - `brew install xcodegen`, or
   - download a release binary from https://github.com/yonaskolb/XcodeGen/releases
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
