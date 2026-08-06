import SwiftUI

/// Design tokens transcribed from the web app's design lock.
///
/// Sources (see `.superpowers/sdd/task-7-report.md` for full provenance):
/// - `DESIGN.md` (Sightline New production/SightLine/.worktrees/staging-merge) — OKLCH color
///   tokens (lines 4-18) and typography scale (lines 19-44).
/// - `.impeccable/design.json` — component `css` blocks carry sRGB hex fallbacks for the same
///   OKLCH custom properties (e.g. `var(--primary, #0e7490)`), used here as the authoritative
///   hex transcription since DESIGN.md itself is OKLCH-only except for the one inline accent
///   alias. Where neither file gives a hex fallback (the three status colors), the hex was
///   computed from the cited OKLCH triple via the standard OKLCH→linear-sRGB conversion
///   (Björn Ottosson's matrices) — flagged individually below.
enum DS {
    enum Color {
        /// Glass Teal. DESIGN.md line 94 states the hex family alias directly: "the accent's
        /// hex family alias is `#0E7490`" — also `var(--primary, #0e7490)` in design.json:190.
        static let accent = SwiftUI.Color(hex: 0x0E7490)

        /// North-Light Grey (canvas). DESIGN.md:8 `north-light-bg: oklch(0.985 0.002 230)`;
        /// hex fallback from design.json:222 `var(--background, #fafbfc)`.
        static let background = SwiftUI.Color(hex: 0xFAFBFC)

        /// Ink. DESIGN.md:10 `ink: oklch(0.21 0.015 230)`; hex fallback from design.json:190
        /// `var(--foreground, #24292e)`.
        static let textPrimary = SwiftUI.Color(hex: 0x24292E)

        /// Ink Muted. DESIGN.md:11 `ink-muted: oklch(0.47 0.015 230)`; hex fallback from
        /// design.json:198 `var(--muted-foreground, #5c666e)`.
        static let textSecondary = SwiftUI.Color(hex: 0x5C666E)

        /// Destructive-action tint, codified from the settings logout review nit.
        static let destructive = SwiftUI.Color.red

        /// Chip fill for a `Surface.status` value. The web app models "normal" states as one
        /// grey chip and reserves color for severity (DESIGN.md's Severity-Only Rule); it has
        /// no chip vocabulary for a multi-stage fabrication pipeline (MEASURED/CUT/FILM_CUT/
        /// INSTALLED), so those four are a derived progression through the existing Glass Teal
        /// tonal ramp (design.json:12-19, hex stops verbatim) rather than an invented palette.
        /// PENDING reuses the web's literal muted-chip grey. COMPLETED/NEEDS_REVIEW/
        /// UNDER_REVIEW map onto the web's existing success/warning/warning-strong semantics
        /// (direct web counterparts); those three have no hex token anywhere in either source
        /// file, so the hex was computed from the cited OKLCH triple (see file header).
        static func surfaceStatus(_ status: String) -> SwiftUI.Color {
            switch status {
            case "PENDING":
                // design.json:214 `var(--muted, #eef0f2)` — DESIGN.md:12 `mist`.
                SwiftUI.Color(hex: 0xEEF0F2)
            case "MEASURED":
                // design.json:13 glass-teal tonalRamp[1] ("800").
                SwiftUI.Color(hex: 0x164E63)
            case "CUT":
                // design.json:16 glass-teal tonalRamp[4] ("500").
                SwiftUI.Color(hex: 0x0891B2)
            case "FILM_CUT":
                // design.json:17 glass-teal tonalRamp[5] ("400").
                SwiftUI.Color(hex: 0x06B6D4)
            case "INSTALLED":
                // design.json:18 glass-teal tonalRamp[6] ("300").
                SwiftUI.Color(hex: 0x67E8F9)
            case "COMPLETED":
                // Derived from DESIGN.md:15 `success-emerald: oklch(0.46 0.125 163)`.
                SwiftUI.Color(hex: 0x006C43)
            case "NEEDS_REVIEW":
                // Derived from DESIGN.md:16 `warning-amber: oklch(0.769 0.188 70.1)`.
                SwiftUI.Color(hex: 0xFE9A00)
            case "UNDER_REVIEW":
                // Derived from DESIGN.md:17 `warning-strong: oklch(0.52 0.128 65)`.
                SwiftUI.Color(hex: 0x9A5600)
            default:
                SwiftUI.Color(hex: 0xEEF0F2)
            }
        }
    }

    enum Font {
        /// DESIGN.md:30-34 `title`: 18px / weight 600. Font family per DESIGN.md is
        /// "IBM Plex Sans"; not bundled in this target, so `.custom` falls back to the system
        /// font until a Plex Sans font file + `UIAppFonts` entry are added.
        static let title = SwiftUI.Font.custom("IBM Plex Sans", size: 18).weight(.semibold)

        /// DESIGN.md:35-39 `body`: 16px / weight 400.
        static let body = SwiftUI.Font.custom("IBM Plex Sans", size: 16).weight(.regular)

        /// DESIGN.md:40-44 `label`: 12px / weight 500 — closest DESIGN.md scale rung to
        /// SwiftUI's "caption" role (DESIGN.md has no literal "caption" token).
        static let caption = SwiftUI.Font.custom("IBM Plex Sans", size: 12).weight(.medium)
    }

    /// HIG minimum tappable-control size (44×44pt, `reference/ios.md`'s "Touch targets"
    /// floor). Additive M5c token — reused by every icon-only per-row action on the survey
    /// screens (`JobElevationsView`'s "Capture Pane", `JobDetailView`'s per-surface "Assign
    /// to Elevation"/"Add Photo") so a small SF Symbol glyph never renders a smaller hit
    /// target than HIG requires, regardless of the glyph's own intrinsic size.
    enum Layout {
        static let minTouchTarget: CGFloat = 44
    }
}

private extension SwiftUI.Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
