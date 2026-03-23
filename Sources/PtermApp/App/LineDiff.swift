/// Line-level diff using the LCS (Longest Common Subsequence) algorithm.
///
/// Given two arrays of lines (previous and current), computes the lines that
/// were **added or changed** in `current` — i.e., lines present in `current`
/// but not part of the longest common subsequence with `previous`.
///
/// This is equivalent to the "+" lines in a unified diff output.
///
/// The algorithm runs in O(N·M) time and space where N and M are the line
/// counts of `previous` and `current`.  For terminal grids (typically ≤ 100
/// rows), this is negligible.
///
/// This is a pure function with no side effects — easy to test in isolation.
enum LineDiff {

    /// Compute the added/changed lines between `previous` and `current`.
    ///
    /// Returns only lines from `current` that are not part of the LCS.
    /// The returned lines preserve their order in `current`.
    ///
    /// - Parameters:
    ///   - previous: The previous set of lines (e.g., last idle flush).
    ///   - current: The current set of lines (e.g., current screen content).
    /// - Returns: Lines in `current` that are new or changed relative to `previous`.
    static func addedLines(previous: [String], current: [String]) -> [String] {
        let lcs = longestCommonSubsequence(previous, current)
        // Walk current lines, skipping those that are part of the LCS.
        var lcsIndex = 0
        var result: [String] = []
        for line in current {
            if lcsIndex < lcs.count && line == lcs[lcsIndex] {
                lcsIndex += 1
            } else {
                result.append(line)
            }
        }
        return result
    }

    /// Compute the LCS of two string arrays.
    ///
    /// Uses the standard dynamic programming approach with O(N·M) table,
    /// then backtracks to reconstruct the subsequence.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let n = a.count
        let m = b.count
        guard n > 0 && m > 0 else { return [] }

        // Build DP table.  dp[i][j] = length of LCS of a[0..<i] and b[0..<j].
        // Use a flat array for cache locality.
        let stride = m + 1
        var dp = [Int](repeating: 0, count: (n + 1) * stride)

        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    dp[i * stride + j] = dp[(i - 1) * stride + (j - 1)] + 1
                } else {
                    dp[i * stride + j] = max(dp[(i - 1) * stride + j],
                                              dp[i * stride + (j - 1)])
                }
            }
        }

        // Backtrack to reconstruct the LCS.
        var lcs: [String] = []
        lcs.reserveCapacity(dp[n * stride + m])
        var i = n, j = m
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[(i - 1) * stride + j] >= dp[i * stride + (j - 1)] {
                i -= 1
            } else {
                j -= 1
            }
        }
        lcs.reverse()
        return lcs
    }
}
