import Foundation
import DNPShared

// MARK: - Argument parsing

struct Args {
    var event: String = "Unknown"
    var endpoint: String = ProcessInfo.processInfo.environment["DNP_RELAY_ENDPOINT"] ?? "http://127.0.0.1:18734/hook"
    var fallbackPath: String = ProcessInfo.processInfo.environment["DNP_RELAY_FALLBACK"] ?? ".dnp/events/hooks.jsonl"
    var failOpen: Bool = true   // never fail Claude execution on relay errors
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let token = it.next() {
        switch token {
        case "--event":
            if let v = it.next() { a.event = v }
        case "--endpoint":
            if let v = it.next() { a.endpoint = v }
        case "--fallback":
            if let v = it.next() { a.fallbackPath = v }
        case "--strict":
            a.failOpen = false
        default: break
        }
    }
    return a
}

// MARK: - Main

let args = parseArgs()

let stdinData: Data = {
    let h = FileHandle.standardInput
    return (try? h.readToEnd()) ?? Data()
}()

let json: String = String(data: stdinData, encoding: .utf8) ?? ""

let envelope: [String: Any] = [
    "event": args.event,
    "timestamp": ISO8601DateFormatter.dnpShared.string(from: Date()),
    "cwd": FileManager.default.currentDirectoryPath,
    "pid": ProcessInfo.processInfo.processIdentifier,
    "raw": json
]

func writeFallback() {
    let dir = (args.fallbackPath as NSString).deletingLastPathComponent
    if !dir.isEmpty { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    if let line = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) {
        let withNewline = line + Data([0x0A])
        if FileManager.default.fileExists(atPath: args.fallbackPath) {
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: args.fallbackPath)) {
                try? h.seekToEnd()
                try? h.write(contentsOf: withNewline)
                try? h.close()
            }
        } else {
            try? withNewline.write(to: URL(fileURLWithPath: args.fallbackPath))
        }
    }
}

func tryPostToMac() -> Bool {
    guard let url = URL(string: args.endpoint) else { return false }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 1.5
    req.httpBody = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    let sem = DispatchSemaphore(value: 0)
    var success = false
    URLSession.shared.dataTask(with: req) { _, response, err in
        if err == nil, let r = response as? HTTPURLResponse, (200..<300).contains(r.statusCode) {
            success = true
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 2)
    return success
}

if !tryPostToMac() {
    writeFallback()
}

// fail-open: exit 0 so Claude Code keeps running.
exit(args.failOpen ? 0 : (json.isEmpty ? 1 : 0))
