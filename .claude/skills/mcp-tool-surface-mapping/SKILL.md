---
name: mcp-tool-surface-mapping
description: Use when surfacing MCP server tool calls in the iOS feed and Mac event pane. Triggers on changes to event normalizer detection of `mcp__<server>__<tool>` tool names, or to ToolActivityPayload rendering.
---

## When to use

When you see a tool call whose `tool_name` starts with `mcp__` — this is an MCP server tool. We don't run MCP ourselves; we observe and render.

## Hard rules

- Render every MCP call as a `ToolActivityCard` with `provider == .mcp`.
- Don't assume any particular MCP server's schema. Treat `tool_input` and `tool_response` as opaque JSON; surface a digest preview only.
- Don't auto-elevate MCP calls to approvals — Claude's permission system already gates them. Our approval flow only fires if Claude itself emitted a `PermissionRequest` for the tool.
- iOS shows the tool name (e.g., `mcp__memory__create_entities`) and a one-line input preview, not full JSON. Full JSON is available in Mac developer mode.
- When an MCP call fails (`PostToolUseFailure` or `tool_response.is_error`), emit a paired `.warning` event next to the `.toolActivity` so the user sees something went wrong.

## How to apply

### Detection

```swift
func isMCPTool(_ name: String) -> Bool { name.hasPrefix("mcp__") }

func toolProvider(_ name: String) -> ToolProvider {
    isMCPTool(name) ? .mcp : .builtIn
}
```

### Rendering (iOS)

```swift
struct ToolActivityCard: View {
    let event: SessionEvent
    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                Image(systemName: "hammer.fill")
                    .foregroundStyle(provider == .mcp ? LG.accent : LG.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName).font(.callout.bold()).foregroundStyle(LG.textPrimary)
                    Text(inputPreview).font(.caption).foregroundStyle(LG.textTertiary).lineLimit(1)
                }
                Spacer()
                statusBadge
            }
            .padding(14)
        }
    }
}
```

### Display name normalization

```swift
// `mcp__memory__create_entities` → "memory · create_entities"
func displayName(_ rawName: String) -> String {
    guard rawName.hasPrefix("mcp__") else { return rawName }
    let parts = rawName.dropFirst(5).split(separator: "_", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return rawName }
    return "\(parts[0]) · \(parts[1])"
}
```

### Failure pairing

When `PostToolUseFailure` arrives for an MCP call:

```swift
let activity = SessionEvent(... type: .toolActivity, payload: .toolActivity(failed))
let warning  = SessionEvent(... type: .warning, severity: .warning,
                            payload: .warning(WarningPayload(code: "mcp.failed",
                                                            title: "MCP tool failed: \(displayName(name))",
                                                            detail: failureReason)))
emit([activity, warning])
```

## Examples

**Good** — generic surface that works for any MCP server:

```swift
let card = ToolActivityCard(event: event)   // input/output digests, no schema assumptions
```

**Bad** — coupling iOS to a specific server:

```swift
if name == "mcp__github__create_pr" {        // ❌ don't special-case servers in UI
    GitHubPRDetailedView(event: event)
}
```

## Pitfalls

- Forgetting that MCP tool names are case-sensitive. Match exactly.
- Letting full `tool_response` JSON cross the bridge. It can be huge — send a digest + size, then let the user request the full payload through Mac developer mode.
- Treating `mcp__server__.*` matcher syntax as a literal name. It's a regex matcher in `.claude/settings.json`.
- Showing internal IDs (`tool_use_id`) on iOS. They're for the Mac dev pane.
