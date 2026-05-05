# DNP Remote Suite — Changelog

This file logs the substantive behavioural changes since the second public commit
(`f406305 Approvals, diff cards, GitHub project linking, and turn-stat indicators`).
The current commit on `main` collects everything below into one batch
(`36b8e19 PTY-driven approvals, force-allow, file edit markers, inline diff banners`,
plus the work since); this changelog is the human-readable expansion.

---

## Approval pipeline (Mac)

- **PTY-driven lifecycle.** `PreToolUse` / `PermissionRequest` hooks no longer
  raise approval cards directly. They cache tool / target context into
  `MacAppViewModel.pendingHookCalls[sid]`. The 750 ms `pollLiveTerminalText`
  timer scans every session's terminal via `TerminalSession.isAtClaudePrompt()`
  and raises a card only when Claude's inline `Do you want to proceed?`
  prompt is actually visible on screen. When the prompt vanishes a 1.5 s
  grace period later, `silentlyDismissStaleApproval` clears the card and
  emits an `.approvalResult` with `.expired` lifecycle so iOS removes it —
  no PTY digit is written during dismissal. Eliminates phantom `allow`
  notifications.
  - Memory: `architecture_pty_driven_approvals.md`.
- **Broader prompt detection.** `isAtClaudePrompt()` accepts ANY of three
  signals: caret glyph next to a numbered option (`❯ 1.` / `❯ 1)`), three
  consecutive numbered options near the bottom of the buffer, or a trigger
  headline (`Do you want`, `Allow Claude`, `Use this`, `Run this`,
  `Apply this`, `Continue?`, `Confirm:`, `Proceed?`) plus a `1. Yes` / `1) Yes`
  marker. Catches every Claude TUI variant we observed.
- **Aligned dedup keys.** `MacAppViewModel.unifiedToolTarget(toolName:toolInput:)`
  is the single source of truth for "what does this tool act on" — same
  string in `PreToolUse` and `PermissionRequest`, so dedup hashes collide
  and duplicate cards stop stacking for Edit / Write / MultiEdit.
- **PTY guard on approval write.** `handleApprovalDecision` only writes
  `1\r` / `2\r` if `isAtClaudePrompt()` is currently true. Catches
  multi-device retries and stale UI; the worst case is now a silent no-op
  rather than `1` leaking into chat.
  - Memory: `feedback_approval_pty_guard.md`.
- **In-function content-hash dedup removed from `raiseApproval`.** The
  poller already gates on `pending == nil` + `approvalRaiseInFlight`, and
  the old hash dedup was blocking legitimate re-prompts after a silent
  dismiss.
- **Force Allow.** New `forceApprove` bridge message + `ForceApprovePayload`.
  iOS surfaces an inline `Allow` pill on Row 2 of the composer (next to
  the Context indicator), gated by `dnp.ios.showForceApprove` (Settings →
  Feed). Tap morphs in place into a `[✗][✓ Send 1↵]` confirm pair —
  no system action sheet. Mac's `forceApprove(sessionId:)` deliberately
  bypasses `isAtClaudePrompt()` (the whole point is to override the
  detector when it misses); the PTY guard on standard approvals stays as
  the catch-all.

## Live thinking + indicator

- **PTY scrape mirror.** `MacAppViewModel.pollLiveTerminalText` (750 ms)
  scrapes Claude's TUI via `TerminalSession.recentVisibleText`, runs it
  through `filterClaudeTUI` (drops the prompt row / status bar /
  separators), and emits `.thinkingSummary` events. iOS receives them
  and pipes the text into `liveThinking[sid]`, so the indicator's
  secondary line streams Claude's actual output instead of just a verb.
- **Indicator format matches Claude's CLI.** `Thinking (1m 41s · ↓ 6.7k · thought for 10s)`
  with stats inline next to the verb (no detached footer row). `formatElapsed`
  collapses `0–59 → Ns`, `≥60 → Xm` or `Xm Ys`.
- **`thoughtForSeconds`** tracked on iOS — first `.thinkingSummary` of a
  turn stamps `thinkingPhaseStart`, first `.assistantMessage` closes the
  duration. Cleared on user prompt.
