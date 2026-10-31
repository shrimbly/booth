import Foundation

/// A spring's progress from 0 to 1, set by feel the way SwiftUI and Core Animation set one: a
/// perceptual duration and a bounce (0 for none). Stiffness (2π / duration)², damping
/// 4π (1 − bounce) / duration, unit mass, starting at rest.
public struct SpringCurve: Equatable, Sendable {
    public let perceptualDuration: Double
    public let bounce: Double

    public init(perceptualDuration: Double, bounce: Double) {
        self.perceptualDuration = perceptualDuration
        self.bounce = bounce
    }

    public func value(at seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let omega = 2 * .pi / perceptualDuration
        let zeta = 1 - bounce
        guard zeta < 1 else { return 1 - (1 + omega * seconds) * exp(-omega * seconds) }
        let decay = zeta * omega
        let damped = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-decay * seconds) * (cos(damped * seconds) + decay / damped * sin(damped * seconds))
    }
}

/// The popover opening: it drops `lift` points into place and grows from `startScale` on
/// `spring`, about a pivot on its top edge under the menu bar icon.
public enum PanelOpening {
    public static let startScale = 0.95
    public static let lift = 6.0
    public static let spring = SpringCurve(perceptualDuration: 0.32, bounce: 0.12)

    /// The panel's scale, and how far above its resting place it is, `seconds` into opening.
    public static func pose(at seconds: Double) -> (scale: Double, lift: Double) {
        let x = spring.value(at: seconds)
        return (startScale + (1 - startScale) * x, lift * (1 - x))
    }

    /// The offset, in the panel's own coordinates (y down), that keeps `point` where it will rest
    /// on screen while the panel opens around `pivot`: it cancels the panel's drift there.
    public static func steadying(
        _ point: (x: Double, y: Double), pivot: (x: Double, y: Double), at seconds: Double
    ) -> (x: Double, y: Double) {
        let pose = pose(at: seconds)
        // Left alone, the point is drawn at pivot + scale × (point − pivot), lifted.
        let driftX = (pose.scale - 1) * (point.x - pivot.x)
        let driftY = (pose.scale - 1) * (point.y - pivot.y) - pose.lift
        return (-driftX / pose.scale, -driftY / pose.scale)
    }
}

/// The "Booth" signature coming forward through fog as the popover opens (BoothReveal.dc.html,
/// "Fog bank"). Each letter starts `stagger` after the one before. It comes forward from `depth`
/// points back (drawn smaller, as through a `perspective`), clears from `startBlur`, fades up and
/// rises `rise` points into place; a haze over the corner thins behind it.
public enum SignatureReveal {
    /// After the popover starts to open.
    public static let delay = 0.040
    public static let duration = 0.550
    /// The ease out: 1 − (1 − x)^power. Higher reaches most of the way sooner and settles longer.
    public static let easePower = 3.5
    public static let depth = 100.0
    public static let perspective = 800.0
    /// Points below its resting place, on screen, as each letter starts to rise.
    public static let rise = 8.0
    public static let riseDelay = 0.030
    public static let riseDuration = 0.400
    public static let riseEasePower = 3.0
    public static let startBlur = 23.0
    /// The blur clears as (1 − nearness)^falloff: above 1 it clears ahead of the depth.
    public static let blurFalloff = 1.6
    /// The ink fades up this many times faster than the letter comes forward.
    public static let fadeSpeed = 1.9
    public static let stagger = 0.030
    /// The haze: its densest alpha, its softness (blur), when it starts thinning and for how long,
    /// as shares of `duration`.
    public static let haze = 0.95
    public static let hazeSoftness = 23.0
    public static let hazeLag = 0.15
    public static let hazeLength = 0.95

    /// One letter's part in the reveal, laid over how the letter otherwise looks.
    public struct Letter: Equatable, Sendable {
        /// Drawn size, 1 at rest.
        public var scale: Double
        /// Points below its resting place, on screen.
        public var drop: Double
        /// Blur added to the letter's own.
        public var extraBlur: Double
        /// Multiplies the letter's ink.
        public var alpha: Double

        public static let rest = Letter(scale: 1, drop: 0, extraBlur: 0, alpha: 1)
    }

    /// When every letter and the haze have settled.
    public static var seconds: Double {
        let lastStart = Double(SignatureWave.letters.count - 1) * stagger
        return max(delay + lastStart + duration, riseDelay + lastStart + riseDuration, delay + (hazeLag + hazeLength) * duration)
    }

    /// Each of `count` letters, `seconds` after the popover started to open. With reduced motion
    /// the letters still clear and fade up in turn, but neither come forward nor rise.
    public static func letters(at seconds: Double, count: Int = SignatureWave.letters.count, reduceMotion: Bool) -> [Letter] {
        (0..<count).map { index in
            let lag = Double(index) * stagger
            let progress = clamp01((seconds - delay - lag) / duration)
            let near = ease(progress, easePower)
            let lifting = clamp01((seconds - riseDelay - lag) / riseDuration)
            return Letter(
                scale: reduceMotion ? 1 : perspective / (perspective + depth * (1 - near)),
                drop: reduceMotion ? 0 : rise * pow(1 - lifting, riseEasePower),
                extraBlur: (startBlur - SignatureWave.restingBlur) * pow(1 - near, blurFalloff),
                alpha: ease(clamp01(progress * fadeSpeed), easePower))
        }
    }

    /// How dense the haze is `seconds` after the popover started to open: 1 until it starts to
    /// thin, then smoothly gone.
    public static func hazeOpacity(at seconds: Double) -> Double {
        let thinning = clamp01((seconds - delay - hazeLag * duration) / (hazeLength * duration))
        return 1 - thinning * thinning * (3 - 2 * thinning)
    }

    private static func ease(_ x: Double, _ power: Double) -> Double {
        1 - pow(1 - x, power)
    }

    private static func clamp01(_ x: Double) -> Double {
        min(1, max(0, x))
    }
}
