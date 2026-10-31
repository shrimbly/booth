import AppKit
import QuartzCore

/// A CSS `cubic-bezier()` timing curve, solved the way browsers solve it (WebKit's UnitBezier),
/// so motion ported from the mockups keeps its overshoot.
struct CubicBezier: Equatable {
    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// Main.dc.html: the menu bar button's `transform 240ms cubic-bezier(.34,1.56,.64,1)`.
    static let iconSpring = CubicBezier(0.34, 1.56, 0.64, 1)
    /// An even ease in and out, for one state dissolving into another.
    static let inOut = CubicBezier(0.45, 0, 0.55, 1)
    /// CSS `ease`, for fades and colour changes.
    static let cssEase = CubicBezier(0.25, 0.1, 0.25, 1)
    /// A strong ease-out for UI that answers an action: it moves most of the way at once, so
    /// the response shows the moment you act.
    static let easeOut = CubicBezier(0.23, 1, 0.32, 1)

    /// The curve's output for `progress` (0…1) along the time axis.
    func value(at progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        return sampleY(solveT(forX: progress))
    }

    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    // Each axis is a cubic polynomial a·t³ + b·t² + c·t with endpoints fixed at 0 and 1.
    private var cx: Double { 3 * x1 }
    private var bx: Double { 3 * (x2 - x1) - cx }
    private var ax: Double { 1 - cx - bx }
    private var cy: Double { 3 * y1 }
    private var by: Double { 3 * (y2 - y1) - cy }
    private var ay: Double { 1 - cy - by }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    /// Newton's method first (fast, nearly always enough), bisection as the fallback.
    private func solveT(forX x: Double) -> Double {
        let epsilon = 1e-6
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < epsilon { return t }
            let slope = slopeX(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0
        var high = 1.0
        t = x
        while low < high {
            let sample = sampleX(t)
            if abs(sample - x) < epsilon { return t }
            if x > sample { low = t } else { high = t }
            t = (low + high) / 2
            if high - low < epsilon { break }
        }
        return t
    }
}

/// A value easing towards a target along a curve; retargeting starts from wherever it is now,
/// like a CSS transition interrupted mid-flight.
struct Transition {
    private(set) var target: Double
    private var origin: Double
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private let curve: CubicBezier

    init(_ value: Double, curve: CubicBezier) {
        target = value
        origin = value
        self.curve = curve
    }

    func value(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return target }
        let progress = min(1, max(0, (time - startTime) / duration))
        return origin + (target - origin) * curve.value(at: progress)
    }

    func isSettled(at time: CFTimeInterval) -> Bool {
        duration <= 0 || time - startTime >= duration
    }

    mutating func retarget(_ newTarget: Double, duration newDuration: CFTimeInterval, at time: CFTimeInterval) {
        guard newTarget != target else { return }
        origin = value(at: time)
        target = newTarget
        startTime = time
        duration = newDuration
    }
}

enum Motion {
    /// System Settings → Accessibility → Display → Reduce motion.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension NSAppearance {
    /// Dark and vibrant-dark appearances (the menu bar over a dark wallpaper reports the latter).
    var isDark: Bool {
        switch bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) {
        case .darkAqua?, .vibrantDark?: true
        default: false
        }
    }
}