- **No phantom Thinking cards on relaunch.** `bridge.onEventBatch` filters
  `.thinkingSummary` out of incoming snapshots, since live receipt of
  those events never appends them to `feed[]` either.

## Transcript watcher

- **Tail reader stops at the last `\n`.** Previously the watcher consumed
  partial JSONL lines and silently dropped them when JSON parse failed —
  closing-summary disappearance bug.
  - Memory: `feedback_transcript_partial_lines.md`.
- **`ai-title` adoption.** Claude Code writes `{"type":"ai-title", ...}`
  to its session JSONL once it has summarised the conversation. The
  watcher emits `onAITitle`; `MacAppViewModel.applyClaudeAITitle` adopts
  the title and adds the session to `claudeNamedSessions`. Both
  `maybeAutoTitleSession` and the `Claude · <short>` SessionStart
  placeholder consult that set and bail out — Claude's name is never
  overwritten.
  - Memory: `reference_claude_ai_title.md`.

## File edit markers + inline diff (Mac + iOS)

- **`editedFilesByProject` + `lastDiffByFile`** on `MacAppViewModel`,
  populated in `deliverCodeEdit`. Each iOS bridge connect pushes the maps
  forward; iOS mirrors them.
- **Mac file explorer**: rows whose path (or any descendant for folders)
  is in the edited set get an orange `LG.warning` dot, warm-tinted icon
  and filename, and a hover background.
- **Mac code editor**: Cursor-style inline diff banner above the
  `SourceEditor` when the open file has a `lastDiffByFile` entry.
  Collapsed-by-default chip with `+N / −M` stats; expand to see the
  green / red diff (reuses the `DiffPreviewView` renderer from the feed
  pane).
- **iOS file explorer**: `IOSFileExplorerView` row helpers
  `isFileEdited(_:)` / `isFolderEdited(_:)` resolve `<rootPath>/<relativePath>`
  against `vm.editedFilePaths`. Edited rows badge with the warning tint.
- **iOS file viewer**: `IOSFileViewerSheet` shows a `IOSDiffBanner` above
  the file content for files with a `vm.lastDiffByFile[abs]` entry. Same
  collapse / expand behaviour as the Mac banner.

## File explorer — iOS UX

- **Files opens as a pushed page**, not a bottom-up `.fullScreenCover`.
  `IOSAppShellView`'s `.overlay` adds the explorer with
  `.transition(.move(edge: .trailing))`; the sidebar drawer closes itself
  on tap.
- **Project switcher removed.** The "Choose project folder…" menu item
  is gone — the explorer is strictly scoped to the active project's
  tree.
- **Git-link banner.** Above the project root listing: linked →
  `</> owner/repo  ⌥ branch` accent strip; not linked → `</> Not linked
  to Git` in tertiary text. Reads from `vm.remoteProject?.gitHub`.
- **Search added** to the iOS folder picker (`.searchable` placement,
  current-depth filter, auto-clears on navigation).

## Project picker — iOS

- **Open Folder on Mac** now opens an iOS-side `IOSFolderPickerSheet`
  pushed into the parent `NavigationStack` instead of asking the Mac to
  show its `NSOpenPanel` (which was getting wedged with no way to
  dismiss from iOS).
- **Clone from Git** enabled, navigates to `IOSGitHubBrowseView` (existing
  GitHub-repo browser).
- **Connect to SSH** enabled — currently shows a basic info alert with
  next-step guidance (full SSH-from-iOS plumbing not yet wired).

## Project state restoration

- **iOS persists `currentProjectPath`** via UserDefaults. On relaunch the
  app drops the user back into the chat for the previously-active project
  instead of re-showing the picker. On bridge `.connected` the path is
  re-synced to the Mac via `requestSetProjectRoot`.

## AI Usage indicator (new)

- **Endpoint**: Anthropic's `https://api.anthropic.com/api/oauth/usage`
  — `Bearer` token re-uses the user's existing Claude Code OAuth, with
  the discovery chain documented by Muxy
  (`Muxy/Services/Providers/ClaudeCodeProvider.swift`): env
  `CLAUDE_CODE_OAUTH_TOKEN` → `~/.claude/.credentials.json` →
  Keychain via `/usr/bin/security`.
  - Memory: `reference_claude_oauth_usage.md`.
