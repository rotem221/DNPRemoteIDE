---
name: settings-and-diagnostics
description: Use when modifying Settings panes (Mac or iOS), Diagnostics views, scripts/doctor.sh, or user-readable error mapping. Triggers on changes to MacSettingsView, IOSSettingsView, DiagnosticsView, IOSDiagnosticsView, or scripts/doctor.sh.
---

## When to use

Anytime you expose a new setting, new diagnostic field, or a new error string that the user might see in the UI or in `doctor.sh`.

## Hard rules

- Settings keys persist in `UserDefaults.standard` on iOS; on Mac use `@AppStorage` for view-bound flags or write to Application Support for richer config.
- Don't surface internal IDs or stack traces directly to the user. Map them to actionable messages.
- Every diagnostic line in `doctor.sh` is binary: ✅ or ❌. Add a path or fix hint if ❌.
- Settings panes are split by domain: Claude / Bridge / Context / Feed (Mac); Connection / Pairing / Feed / About (iOS). Don't grow them open-ended.
- Diagnostics is read-only. Don't put toggles there — they belong in Settings.

## How to apply

### Mac settings tab

```swift
struct ContextSettingsTab: View {
    @AppStorage("dnp.lowContextThreshold") private var threshold = 0.25
    var body: some View {
        Form {
            Slider(value: $threshold, in: 0.05...0.50, step: 0.05) { Text("Low-context threshold") }
            Text("Warn iOS when context drops below \(Int(threshold * 100))%.")
                .font(.caption).foregroundStyle(MacTheme.textTertiary)
        }.padding()
    }
}
```

### iOS settings section

```swift
SettingsSection(title: "Connection") {
    row("Bridge", value: vm.connectionStatus.rawValue)
    if let mac = vm.pairedMac {
        row("Mac name", value: mac.macName)
        row("Endpoint", value: mac.endpoint, mono: true)
    }
}
```

### `doctor.sh` line

```bash
status() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf "  ✅ %s\n" "$name"
  else
    printf "  ❌ %s\n" "$name"
  fi
}
status "claude (Claude Code)" command -v claude
status "Mac Xcode project generated" test -d apps/DNPRemoteMac/DNPRemoteMac.xcodeproj
```

### User-readable error mapping

```swift
func userMessage(for code: BridgeErrorCode) -> String {
    switch code {
    case .invalidSignature:    return "Couldn't verify a message from your Mac. Try re-pairing."
    case .staleTimestamp:      return "Your Mac and iPhone clocks are out of sync."
    case .replayedNonce:       return "Connection got noisy — reconnecting…"
    case .unknownDevice:       return "This iPhone isn't paired with that Mac yet."
    case .revokedDevice:       return "This iPhone was revoked. Re-pair to continue."
    default:                   return "Something went wrong. See Diagnostics."
    }
}
```

## Examples

**Good** — actionable diagnostic:

```
❌ claude (Claude Code) — install per https://code.claude.com/docs/en/overview
```

**Bad** — opaque internal state:

```
❌ ENOENT
```

## Pitfalls

- Sticking too many toggles in Settings. Each toggle is a maintenance commitment — only ship the ones that matter.
- Writing to `UserDefaults` on the main thread for big values (don't store events there). Use Application Support for anything > 1 KB.
- Forgetting that `doctor.sh` exits with the failure count — CI uses it. Keep success path returning 0.
- Diagnostics that lie. Always reflect actual runtime state, not last-known.
