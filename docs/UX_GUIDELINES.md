# UX Guidelines — DNP Remote Suite

## Visual direction

| App | Direction | Source of inspiration |
|---|---|---|
| DNP Remote Mac | Professional dark IDE. Three panes. Refined toolbars. Density over decoration. | Cursor, Anti-Gravity-style developer tools, Xcode. |
| DNP Remote iOS | Dark-first **Liquid Glass**. Translucent cards over a layered gradient backdrop. Premium typography. Smooth motion. | Apple's iOS visualEffect/material guidance + the warm-light reference at `DNP Remote/DNPRemoteClient/Views/Design/LiquidGlassModifiers.swift`, retuned for dark. |

Both apps default to dark mode and degrade gracefully on older OSes (`.ultraThinMaterial` falls back to a translucent `Color.black.opacity(0.4)` if needed).

## Mac — palette & primitives

`apps/DNPRemoteMac/DNPRemoteMac/UI/Theme.swift`:

| Token | Value | Use |
|---|---|---|
| `MacTheme.background` | `#15181A` | Window background, terminal pane. |
| `MacTheme.surface` | `#1F2226` | Toolbars, sidebar, settings forms. |
| `MacTheme.surfaceAlt` | `#292D33` | Selected sidebar row, hovered row. |
| `MacTheme.border` | white-08 | All thin separators (`.strokeBorder` 0.5–1px). |
| `MacTheme.accent` | `#80C7FF` | Primary buttons, active session dot. |
| `MacTheme.warning` / `danger` / `success` | warm-orange / red / green | Pills, severity icons. |
| `MacTheme.mono` | `.system(.body, design: .monospaced)` | Terminal, command echo, IDs. |

Hierarchy:
- Sidebar uses `List(.sidebar)` with section headers.
- Workspace is `HStack` of `TerminalPaneView` + `Divider` + `SessionFeedPaneView`.
- Composer at the bottom is **not** modal — a thin bar, monospaced.

Toolbar tokens: status pill, context chip (matches iOS context ring color logic), connection pill. Three-tier disclosure: top-line title + subtitle + at-a-glance pills.

## iOS — palette & primitives

`apps/DNPRemoteiOS/DNPRemoteiOS/UI/LiquidGlass.swift`:

| Token | Value | Use |
|---|---|---|
| `LG.background` | dark navy `#0F121A` | Session detail backdrop. The shell view layers a soft 3-stop gradient on top. |
| `LG.surfaceElevated` | white-06 | Default tint above `.ultraThinMaterial`. |
| `LG.stroke` | white-10 | All glass card borders (0.6 px). |
| `LG.accent` | `#9ED7FF` | Primary buttons, info pills. |
| `LG.warning`, `LG.danger`, `LG.success` | amber, coral, mint | Risk-tinted glass and severity icons. |
| `LG.textPrimary/Secondary/Tertiary` | white opacities 95/70/45 | Three-tier hierarchy. |

Components:

| Component | Behavior |
|---|---|
| `GlassCard` | `.ultraThinMaterial` + tone tint + 0.6 px stroke + soft shadow. Tones: `.neutral`, `.accent`, `.warning`, `.danger`, `.success`. |
| `GlassPrimaryButtonStyle` | Capsule with `.ultraThinMaterial` + tint overlay. Press = `scale(0.985)`. |
| `GlassSecondaryButtonStyle` | Capsule, no tint. |
| `GlassStatusPill` | Icon + text in a capsule with material backing. |
| `GlassContextRing` | 42×42 ring with animated trim and percent label. |

Motion: `.snappy(0.18)` for press, `.easeInOut(0.4)` for context ring, `.easeOut` for feed scroll. No bouncy spring on critical content (approvals, errors).

## Information density rules

| Rule | Why |
|---|---|
| Each `SessionEvent` renders to **one** card type. | Avoid render forks the user has to learn. |
| Risk level is communicated by **two** signals (color + uppercase badge). | Color-blind users + glance reading. |
| Confidence (measured / estimated) is *always* visible on context UI. | Don't pretend we know what we don't. |
| Approvals dominate the layout when present. | Safety first — the carousel sits above everything else. |
| Raw fallback (`UnknownCard`) is compact and grey. | Unknown is not noise; it's a hint to update the parser. |

## Empty / loading / error states

| State | Mac | iOS |
|---|---|---|
| No sessions | "No session" + Start button | Glass card with icon + "Start one from your Mac, or create one here." |
| Disconnected | Yellow toolbar pill | Header pill switches to amber; banner suggests retry. |
| Bridge error | Red pill + diagnostics link | Banner + Diagnostics tab badge. |
| Pending approval timed out | Audit entry; `.warning` event | `ApprovalCard` slides off; warning card persists. |

## Accessibility

- Everything respects Dynamic Type up to `.accessibility3`.
- VoiceOver labels: `ContextStatusHeader` reads `Context 73 percent remaining, healthy`. Approval cards announce risk and target.
- Reduce Motion: ring animation falls back to a non-animated arc; carousel auto-advance disabled.
- Hit targets ≥ 44×44 pt on iOS; key actions are also keyboard-accessible on Mac.

## Don'ts

- ❌ Don't show raw ANSI escape sequences anywhere on iOS.
- ❌ Don't render hidden chain-of-thought as Thinking. Only safe summaries that describe observable state.
- ❌ Don't auto-decide approvals from iOS heuristics. The user is always in the loop.
- ❌ Don't hide the connection status. A subtle `Live` / `Offline` pill is always present.
- ❌ Don't use red for low-context warnings — reserve red for `critical` / errors / explicit destructive intent.
