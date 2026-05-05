---
name: claude-code-permissions
description: Use when mapping Claude Code's permission model (ask / allow / deny, permissionDecision, permission_mode) to our ApprovalRequest flow. Triggers when changing permissions handling on the Mac, designing iOS approval cards, or updating .claude/settings.local.json defaults.
---

## When to use

Anything that converts a Claude permission prompt into a user-facing approval, or anything that tweaks the default permission rules in this repo.

## Hard rules

- Respect Claude Code's permission model. **Never** default to `--dangerously-skip-permissions`. The setting exists in Mac → Settings → Claude as an explicit, banner-warned toggle, but iOS approvals never grant it.
- iOS approvals translate to Claude's `permissionDecision` (`allow` / `deny` / `ask` / `defer`). Precedence when multiple hooks fire: `deny > defer > ask > allow`.
- Each `ApprovalRequest` carries: `actionType`, `target`, `summary`, `detail`, `risk`, `requestedAt`, `timeoutAt`. Risk is computed by `RiskClassifier`.
- Audit every transition. The audit log is durable in `events.jsonl`.
- Don't conflate Claude's *permission rules* (`.claude/settings.local.json`'s allow/deny lists) with our *approval flow*. Permission rules are static; approvals are dynamic.

## How to apply

### Build an `ApprovalRequest` from a `PermissionRequest` hook

```swift
let payload = try JSONDecoder().decode(PermissionRequestHook.self, from: jsonData)
let req = ApprovalRequest(
    sessionId: sessionId,
    actionType: actionType(for: payload.tool_name),
    target: payload.tool_input["command"]?.stringValue ?? payload.tool_name,
    summary: humanSummary(for: payload),
    detail: payload.permission_suggestions?.first?.rules.first?.ruleContent,
    risk: classifyRisk(payload),
    timeoutAt: Date().addingTimeInterval(ProtocolConstants.approvalDefaultTimeoutSeconds)
)
await coordinator.create(req)
```

### Apply the iOS decision back to Claude

```swift
switch await coordinator.apply(response) {
case .accepted(let approved):
    if approved.status == .approved {
        emitDecisionJSON(["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow"]
        ]])
    } else {
        emitDecisionJSON(["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "deny"],
            "decisionReason": "Rejected from DNP Remote iOS"
        ]])
    }
case .alreadyDecided, .expired, .notFound:
    // Fall back to Claude's default prompt UX.
    break
}
```

### Pre-canned safe rules for `.claude/settings.local.json` (user-only)

```json
{
  "permissions": {
    "deny": [
      "Bash(rm -rf /)",
      "Bash(:(){ :|:& };:)"
    ],
    "ask": [
      "Bash(git push --force*)",
      "Edit(/Users/*/.env*)",
      "Edit(/Users/*/.aws/*)",
      "Edit(/Users/*/.ssh/*)"
    ]
  }
}
```

## Examples

**Good** — surface risk and target both:

```swift
ApprovalCard(approval: req) { decision in vm.decide(approval: req, decision: decision) }
// where the card shows: risk pill + monospaced target string + Approve / Reject buttons
```

**Bad** — auto-approving low-risk items:

```swift
if req.risk == .low { auto-approve }   // ❌ user is always in the loop
```

## Pitfalls

- Treating `permission_mode == "default"` as "approve everything". It only means Claude is using the project's own rules, which may still ask.
- Forgetting `decisionReason` in deny — iOS users see a clearer audit trail when reasons are present.
- Building the approval target from the wrong field (`tool_name` instead of `tool_input.command` for Bash) — always look at the input.
- Letting the user disable the approval flow entirely. There's no off-switch by design.
