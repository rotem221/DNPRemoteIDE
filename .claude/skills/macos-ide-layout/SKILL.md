---
name: macos-ide-layout
description: Use when authoring or reviewing Mac SwiftUI views in apps/DNPRemoteMac — IDE shell, three-pane workspace, sidebar, terminal pane, event feed pane, settings, pairing, diagnostics. Triggers on any change to files under apps/DNPRemoteMac/DNPRemoteMac/UI or App/.
---

## When to use

The DNP Remote Mac app is a professional dark IDE — Cursor-grade hierarchy, dense without being cluttered. Use this skill whenever you touch its SwiftUI shell or the panes inside it.

## Hard rules

- Top-level shell is `NavigationSplitView` (sidebar + detail). Don't rebuild split-pane logic with `HStack` at the root.
- Three-pane workspace: `WorkspaceView` = `[TerminalPaneView | SessionFeedPaneView]` with a fixed `Divider`. Feed pane width is ~ 380 pt.
- All colors come from `MacTheme` (`apps/DNPRemoteMac/DNPRemoteMac/UI/Theme.swift`).
- Use `MacTheme.mono` for terminal, command echoes, IDs, fingerprints.
- Settings scene is a separate `Settings { … }` scene. Don't reinvent it as an in-window page.
- The Mac event feed is a *superset* of the iOS feed (it can show developer-detail events). It still uses `SessionEvent` — don't introduce alternate types.

## How to apply

### Shell

```swift
NavigationSplitView {
    MacSidebarView(selection: $sidebarSelection)
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
} detail: {
    switch sidebarSelection ?? .sessions {
    case .sessions: WorkspaceView()
    case .pairing:  PairingCenterView()
    case .settings: MacSettingsView()
    case .diagnostics: DiagnosticsView()
    }
}
```

### Workspace toolbar tokens

```swift
HStack(spacing: 12) {
    Text(session.title).font(.headline)
    StatusPill(status: session.status)
    if let snap = vm.contextSnapshots[session.id] { ContextChip(snapshot: snap) }
    Spacer()
    ConnectionPill(status: vm.bridgeStatus)
}
```

### Terminal pane composer

A thin bar at the bottom of `TerminalPaneView`:

```swift
HStack(spacing: 8) {
    Image(systemName: "chevron.right").foregroundStyle(MacTheme.accent)
    TextField("Type a command…", text: $draft)
        .textFieldStyle(.plain)
        .font(MacTheme.mono)
        .foregroundStyle(MacTheme.textPrimary)
}
.padding(.horizontal, 14).padding(.vertical, 10)
.background(MacTheme.surface)
```

### Sidebar rows

Use `SessionRowMac` — a small status dot, title, project name, optional pending-approval badge. Highlight selected row with `MacTheme.surfaceAlt` background, not by tint.

## Examples

**Good** — Refined toolbar with semantic pills and a divider:

```swift
WorkspaceToolbar()
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(MacTheme.surface)
    .overlay(Divider(), alignment: .bottom)
```

**Bad** — Loud colors fighting the IDE feel:

```swift
.background(Color.blue)        // ❌ accent only on small surfaces (pills, primary buttons)
.font(.title.bold())           // ❌ way too big in a workspace toolbar
```

## Pitfalls

- macOS `Form` defaults look bright; tab content in `MacSettingsView` should explicitly set `.background(MacTheme.background)`.
- `List` selection on macOS uses the system tint; for sidebar rows we override with our own row background to keep the IDE feel.
- Don't put `MainActor`-marked async work directly in a view body. Wrap in `Task { … }` or call into the view model.
- Don't add macOS toolbar items that duplicate sidebar entries — pick one.
