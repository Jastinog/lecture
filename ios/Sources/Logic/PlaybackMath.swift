import Foundation

// Pure playback / library decisions, kept free of AVFoundation, SwiftUI and
// singletons so they can be unit-tested directly (see Tests/). `AudioPlayer` and
// the views call into these; the tests pin down their behavior.

/// Where a skip lands: within the current chapter, or in a neighbouring one.
enum SkipTarget: Equatable {
    case seek(Double)
    case chapter(index: Int, time: Double)
}

enum PlaybackMath {
    /// Overall progress from which a topic counts as listened to the end
    /// ("Start Over", hidden from "Continue", "Delete Finished").
    static let finishedFraction = 0.98

    static func isFinished(_ fraction: Double) -> Bool { fraction >= finishedFraction }

    /// Resolves a ±`seconds` skip from `time` in chapter `index`. Rewinding past a
    /// chapter's start continues into the end of the previous chapter; skipping
    /// past its end lands in the next one, walking on across as many chapters as
    /// the step spans. Only the topic's edges clamp. `currentDuration` is the
    /// playing chapter's real length (may differ from the page metadata in
    /// `durations`).
    static func skip(by seconds: Double, from time: Double, index: Int,
                     currentDuration: Double, durations: [Double]) -> SkipTarget {
        let target = time + seconds
        if target < 0, index > 0 {
            var i = index, t = target
            while t < 0, i > 0 {
                i -= 1
                t += durations[i]
            }
            return .chapter(index: i, time: max(t, 0))
        }
        if seconds > 0, currentDuration > 0, target >= currentDuration, index + 1 < durations.count {
            var i = index + 1, t = target - currentDuration
            // A chapter of unknown length (0) stops the walk rather than being skipped.
            while i + 1 < durations.count, durations[i] > 0, t >= durations[i] {
                t -= durations[i]
                i += 1
            }
            return .chapter(index: i, time: durations[i] > 0 ? min(t, durations[i]) : t)
        }
        let upper = currentDuration > 0 ? currentDuration : target
        return .seek(min(max(target, 0), upper))
    }

    /// Smart-rewind step after a break of `pause` seconds.
    static func rewind(afterPause pause: TimeInterval, enabled: Bool = true) -> Double {
        guard enabled else { return 0 }
        switch pause {
        case ..<30: return 0
        case ..<600: return 10
        case ..<3600: return 20
        default: return 30
        }
    }

    /// Chapter + position to start a topic at. `requested` is an explicitly tapped
    /// chapter (nil = resume). The saved time only applies to its own chapter, and
    /// gets the smart rewind for the time since it was saved.
    /// With `chapterCount`, an index outside the topic (chapters changed since the
    /// save) is pulled back into it and starts that chapter from its beginning.
    static func startPosition(requested: Int?, savedIndex: Int?, savedTime: Double?,
                              savedAt: Double?, now: Double, smartRewind: Bool,
                              chapterCount: Int? = nil) -> (index: Int, time: Double) {
        let wanted = requested ?? savedIndex ?? 0
        let index = chapterCount.map { min(max(wanted, 0), max($0 - 1, 0)) } ?? wanted
        guard index == wanted, savedIndex == index, let savedTime, savedTime > 0 else { return (index, 0) }
        var time = savedTime
        if let savedAt {
            time -= rewind(afterPause: now - savedAt, enabled: smartRewind)
        }
        return (index, max(0, time))
    }

    /// Overall topic progress (0…1) at `time` into chapter `index`.
    static func fraction(index: Int, time: Double, durations: [Double]) -> Double {
        let total = durations.reduce(0, +)
        guard total > 0 else { return 0 }
        let before = durations.prefix(index).reduce(0, +)
        return min(max((before + time) / total, 0), 1)
    }

    /// Total length of the chapters after `index`.
    static func after(index: Int, durations: [Double]) -> Double {
        index + 1 < durations.count ? durations[(index + 1)...].reduce(0, +) : 0
    }

    /// Real time left in the topic at `rate`: what's left of this chapter plus the
    /// chapters after it.
    static func bookRemaining(chapterLeft: Double, after: Double, rate: Float) -> Double {
        (after + max(chapterLeft, 0)) / Double(max(rate, 0.1))
    }
}

