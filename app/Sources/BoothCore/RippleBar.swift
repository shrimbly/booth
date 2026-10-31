import Foundation

/// The Working screen's ripple bar (WorkingSound.dc.html, option J). The whole popover is the
/// progress bar: the fill spreads from the left like sound from a speaker, faint rings leave
/// the source in bursts and spread through it, and one faint ring runs ahead of it.
///
/// Distances are in points on a bar 56 pt tall; times are milliseconds on a free-running clock.
public enum RippleBar {
    public static let height = 56.0
    /// The rings' shared centre: just off the bar's left edge, at mid-height.
    public static let sourceX = -20.0
    public static let midY = 28.0
    /// At most one ring leaves the source in each slot this long.
    public static let slotMilliseconds = 240.0
    /// Slots looked back over: enough for a ring to cross the whole bar.
    public static let slots = 46
    /// How fast rings travel outward, in points per millisecond.
    public static let ringSpeed = 0.03
    /// The faint ring ahead of the fill leaves the front this often.
    public static let leadMilliseconds = 1800.0
    /// The fill's edge is blurred by this radius.
    public static let fillSoftness = 2.5
    /// The rings are blurred by this radius.
    public static let ringSoftness = 0.6

    /// An ellipse about (`sourceX`, `midY`).
    public struct Ring: Equatable, Sendable {
        public var rx: Double
        public var ry: Double
        public var alpha: Double
        public var lineWidth: Double
        /// A faint wide band of pressure drawn around the hairline.
        public var bandWidth: Double
        public var bandAlpha: Double
        /// Stable for the ring's life, so its waver keeps its own shape as it spreads.
        public var seed: Int
    }

    /// The fill's horizontal radius: it reaches the front at mid-height.
    public static func fillRadius(front: Double) -> Double {
        front - sourceX
    }

    /// Rings are flatter than circles, so the wavefront bulges forward.
    public static func verticalRadius(_ rx: Double) -> Double {
        0.5 * rx + 14
    }

    /// The rings inside a fill whose front is at `front`. Each slot may send out a ring at its
    /// own moment within the slot, as strong as the voice was then. Loud passages send most
    /// slots' rings and quiet ones few, so rings come in bursts and never sit evenly spaced.
    /// Each eases in at the source and fades as it spreads.
    public static func rings(milliseconds t: Double, front: Double) -> [Ring] {
        let fill = fillRadius(front: front)
        let slot = (t / slotMilliseconds).rounded(.down)
        var rings: [Ring] = []
        for n in 0..<slots {
            let k = slot - Double(n)
            let left = (k + 0.15 + 0.7 * noise(k, 7)) * slotMilliseconds
            let r = (t - left) * ringSpeed
            let level = 0.25 + 0.75 * speech(k * 23.3 + 300)
            guard noise(k, 3) < 0.2 + 0.6 * level, r > 0.1, r < fill - 8 else { continue }
            let strength = level * pow(1 - r / fill, 0.8) * smoothstep(0, 12, r)
            rings.append(Ring(
                rx: r, ry: verticalRadius(r),
                alpha: 0.22 * strength, lineWidth: 0.6 + level,
                bandWidth: 4 + 8 * level, bandAlpha: 0.06 * strength,
                seed: Int(k)))
        }
        return rings
    }

    /// The faint ring that leaves the front and fades as it travels ahead.
    public static func leadRing(milliseconds t: Double, front: Double) -> Ring {
        let phase = max(0, t).truncatingRemainder(dividingBy: leadMilliseconds) / leadMilliseconds
        let r = fillRadius(front: front) + 4 + 22 * phase
        return Ring(rx: r, ry: verticalRadius(r), alpha: 0.28 * (1 - phase), lineWidth: 1.4, bandWidth: 0, bandAlpha: 0, seed: 0)
    }

    /// How far a ring wavers sideways at height `y`: about ±2 pt, drifting over time.
    public static func waver(y: Double, seed: Int, milliseconds t: Double) -> Double {
        let s = Double(seed % 997)
        return 1.4 * sin(y * 0.13 + t * 0.0011 + s * 1.7) + 0.9 * sin(y * 0.29 - t * 0.0016 + s * 2.9)
    }

