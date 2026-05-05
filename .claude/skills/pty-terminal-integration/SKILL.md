---
name: pty-terminal-integration
description: Use when implementing or debugging real PTY behavior in DNP Remote Mac — forkpty, termios raw mode, winsize / TIOCSWINSZ resize, lifecycle, stream handling, signal forwarding. Triggers on changes to apps/DNPRemoteMac/DNPRemoteMac/Terminal/PTYRuntimeService.swift.
---

## When to use

Anytime you need to spawn a child process with a real controlling terminal — required for Claude Code interactive prompts and for any tool that reads from `/dev/tty`. Don't use `Process` + `Pipe` for this.

## Hard rules

- Use `forkpty(3)` from libutil. Bridge it via `@_silgen_name("forkpty")` in Swift since Foundation doesn't expose it.
- Set the master FD non-blocking (`fcntl(F_SETFL, O_NONBLOCK)`) so reads don't block the dispatch source.
- Read on a dedicated `DispatchQueue` via `DispatchSource.makeReadSource(fileDescriptor:queue:)`. Surface bytes through an `AsyncStream<Data>`.
- Resize with `ioctl(masterFD, TIOCSWINSZ, &winsize)`. Default size 40×120 rows×cols. Re-issue on SwiftUI geometry change.
- Reap the child with `waitpid(pid, &status, 0)` on a background queue. Always `close(masterFD)` exactly once on cleanup.
- Forward `SIGINT` / `SIGTERM` / `SIGWINCH` correctly. Killing the session must not orphan a Claude child.

## How to apply

### Spawning

```swift
var master: Int32 = 0
var winsz = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
var term = termios()
cfmakeraw(&term)

let pid = forkpty(&master, nil, &term, &winsz)
if pid < 0 { throw POSIXError(.ENOMEM) }
if pid == 0 {
    chdir(workingDirectory)
    for (k, v) in env { setenv(k, v, 1) }
    var args: [UnsafeMutablePointer<CChar>?] = [strdup(command)] + extra.map(strdup) + [nil]
    execvp(command, &args)
    _exit(127)
}
// Parent: register read source on `master`.
```

### Reading

```swift
let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
source.setEventHandler {
    var buf = [UInt8](repeating: 0, count: 8192)
    let n = read(master, &buf, buf.count)
    if n > 0 { continuation.yield(Data(bytes: buf, count: n)) }
    else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
        continuation.finish(); cleanup()
    }
}
source.resume()
```

### Writing

```swift
data.withUnsafeBytes { ptr in
    _ = Darwin.write(masterFD, ptr.baseAddress, data.count)
}
```

### Resize

```swift
var sz = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
_ = ioctl(masterFD, TIOCSWINSZ, &sz)
kill(pid, SIGWINCH)   // poke the child if needed
```

### Cleanup

```swift
private func cleanup(processId: UUID) {
    Task { @MainActor in
        if let p = self.processes.removeValue(forKey: processId) { close(p.masterFD) }
    }
}
```

## Examples

**Good** — declare the imported function once:

```swift
@_silgen_name("forkpty")
private func forkpty(_ amaster: UnsafeMutablePointer<Int32>?,
                     _ name: UnsafeMutablePointer<CChar>?,
                     _ termp: UnsafeMutablePointer<termios>?,
                     _ winp: UnsafeMutablePointer<winsize>?) -> pid_t
```

**Bad** — using `Process` for Claude Code:

```swift
// ❌ Claude Code's interactive prompt won't render correctly without a controlling TTY.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
process.standardOutput = Pipe()
```

## Pitfalls

- Forgetting `O_NONBLOCK` on the master FD — `read` blocks the dispatch source thread.
- Reaping in `setExitHandler` on a `Process` looks tempting; we don't use `Process`. Spawn a global `DispatchQueue.global().async` reaper that calls `waitpid`.
- Closing the master FD twice causes `EBADF` later in unrelated code.
- Calling `kill(pid, SIGTERM)` then immediately `close(masterFD)` can lose the goodbye bytes — wait for `waitpid` first.
- Not re-reading `errno` after a partial read — treat `EAGAIN`/`EINTR` as recoverable.