/// Playback speed rules: range, 0.05 grid, per-topic overrides over a default.
struct RateTopic: Equatable {
    static let range: ClosedRange<Float> = 0.5...3.0
    static let step: Float = 0.05

    var defaultRate: Float = 1.0
    /// Topic id → that topic's own speed.
    var perTopic: [String: Double] = [:]

    /// Clamps to the range and snaps to the 0.05 grid (no 1.2999…).
    static func normalized(_ r: Float) -> Float {
        let clamped = Double(min(max(r, range.lowerBound), range.upperBound))
        // Round in Double, then convert once: Float steps accumulate error
        // (1.3000001), which then fails to match the 1.3 preset.
        let steps = (1 / Double(step)).rounded()   // exactly 20, not 19.9999997
        return Float((clamped * steps).rounded() / steps)
    }

    func rate(for topicID: Int?) -> Float {
        guard let topicID, let own = perTopic[String(topicID)] else { return defaultRate }
        return Float(own)
    }

    func hasOwnRate(_ topicID: Int?) -> Bool {
        guard let topicID else { return false }
        return perTopic[String(topicID)] != nil
    }

    mutating func set(_ r: Float, for topicID: Int) {
        perTopic[String(topicID)] = Double(Self.normalized(r))
    }

    mutating func reset(_ topicID: Int) { perTopic[String(topicID)] = nil }
}

/// Recent search queries: newest first, de-duplicated case-insensitively, capped.
/// The search API needs at least this many characters (after trimming).
enum SearchQuery {
    static let minLength = 2
    static func trimmed(_ q: String) -> String { q.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func isSearchable(_ q: String) -> Bool { trimmed(q).count >= minLength }
}

struct SearchHistoryList: Equatable {
    static let limit = 15
    private(set) var items: [String]

    init(_ items: [String] = []) { self.items = Array(items.prefix(Self.limit)) }

    mutating func record(_ query: String) {
        guard SearchQuery.isSearchable(query) else { return }
        let q = SearchQuery.trimmed(query)
        items.removeAll { $0.compare(q, options: .caseInsensitive) == .orderedSame }
        items.insert(q, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    mutating func remove(_ query: String) { items.removeAll { $0 == query } }
}

/// Which chapters to fetch ahead while listening.
enum Prefetch {
    /// The next `count` chapter indices after `index` that aren't downloaded yet.
    static func next(after index: Int, count: Int, total: Int,
                     isDownloaded: (Int) -> Bool) -> [Int] {
        guard count > 0, index + 1 < total else { return [] }
        return ((index + 1)..<min(index + 1 + count, total)).filter { !isDownloaded($0) }
    }
}

/// "1.2 GB" / "350 MB" / "5.7 MB" for storage labels, decimal units as Files
/// counts them, with an English point whatever the phone's region.
func formatBytes(_ bytes: Int64) -> String {
    let value = Double(max(bytes, 0))
    for (size, unit) in [(1e9, "GB"), (1e6, "MB")] where value >= size {
        let n = value / size
        return "\(decimalFormatter(n < 100 ? 1 : 0).string(from: NSNumber(value: n)) ?? "\(n)") \(unit)"
    }
    return "\(Int((value / 1e3).rounded())) KB"
}

private func decimalFormatter(_ fractionDigits: Int) -> NumberFormatter {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    f.maximumFractionDigits = fractionDigits
    return f
}

/// "34%".
func formatPercent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

/// "1,486", grouped the English way whatever the phone's region.
func formatNumber(_ n: Int) -> String { numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

private let numberFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US")
    f.numberStyle = .decimal
    return f
}()

/// "1 topic" / "1,486 topics".
func formatCount(_ n: Int, _ singular: String, _ plural: String) -> String {
    "\(formatNumber(n)) \(n == 1 ? singular : plural)"
}

/// Human-readable length for remaining-time labels: "6 h 20 min", "45 min",
/// "under a minute".
func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
    let total = Int(seconds) / 60
    let h = total / 60, m = total % 60
    if h == 0 { return "\(m) min" }
    return m == 0 ? "\(h) h" : "\(h) h \(m) min"
}