    /// A speech-like level, 0–1, at position `u`: words, syllables inside them, and pauses between.
    public static func speech(_ u: Double) -> Double {
        let words = abs(sin(u * 0.061) * sin(u * 0.017 + 1.3))
        let syllables = 0.55 + 0.45 * sin(u * 0.19 + 2 * sin(u * 0.05))
        let pause = sin(u * 0.0093 + 0.6) > -0.55 ? 1.0 : 0.08
        return min(1, words * syllables * 1.7 * pause)
    }

    /// Repeatable noise, 0–1, for sample `i` of stream `stream`.
    static func noise(_ i: Double, _ stream: Double) -> Double {
        let v = sin(i * 12.9898 + stream * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let k = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return k * k * (3 - 2 * k)
    }
}

/// How a text layer fades as the fill's front passes: alpha against the distance from the
/// front in points (negative behind it, inside the fill), linear between points and held
/// beyond the ends.
public struct FrontFade: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var distance: Double
        public var alpha: Double
    }

    /// A gradient stop across the bar: `location` 0 (left edge) to 1 (right edge).
    public struct Stop: Equatable, Sendable {
        public var location: Double
        public var alpha: Double
    }

    /// In order of distance.
    public let points: [Point]

    public init(_ points: [(distance: Double, alpha: Double)]) {
        self.points = points.map { Point(distance: $0.distance, alpha: $0.alpha) }
    }

    public func alpha(at distance: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if distance <= first.distance { return first.alpha }
        if distance >= last.distance { return last.alpha }
        for (a, b) in zip(points, points.dropFirst()) where distance <= b.distance {
            return a.alpha + (b.alpha - a.alpha) * (distance - a.distance) / (b.distance - a.distance)
        }
        return last.alpha
    }

    /// Stops for a bar `width` wide with the front at `front`, kept inside the bar: the
    /// fade's points that fall within it, plus its two edges.
    public func stops(front: Double, width: Double) -> [Stop] {
        guard width > 0 else { return [Stop(location: 0, alpha: alpha(at: -front))] }
        let inside = points.map { front + $0.distance }.filter { $0 > 0 && $0 < width }
        return ([0] + inside + [width]).map { x in
            Stop(location: x / width, alpha: alpha(at: x - front))
        }
    }
}

/// The Working bar's text: percent on the left, the file name on the right. The name stays out
/// of focus until the front reaches it, turns pale as it crosses, and only then comes into
/// focus, in steps, inside the fill. Percent and × simply turn pale as they cross.
public enum WorkingText {
    /// Percent and × in the text colour, ahead of the front.
    public static let marks = FrontFade([(-4, 0), (8, 1)])
    /// Percent and × in the on-fill colour, behind the front.
    public static let marksOnFill = FrontFade([(-4, 1), (8, 0)])

    /// One drawing of the name. The layers' alphas add up to 1 at every distance.
    public struct NameLayer: Equatable, Sendable {
        public var fade: FrontFade
        /// Gaussian blur radius in points.
        public var blur: Double
        public var opacity: Double
        /// Drawn in the on-fill colour rather than the text colour.
        public var onFill: Bool
    }

    public static let nameLayers: [NameLayer] = [
        NameLayer(fade: FrontFade([(-4, 0), (8, 1)]), blur: 2.6, opacity: 0.75, onFill: false),
        NameLayer(fade: FrontFade([(-30, 0), (-16, 1), (-4, 1), (8, 0)]), blur: 2.6, opacity: 0.85, onFill: true),
        NameLayer(fade: FrontFade([(-48, 0), (-34, 1), (-30, 1), (-16, 0)]), blur: 1, opacity: 1, onFill: true),
        NameLayer(fade: FrontFade([(-48, 1), (-34, 0)]), blur: 0, opacity: 1, onFill: true),
    ]
}
