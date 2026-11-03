import Foundation

/// The Working bar's glide between the engine's progress updates. Each change plays out
/// linearly over `seconds`, and changes that overlap add up, the way SwiftUI runs a new linear
/// animation alongside the one it interrupts.
public struct ProgressGlide: Sendable {
    public let seconds: Double
    private var steps: [Step] = []

    private struct Step: Sendable {
        var start: Date
        var change: Double
    }

    public init(seconds: Double) {
        self.seconds = seconds
    }

    /// Progress moved by `change` at `time`.
    public mutating func add(_ change: Double, at time: Date) {
        steps.removeAll { time.timeIntervalSince($0.start) >= seconds }
        if change != 0 { steps.append(Step(start: time, change: change)) }
    }

    /// Where the bar is at `time` on its way to `target`.
    public func value(target: Double, at time: Date) -> Double {
        steps.reduce(target) { value, step in
            let done = min(1, max(0, time.timeIntervalSince(step.start) / seconds))
            return value - step.change * (1 - done)
        }
    }
}
