---
name: claude-code-cli-integration
description: Use when launching the Claude Code CLI from DNP Remote Mac — detection, version probing, supported flag combinations, project workspace, resume/continue. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Terminal/ClaudeSessionService.swift or anything that builds Claude launch arguments.
---

## When to use

Building or modifying the way DNP Remote Mac launches Claude Code. We use the **public** CLI only — no private remote-control APIs.

## Hard rules

- Detect the binary in this order: `which claude`, then `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/.claude/bin/claude`.
- Version probe with `claude --version`. Cache the result; refresh on demand.
- **Default flags: none.** Specifically, never `--dangerously-skip-permissions`.
- Supported flags we may pass (validate against `https://code.claude.com/docs/en/cli-reference`):
  `--verbose`, `--append-system-prompt @<file>`, `--allowed-tools <csv>`, `--permission-mode <mode>`, `--mcp-config <file>`, `--continue`, `--resume <id>`, `--print`.
- Always launch inside the PTY — never `Process` + `Pipe` (Claude's interactive prompt needs a controlling TTY).
- Hand a clean working directory (`workingDirectory:`) — use the user's selected project folder.

## How to apply

### Build args

```swift
func launchCommand(
    projectPath: String,
    appendSystemPromptFile: String? = nil,
    allowedTools: [String]? = nil,
    verbose: Bool = false,
    resumeSessionId: String? = nil
) -> (command: String, args: [String])? {
    guard let path = detectedPath else { return nil }
    var args: [String] = []
    if let resume = resumeSessionId { args += ["--resume", resume] }
    if verbose { args.append("--verbose") }
    if let prompt = appendSystemPromptFile { args += ["--append-system-prompt", "@\(prompt)"] }
    if let tools = allowedTools, !tools.isEmpty { args += ["--allowed-tools", tools.joined(separator: ",")] }
    return (path, args)
}
```

### Spawn through PTY

```swift
guard let (cmd, args) = claude.launchCommand(projectPath: project.path) else { return }
try runtime.spawn(command: cmd, args: args, workingDirectory: project.path)
```

### Detect

```swift
static func locateClaudeBinary() -> String? {
    if let p = which("claude") { return p }
    let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                      "\(NSHomeDirectory())/.local/bin/claude",
                      "\(NSHomeDirectory())/.claude/bin/claude"]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}
```

## Examples

**Good** — opting into developer verbosity but never permission bypass:

```swift
claude.launchCommand(projectPath: "/Users/me/code/myapp", verbose: true)
// args: ["--verbose"]
```

**Bad** — sneaking dangerous flags in:

```swift
args.append("--dangerously-skip-permissions")  // ❌ never
```

## Pitfalls

- Calling `--continue` blindly after a clean checkout will fail; only call when there's a real prior session.
- Passing `--allowed-tools` without thought silently constrains Claude's behavior. Surface it in Settings UI so the user knows.
- A tilde in `appendSystemPromptFile` won't expand; resolve to absolute path before passing.
- If the binary is unreachable, the Mac shows a banner. Don't auto-install it.
