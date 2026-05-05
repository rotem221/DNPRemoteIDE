import Foundation
import Darwin

/// Real PTY-backed runtime for shells and Claude Code. Uses `forkpty` so child processes get
/// a proper controlling terminal — this is required for Claude Code's interactive prompts.
final class PTYRuntimeService: ObservableObject, @unchecked Sendable {

    static var ptyAvailable: Bool { true }

    struct Process: Identifiable {
        let id: UUID
        let pid: pid_t
        let masterFD: Int32
        let command: String
        let workingDirectory: String
        let startedAt: Date
    }

    @Published private(set) var processes: [UUID: Process] = [:]

    /// stdout/stderr stream for a given process, as raw UTF-8 bytes (caller normalizes).
    func outputStream(for processId: UUID) -> AsyncStream<Data> {
        AsyncStream { continuation in
            guard let proc = processes[processId] else { continuation.finish(); return }
            let fd = proc.masterFD
            let queue = DispatchQueue(label: "dnp.pty.read.\(processId)")
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    continuation.yield(Data(bytes: buf, count: n))
                } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                    continuation.finish()
                    self.cleanup(processId: processId)
                }
            }
            source.setCancelHandler {}
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
    }

    /// Spawn a command inside a real PTY. Returns the assigned process id.
    @discardableResult
    func spawn(command: String, args: [String] = [], workingDirectory: String, env: [String: String] = ProcessInfo.processInfo.environment) throws -> UUID {
        var master: Int32 = 0
        var winsz = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        // Pre-allocate child argv in the parent so the child sees valid pointers after fork.
        // Layout: [argv0, arg1, ..., argN, NULL]
        let cArgs: [UnsafeMutablePointer<CChar>?] = ([command] + args).map { strdup($0) } + [nil]
        let cArgsBuf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cArgs.count)
        for (i, p) in cArgs.enumerated() { cArgsBuf[i] = p }

        // Use the parent's tty defaults (cooked mode, echo, signals). `cfmakeraw` is wrong for hosting
        // an interactive shell — it disables canonical input + echo so zsh/bash become unusable.
        let pid = forkpty(&master, nil, nil, &winsz)
        if pid < 0 {
            cArgsBuf.deallocate()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        if pid == 0 {
            // Child
            _ = chdir(workingDirectory)
            for (k, v) in env { setenv(k, v, 1) }
            execvp(command, cArgsBuf)
            // If exec fails, write a diagnostic and exit cleanly. The parent reads it from the PTY.
            let msg = "exec \(command) failed: \(String(cString: strerror(errno)))\n"
            msg.withCString { _ = Darwin.write(1, $0, strlen($0)) }
            _exit(127)
        }
        // Parent
        let id = UUID()
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        let proc = Process(
            id: id, pid: pid, masterFD: master,
            command: ([command] + args).joined(separator: " "),
            workingDirectory: workingDirectory,
            startedAt: Date()
        )
        Task { @MainActor in self.processes[id] = proc }
        // Reaper
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            self?.cleanup(processId: id)
        }
        // Free the parent-side argv (the child has already exec'd and copied them).
        for p in cArgs where p != nil { free(p) }
        cArgsBuf.deallocate()
        return id
    }

    func write(_ data: Data, to processId: UUID) {
        guard let proc = processes[processId] else { return }
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(proc.masterFD, ptr.baseAddress, data.count)
        }
    }

    func resize(processId: UUID, rows: UInt16, cols: UInt16) {
        guard let proc = processes[processId] else { return }
        var sz = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(proc.masterFD, TIOCSWINSZ, &sz)
    }

    func terminate(processId: UUID, signal: Int32 = SIGTERM) {
        guard let proc = processes[processId] else { return }
        kill(proc.pid, signal)
    }

    private func cleanup(processId: UUID) {
        Task { @MainActor in
            if let p = self.processes.removeValue(forKey: processId) {
                close(p.masterFD)
            }
        }
    }
}

// `forkpty` lives in libutil; bridge it.
@_silgen_name("forkpty")
private func forkpty(
    _ amaster: UnsafeMutablePointer<Int32>?,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafeMutablePointer<termios>?,
    _ winp: UnsafeMutablePointer<winsize>?
) -> pid_t
