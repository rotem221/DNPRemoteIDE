import SwiftUI
import AppKit

/// Mac IDE palette — Apple-aligned. Backgrounds, separators, and labels use the system
/// dynamic colors so dark/light mode + Increase Contrast track the user's preference, and
/// the panels feel like native macOS chrome (Finder, Notes, Mail) instead of a custom theme.
/// Brand semantics (accent / warning / danger / success) use the system tint roles for the
/// same reason — they automatically darken in light mode and brighten in dark mode.
enum MacTheme {
    // MARK: - Backgrounds (system dynamic)
    /// Window-level background. Tracks NSColor.windowBackgroundColor — slightly lighter than
    /// the content surface, exactly like every native Mac app.
    static var background: Color { Color(nsColor: .windowBackgroundColor) }
    /// Pages like Settings / Diagnostics / GitHub use the grouped-content tone — a touch
    /// darker than the window background in dark mode, slightly darker gray in light mode —
    /// so cards visually pop off the page in the way Apple's own Settings.app does.
    static var groupedBackground: Color { Color(nsColor: .underPageBackgroundColor) }
    /// Primary content surface (panels, editor body). NSColor.textBackgroundColor is the
    /// canonical "where text goes" color in AppKit.
    static var surface:    Color { Color(nsColor: .textBackgroundColor) }
    /// Slightly elevated content (selected rows, highlight pills, settings cards on the
    /// grouped page background).
    static var surfaceAlt: Color { Color(nsColor: .underPageBackgroundColor) }
    /// Card surface — used for the rounded blocks on Settings / Diagnostics / GitHub pages.
    /// Reads as a soft white block in light mode and a softly elevated gray in dark mode,
    /// matching System Settings.app exactly.
    static var card:       Color { Color(nsColor: .controlBackgroundColor) }

    // MARK: - Separators
    /// 0.5pt hairlines — same NSColor the system uses for `NSBox.separator` etc.
    static var border:     Color { Color(nsColor: .separatorColor) }

    // MARK: - Brand semantics
    /// Brand accent — the DNP purple. Sampled from the brand's status-dot
    /// artwork (`#7D37EB`, RGB 125/55/235) for the LIGHT-mode variant,
    /// then lightened to `#A776FF` (RGB 167/118/255) for DARK mode so the
    /// fill reads cleanly against a near-black background instead of
    /// almost disappearing into it. Implemented via a dynamic NSColor
    /// closure so SwiftUI redraws every accent surface (sidebar
    /// selection, folder glyphs, buttons, focus rings, drop indicators,
    /// the AI-usage chip, repo pill, etc.) the moment the system
    /// appearance changes.
    static var accent: Color {
        Color(nsColor: NSColor(name: "DNPAccent") { appearance in
            let darkVariants: [NSAppearance.Name] = [
                .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]
            let isDark = darkVariants.contains(where: { appearance.bestMatch(from: [$0]) == $0 })
            if isDark {
                // Brighter in dark mode for legibility on near-black surfaces.
                return NSColor(srgbRed: 167.0 / 255.0,
                               green: 118.0 / 255.0,
                               blue: 255.0 / 255.0,
                               alpha: 1.0)
            } else {
                // Original brand purple for light mode.
                return NSColor(srgbRed: 125.0 / 255.0,
                               green: 55.0 / 255.0,
                               blue: 235.0 / 255.0,
                               alpha: 1.0)
            }
        })
    }
    static var warning:    Color { Color(nsColor: .systemOrange) }
    static var danger:     Color { Color(nsColor: .systemRed) }
    static var success:    Color { Color(nsColor: .systemGreen) }

    // MARK: - Labels (system dynamic)
    static var textPrimary:   Color { Color(nsColor: .labelColor) }
    static var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    static var textTertiary:  Color { Color(nsColor: .tertiaryLabelColor) }

    static let mono = Font.system(.body, design: .monospaced)
}
