import Foundation

/// The estimate line before Send (DQ §6.6 "Estimates"): about how many tokens a question sends,
/// on which model, and how long the answer usually takes. Pure; no call is ever made to estimate.
package enum QAEstimator {
    /// Latin text ≈ 4 characters per token; Chinese / Japanese / Korean ≈ 1.5.
    package static func tokens(_ text: String) -> Int {
        var cjk = 0, other = 0
        for u in text.unicodeScalars {
            if isCJK(u) { cjk += 1 } else { other += 1 }
        }
        let t = Double(other) / 4 + Double(cjk) / 1.5
        return text.isEmpty ? 0 : max(1, Int(t.rounded(.up)))
    }

    /// Seconds an answer is expected to take: from `recentMs` (the latest durations of this
    /// provider + model, newest first; at least 3) — about the 25th to the 90th percentile —
    /// otherwise a default per provider and depth.
    package static func latency(recentMs: [Int], mode: AssistMode, depth: AssistSettings.Depth) -> ClosedRange<Int> {
        let samples = recentMs.prefix(20).filter { $0 > 0 }.sorted()
        if samples.count >= 3 {
            func pct(_ p: Double) -> Int { samples[min(samples.count - 1, Int((Double(samples.count - 1) * p).rounded()))] }
            let low = max(1, Int((Double(pct(0.25)) / 1000).rounded(.down)))
            let high = max(low + 1, Int((Double(pct(0.9)) / 1000).rounded(.up)))
            return low...high
        }
        switch (mode, depth) {
        case (.claude, .quick): return 5...15
        case (.claude, .thorough): return 15...40
        case (.codex, .quick): return 8...30
        case (.codex, .thorough): return 20...90
        case (.local, _): return 3...20
        case (.mock, _): return 1...2
        case (.off, _): return 5...15
        }
    }

    /// The estimate of a built context on `mode` / `model`.
    package static func estimate(_ stats: QAContextStats, systemPrompt: String, mode: AssistMode, model: String?,
                                 depth: AssistSettings.Depth, recentMs: [Int], papers: Int) -> QAEstimate {
        let pages = stats.pages.flatMap { $0 }
        return QAEstimate(chars: stats.chars + systemPrompt.count, estimatedTokens: stats.estimatedTokens + tokens(systemPrompt),
                          pages: pages, omitted: stats.omittedPages, model: mode == .off ? nil : model,
                          provider: mode == .off ? nil : mode.rawValue,
                          latency: latency(recentMs: recentMs, mode: mode, depth: depth),
                          mode: stats.mode, fullText: stats.fullText, papers: papers)
    }

    /// "21k" / "850": a token count as the estimate line shows it.
    package static func compact(_ n: Int) -> String {
        if n < 1_000 { return String(n) }
        let k = Double(n) / 1_000
        return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF,
             0x3200...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }
}
