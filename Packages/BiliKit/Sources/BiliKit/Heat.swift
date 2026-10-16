import Foundation

/// 高能进度条: how many comments were sent at each moment of a video, sampled every `step` seconds.
/// Bilibili's own `/pbp/data` endpoint is gone (404 since 2026), so the curve is counted from the danmaku segments.
public struct HeatCurve: Sendable, Equatable {
    public var step: Double
    public var values: [Double]

    public init(step: Double, values: [Double]) {
        self.step = step
        self.values = values
    }

    /// Values scaled to 0…1, lightly smoothed so single spikes don't dominate the curve.
    public var normalized: [Double] {
        guard !values.isEmpty else { return [] }
        let smoothed = values.indices.map { i -> Double in
            let window = values[max(0, i - 1) ... min(values.count - 1, i + 1)]
            return window.reduce(0, +) / Double(window.count)
        }
        let top = smoothed.max() ?? 0
        return top > 0 ? smoothed.map { $0 / top } : smoothed.map { _ in 0 }
    }

    /// The `count` busiest moments (seconds, in time order), at least `spacing` seconds apart and well above the
    /// video's typical level, so a flat curve yields none.
    public func highlights(count: Int = 3, spacing: Double = 30, duration: Double? = nil) -> [Double] {
        let curve = normalized
        guard !curve.isEmpty else { return [] }
        let median = curve.sorted()[curve.count / 2]
        var picked: [Double] = []
        for i in curve.indices.sorted(by: { curve[$0] > curve[$1] }) {
            guard picked.count < count else { break }
            let value = curve[i]
            guard value >= 0.5, value >= median * 1.6 + 0.05 else { break }
            // Start a little before the busiest sample so the moment itself is seen.
            let time = max(0, Double(i) * step - step)
            if let duration, time >= duration - 5 { continue }
            if picked.allSatisfy({ abs($0 - time) >= spacing }) { picked.append(time) }
        }
        return picked.sorted()
    }
}

/// Counts comment times into a heat curve as danmaku segments arrive (each segment once).
public struct HeatCounter: Sendable {
    public let duration: Double
    public let step: Double
    private var bins: [Double]
    private var counted: Set<Int> = []
    private var total = 0

    /// Comments needed before the curve says anything.
    static let minimumComments = 40

    public init(duration: Double) {
        self.duration = max(1, duration)
        // About 240 samples, 2–10 s each.
        step = min(10, max(2, (self.duration / 240).rounded()))
        bins = Array(repeating: 0, count: Int((self.duration / step).rounded(.up)))
    }

    /// Segments (1-based, 6 minutes each) a full curve needs.
    public var segmentCount: Int { DanmakuTimeline.segment(for: duration - 0.001) }

    public var isComplete: Bool { (1 ... segmentCount).allSatisfy(counted.contains) }

    /// Adds one segment's comment times; a segment seen before is ignored. Returns whether anything changed.
    @discardableResult
    public mutating func add(segment: Int, times: [Double]) -> Bool {
        guard counted.insert(segment).inserted else { return false }
        for t in times where t >= 0 && t < duration {
            bins[min(bins.count - 1, Int(t / step))] += 1
        }
        total += times.count
        return true
    }

    /// The curve so far; nil while there are too few comments to show a shape.
    public var curve: HeatCurve? {
        guard total >= Self.minimumComments, !bins.isEmpty, bins.contains(where: { $0 > 0 }) else { return nil }
        return HeatCurve(step: step, values: bins)
    }
}