- **Shared model**: `AIUsageWindow(label, percent, resetAt, detail)` and
  `AIUsageSnapshot(providerName, fetchedAt, windows, errorMessage)` in
  `DNPShared/Models/AIUsage.swift`. New `aiUsageBroadcast` bridge
  message + `AIUsageBroadcastPayload`.
- **Mac**: `ClaudeUsageService` runs on a 5-min `Timer` from
  `MacAppViewModel.bootstrap()`. `MacAppShellView`'s status bar gets a
  compact `aiUsagePill` (sparkles + headline %, + 5h label) that opens a
  `MacAIUsagePopover` (320 pt, full per-window breakdown with progress
  bars, refresh button) — same affordance pattern as Errors / Warnings.
- **iOS**: pushed to every connected client on each refresh AND on
  reconnect. `IOSSidebarDrawer` renders `AIUsageSidebarCard` pinned to
  the BOTTOM of the drawer (compact single-line rows: `5h  40%  ▰▰▰▱`,
  no per-row reset times) so it doesn't crowd the primary actions.

## Sidebar layout (iOS)

- Drawer wrapped in `GeometryReader` with `.frame(minHeight: outer - 32)`
  so a `Spacer` between the navigation cluster and AI Usage actually
  expands inside the scroll content — AI Usage pins to the bottom edge.

## Composer — iOS

- **Force Allow inline pill** moved out of the floating ZStack into Row 2
  of the composer, between the Context indicator and the Spacer. Two
  states: idle pill ↔ `[✗][✓ Send 1↵]` confirm pair (no action sheet).
- **`+` attach button** — switched from `Button { ... }` to
  `.contentShape + .onTapGesture` recipe to avoid the iOS-26 Liquid
  Glass tap-eating that the parent capsule was causing. Now also fires
  `dnpHaptic(.light)`.
