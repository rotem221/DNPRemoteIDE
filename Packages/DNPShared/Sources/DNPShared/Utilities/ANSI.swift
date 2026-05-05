import Foundation

/// Strips ANSI escape sequences and common terminal control bytes.
public enum ANSICleaner {

    /// Matches ANSI CSI/OSC/SGR sequences and bare control bytes that aren't \n / \t.
    /// Conservative — preserves printable UTF-8.
    public static func clean(_ s: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(s.unicodeScalars.count)
        var i = s.unicodeScalars.startIndex
        let scalars = s.unicodeScalars
        while i < scalars.endIndex {
            let u = scalars[i]
            if u == "\u{1B}" {
                // ESC sequence: skip until terminating byte.
                let next = scalars.index(after: i)
                if next < scalars.endIndex {
                    let n = scalars[next]
                    if n == "[" {
                        // CSI: skip until alpha letter [@-~]
                        var j = scalars.index(after: next)
                        while j < scalars.endIndex {
                            let c = scalars[j]
                            if (c.value >= 0x40 && c.value <= 0x7E) { j = scalars.index(after: j); break }
                            j = scalars.index(after: j)
                        }
                        i = j
                        continue
                    } else if n == "]" {
                        // OSC: skip until BEL or ST
                        var j = scalars.index(after: next)
                        while j < scalars.endIndex {
                            let c = scalars[j]
                            if c == "\u{07}" { j = scalars.index(after: j); break }
                            if c == "\u{1B}" {
                                let k = scalars.index(after: j)
                                if k < scalars.endIndex && scalars[k] == "\\" { j = scalars.index(after: k); break }
                            }
                            j = scalars.index(after: j)
                        }
                        i = j
                        continue
                    } else {
                        // Other ESC: skip 2 chars
                        i = scalars.index(after: next)
                        continue
                    }
                } else {
                    break
                }
            }
            // Strip raw control bytes except \n \t \r
            if u.value < 0x20 && u != "\n" && u != "\t" && u != "\r" {
                i = scalars.index(after: i)
                continue
            }
            output.append(u)
            i = scalars.index(after: i)
        }
        return String(output)
    }

    /// Heuristic: collapse repeated control redraws ("\r" carriage returns followed by overwriting text)
    /// into the *final* line rendered. Useful for spinner-style noise.
    public static func collapseCarriageReturns(_ s: String) -> String {
        var lines: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            // For each line, take everything after the last \r as the "final" rendering.
            if let lastCR = raw.lastIndex(of: "\r") {
                lines.append(String(raw[raw.index(after: lastCR)...]))
            } else {
                lines.append(String(raw))
            }
        }
        return lines.joined(separator: "\n")
    }
}
