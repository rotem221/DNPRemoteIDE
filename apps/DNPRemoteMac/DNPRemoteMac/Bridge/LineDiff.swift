import Foundation

/// Minimal line-by-line diff used to render `+`/`-` blocks on the iOS CodeEdit card. The
/// algorithm here is the textbook longest-common-subsequence (LCS) over O(N×M) lines —
/// fine because the inputs are typically a few-dozen lines at most (Edit / Write blocks).
///
/// We don't try to match Git's word-level intra-line highlighting; the iOS renderer only
/// needs whole-line classification (added / removed / context).
enum LineDiff {
    struct Result {
        /// Unified-diff style preview. Each line is prefixed with `+`, `-`, or ` `.
        let text: String
        /// Count of `+` lines.
        let adds: Int
        /// Count of `-` lines.
        let removes: Int
    }

    static func unifiedDiff(old: String, new: String) -> Result {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)

        let lcs = longestCommonSubsequence(a: oldLines, b: newLines)
        var output: [String] = []
        var adds = 0
        var removes = 0

        var i = 0, j = 0, k = 0
        while i < oldLines.count || j < newLines.count {
            // Lines that are part of the common subsequence — emit as context.
            if k < lcs.count && i < oldLines.count && oldLines[i] == lcs[k]
                              && j < newLines.count && newLines[j] == lcs[k] {
                output.append(" " + oldLines[i])
                i += 1; j += 1; k += 1
                continue
            }
            // Removed from `old`.
            if i < oldLines.count && (k >= lcs.count || oldLines[i] != lcs[k]) {
                output.append("-" + oldLines[i])
                removes += 1
                i += 1
                continue
            }
            // Added in `new`.
            if j < newLines.count && (k >= lcs.count || newLines[j] != lcs[k]) {
                output.append("+" + newLines[j])
                adds += 1
                j += 1
                continue
            }
            break
        }

        return Result(text: output.joined(separator: "\n"), adds: adds, removes: removes)
    }

    private static func lines(of s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Standard DP LCS — `O(N×M)` time, `O(N×M)` space. Returns the actual LCS as `[String]`,
    /// not just its length, so callers can walk both sequences against it.
    private static func longestCommonSubsequence(a: [String], b: [String]) -> [String] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                dp[i + 1][j + 1] = a[i] == b[j]
                    ? dp[i][j] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var result: [String] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }
}