- **Voice transcription**:
  - New `SpeechTranscriber` (`@MainActor ObservableObject`) wrapping
    `SFSpeechRecognizer` + `AVAudioEngine`. Per-start recogniser factory
    walks `Locale.preferredLanguages.first` → region-stripped → `en-US`,
    so Hebrew (`he-IL`) and any other supported locale work natively.
  - Live partial transcripts stream into `text` via
    `mergeLiveTranscript(_:)` (anchored to a `preRecordPrefix` snapshot
    taken at start so previously-typed content isn't duplicated).
  - `Info.plist` keys added: `NSMicrophoneUsageDescription`,
    `NSSpeechRecognitionUsageDescription`.
  - `AdaptiveSendButton` got a fourth state `.recording` (red disc with
    breathing pulse). Mode priority: `isRunning > isRecording > hasText
    > .record` — so the stop affordance stays visible the entire time
    transcription is live, even as text fills the field.
  - **X-clear button** appears on Row 2 (next to send) once `hasContent
    && !isRecording && !isRunning`; tap clears the draft.
  - Transcriber error banner (mic-slash icon + warning-tinted pill) shown
    above the composer when start fails (denied permission, no audio
    device, etc.); auto-clears 4 s later.
  - `AdaptiveSendButton`'s `.record` mode background simplified from
    `Circle().fill(.clear).liquidGlassCircle()` → plain
    `LG.surfaceElevated` fill + hairline border, plus
    `.contentShape(Circle())` — fixes the iOS-26 Liquid Glass
    tap-swallowing on the mic button.

## Back-to-bottom FAB (iOS)

- After multiple geometry-based attempts proved unreliable in iOS 17,
  switched to a deterministic detector: `simultaneousGesture(DragGesture)`
  on the ScrollView flips `hasPanned = true` on any user pan; iOS-17
  native `scrollPosition(id:)` resets it to `false` when the topmost
  visible item is the bottom sentinel. Auto-scroll on new event arrival
  also resets. FAB visibility gate: `hasOverflow && hasPanned`. Bottom
  trailing column, 12 pt above the safe-area bottom (= top of composer).

## Screen mirror

- **Capture API**: `CGDisplayCreateImage` (silently returned stale frames
  on macOS 14/15 in some TCC states — "stuck and not live" symptom)
  swapped for `CGWindowListCreateImage`, matching the DNP Remote Vibe
  Coding reference. Deprecation warning is the same one the reference
  carries; runtime behaviour is correct.
- **JPEG quality** dropped from `0.55` → `0.42`, and Mac's
  `maxLongEdge` ceiling cut from 1920 → 1280.
- **Quality tiers** lightened on iOS: low `(3 fps × 540 pt)`,
  medium `(5 fps × 800 pt)`, high `(10 fps × 1280 pt)`.
- **Cursor decoupled from frames.** New `screenMirrorCursor` envelope +
  `ScreenMirrorCursorPayload(cursorX, cursorY)`. Mac runs a separate
  30 Hz cursor `DispatchSourceTimer` (`scheduleCursorTimer`) that pushes
  positions through `cursorSink`. iOS animates `liveCursorX/Y` with
  `.linear(0.033s)` for fluid pointer motion even when frames are at
  5 fps. Same model as the reference's `screen_cursor` WS message.
- **Touchpad mode** (toggle in the screen-mirror top bar,
  `dnp.ios.screenMirror.trackpadMode` `@AppStorage`):
  - When ON: joystick hidden, the entire mirror surface is a virtual
    trackpad — drag = relative cursor delta (sensitivity 2.6×), tap =
    `.mouseLeftClick`, long-press = `.mouseRightClick`. Implemented as
    `TrackpadGestureSurface` overlay; pinch-zoom + double-tap-reset
    gestures on the inner `Image` continue to work alongside.
  - When OFF: joystick visible, screen taps do NOTHING. Per-pixel
    absolute click is gone; the user explicitly didn't want screen
    taps to fire when the touchpad isn't enabled.
- **Cursor sprite size**: shrunk to 10 × 14 pt with thinner stroke and
  shadow, closer to a real macOS pointer at viewing distance.
- **Terminal background tone**: `MacScreenMirrorService` and
  `TerminalEmulatorView` use `NSColor.underPageBackgroundColor` instead
  of a hardcoded near-black, matching Settings / Diagnostics chrome.

## Mac UX miscellany

- **`BranchMenu` async**: `git branch` is now read on a detached Task
  via the new `BranchMenu` view in `FileExplorerView.swift`. The
  previous form ran `Process + waitUntilExit` synchronously inside
  `Menu { ... }` content, which crashed with `EXC_BAD_ACCESS` /
  AttributeGraph cycle whenever SwiftUI updated the menu.
  - Memory: `feedback_swiftui_process_reentrancy.md`.
- **File explorer hover** uses `MacTheme.accent.opacity(0.14)` (subtle
  blue glow) instead of the previous nearly-invisible
  `surfaceAlt.opacity(0.28)`.

## Project picker — iOS

- **Open Folder** routes to `IOSFolderPickerSheet` (push, not sheet).
- **Clone from Git** routes to `IOSGitHubBrowseView`.
- **Connect to SSH** opens an info alert.

## Notification hook filter

- `Notification` hook messages matching `no response`,
  `response not required`, `response was not requested` are dropped on
  the Mac before becoming `WarningPayload` events — they were Claude's
  end-of-turn bookkeeping leaking onto iOS as warning cards next to
  the actual reply.

---

## Sentinel facts to keep in mind

- iOS deployment target is **17.0**; some APIs (`scrollPosition(id:)`,
  `AVAudioApplication.requestRecordPermission`) are 17+ only.
- `DNPShared` is compiled INLINE into both apps via XcodeGen `sources:`
  globs. After adding a new file under `Packages/DNPShared/Sources/`,
  run `xcodegen generate` in **both** `apps/DNPRemoteMac/` and
  `apps/DNPRemoteiOS/` — without it, the build can't find the new type.
- `CGWindowListCreateImage` is deprecated but still functional through
  macOS 15. The eventual successor is ScreenCaptureKit.
- Liquid Glass interactive sheen on iOS 26 swallows taps on the inner
  `Button` recogniser. For tappable controls inside
  `.liquidGlass*(interactive: true)` containers, use
  `.contentShape(<shape>) + .onTapGesture { … }` (see
  `reference_loola_contact_glass`).
