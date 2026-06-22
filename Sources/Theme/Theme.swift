// Theme.swift — Airlive Bridge dark theme.
//
// Adapted from AirliveStudioApp/Sources/StudioDesign.swift (the frozen Studio
// app), then re-keyed for Bridge's brief:
//
//   • Dark-but-not-black surfaces.  Bridge runs alongside the operator's NLE /
//     OBS / browser, so the canvas is a warm neutral charcoal (#0E0F12) rather
//     than Studio's near-OLED #0A0A0A — three visible tiers (app / panel / rail)
//     give the three-zone layout (Channels | Selected | Outputs) clear depth.
//
//   • Three accents, not one.  Studio is monochrome-plus-one-blue; Bridge keeps
//     the camera app's element palette — blue / red / yellow — so connection,
//     live, and warning states each read distinctly:
//       - accentBlue   selection / active primary action
//       - accentRed    live / program / record (broadcast red)
//       - accentYellow staged / preview / caution
//
// Discipline carried over from Studio: FLAT surfaces (no gradients), 1 pt
// low-contrast strokes, depth from brightness steps + borders only.

import SwiftUI

// MARK: - Color tokens

/// Bridge's dark theme.  All values are true-neutral greys (R = G = B) except
/// the three accents, so the accents are the only chromatic elements and read
/// as accents instead of dissolving into a tinted chrome.
enum Theme {

    // ── Surfaces (three visible tiers for the three-zone layout) ──────────
    /// `#0E0F12` — app canvas.  Warm neutral charcoal, dark but not OLED-black
    /// so Bridge sits comfortably beside other pro tools without a harsh void.
    static let bgApp        = Color(hex: 0x0E0F12)
    /// `#15171C` — panel cards (the selected-channel zone, popovers, settings).
    /// +brightness over the canvas so panels read as floating surfaces.
    static let bgPanel      = Color(hex: 0x15171C)
    /// `#101216` — side rails (Channels list, Outputs list).  Sits just above
    /// the canvas, just below the panel — a quiet recessed bar framing the work.
    static let bgRail       = Color(hex: 0x101216)
    /// `#1B1E24` — row / control hover.
    static let bgHover      = Color(hex: 0x1B1E24)
    /// `#222630` — selected row fill (neutral; the strong selection signal is
    /// `accentBlue` on the selected control, not the row fill).
    static let bgSelected   = Color(hex: 0x222630)

    // ── Strokes (low-contrast 1 pt borders) ───────────────────────────────
    /// `#262A33` — 1 pt panel / tile / rail stroke.
    static let stroke       = Color(hex: 0x262A33)
    /// `#30343E` — slightly stronger inset divider.
    static let strokeDivider = Color(hex: 0x30343E)

    // ── Text ──────────────────────────────────────────────────────────────
    static let textPrimary   = Color(hex: 0xEAEAEA)
    static let textSecondary = Color(hex: 0xA8AAB0)
    static let textFaint     = Color(hex: 0x70747C)

    // ── Accents (the camera app's element colours) ─────────────────────────
    /// `#3B82F6` — selection / active primary action (Tailwind blue-500, same
    /// as Studio's selection accent so the two apps feel related).
    static let accentBlue   = Color(hex: 0x3B82F6)
    /// `#D14545` — live / program / record.  Broadcast red, matched to
    /// Studio's Program tally so a CAM shows the same red on both screens.
    static let accentRed    = Color(hex: 0xD14545)
    /// `#E2B33C` — staged / preview / caution.  Warm broadcast amber.
    static let accentYellow = Color(hex: 0xE2B33C)
}

// MARK: - Spacing & radius constants

/// Layout spacing scale (pt).  Named steps so padding is intentional rhythm,
/// not a scatter of magic numbers.
enum Spacing {
    static let xs: CGFloat  = 4
    static let sm: CGFloat  = 8
    static let md: CGFloat  = 12
    static let lg: CGFloat  = 16
    static let xl: CGFloat  = 24
}

/// Corner-radius scale (pt) — panels soft-card, buttons soft-pill, matching
/// the Studio / Linear / Raycast scale.
enum Radius {
    static let button: CGFloat = 8
    static let panel: CGFloat  = 12
}

// MARK: - Hex initialiser

extension Color {
    /// Convenience initialiser for solid hex colours (0xRRGGBB).
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
