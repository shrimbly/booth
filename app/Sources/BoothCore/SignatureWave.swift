import Foundation

/// How one letter of the "Booth" signature is inked.
public enum SignatureInk: Equatable, Sendable {
    /// `rgba(sigRgb, alpha)`.
    case resting(alpha: Double)
    /// The theme's `sigOver` colour, used while a file is over the popover.
    case over
}

public struct SignatureLetterStyle: Equatable, Sendable {
    public var character: Character
    /// Gaussian blur radius in points (CSS `filter: blur(px)`).
    public var blur: Double
    public var ink: SignatureInk

    public init(character: Character, blur: Double, ink: SignatureInk) {
        self.character = character
        self.blur = blur
        self.ink = ink
    }
}

/// The signature's soft focus and the focus wave that runs across it while a file is in the
/// booth. A direct port of Popover.dc.html (SPEC §3.4).
public enum SignatureWave {
    public static let letters: [Character] = ["B", "o", "o", "t", "h"]
    /// One pass plus a short rest.
    public static let waveMilliseconds = 4200.0
    /// How far the crest reaches either side, in word widths.
    public static let waveWidth = 0.7
    public static let restingBlur = 1.5
    public static let restingAlpha = 0.40
    public static let crestAlphaBoost = 0.24

    /// Whether the view needs a running clock for the Working wave.
    public static func isAnimating(screen: PopoverScreen, dropHover: Bool, reduceMotion: Bool) -> Bool {
        screen == .working && !isOver(screen: screen, dropHover: dropHover) && !reduceMotion
    }

    /// Per-letter blur and ink at `milliseconds` on a free-running clock.
    public static func styles(
        milliseconds: Double, progress: Double, screen: PopoverScreen, dropHover: Bool, reduceMotion: Bool
    ) -> [SignatureLetterStyle] {
        let over = isOver(screen: screen, dropHover: dropHover)
        let waving = isAnimating(screen: screen, dropHover: dropHover, reduceMotion: reduceMotion)
        let progress = min(1, max(0, progress))
        // The resting blur eases off as progress grows.
        let rest = over ? 0 : restingBlur * (screen == .working ? 1 - 0.6 * progress : 1)
        // The crest eases in and out across 85% of the cycle, then rests before the next pass.
        let phase = milliseconds.truncatingRemainder(dividingBy: waveMilliseconds) / waveMilliseconds
        let u = min(1, max(0, phase) / 0.85)
        let crest = -waveWidth + (1 + 2 * waveWidth) * (0.5 - 0.5 * cos(.pi * u))
        let last = Double(letters.count - 1)

        return letters.enumerated().map { index, character in
            let distance = waving ? min(1, abs(Double(index) / last - crest) / waveWidth) : 1
            let k = 0.5 + 0.5 * cos(.pi * distance)
            return SignatureLetterStyle(
                character: character,
                blur: rest * (1 - k),
                ink: over ? .over : .resting(alpha: restingAlpha + crestAlphaBoost * k))
        }
    }

    /// Every screen but Settings takes drops, so only those light the signature up.
    private static func isOver(screen: PopoverScreen, dropHover: Bool) -> Bool {
        dropHover && screen != .settings
    }
}

/// The pointer resting on the name brings only the letters right around it partly into focus:
/// a soft round patch that follows the pointer and never sharpens fully.
public enum PointerFocus {
    /// How far from the pointer the focus reaches, in points.
    public static let reach = 34.0
    /// The blur right under the pointer: most of the resting blur goes, never all of it.
    public static let blur = 0.6
    /// The ink right under the pointer, a little darker than at rest.
    public static let alpha = SignatureWave.restingAlpha + 0.1

    /// How focused the name is `distance` points from the pointer: 1 under it, easing to 0 at
    /// `reach`.
    public static func amount(atDistance distance: Double) -> Double {
        let u = min(1, max(0, distance / reach))
        return 0.5 + 0.5 * cos(.pi * u)
    }

    /// `resting` as it looks right under the pointer. A file over the popover already sharpens
    /// the whole name, so then nothing changes.
    public static func styles(_ resting: [SignatureLetterStyle]) -> [SignatureLetterStyle] {
        resting.map { letter in
            guard case .resting(let restingAlpha) = letter.ink else { return letter }
            return SignatureLetterStyle(
                character: letter.character, blur: min(letter.blur, blur), ink: .resting(alpha: max(restingAlpha, alpha)))
        }
    }

    /// Stops for a radial mask out to `reach`: the focused drawing's alpha at each fraction of the
    /// way out, scaled by `strength` as the focus fades in and out.
    public static func stops(strength: Double, count: Int = 9) -> [(location: Double, alpha: Double)] {
        let strength = min(1, max(0, strength))
        return (0..<count).map { i in
            let location = Double(i) / Double(count - 1)
            return (location, strength * amount(atDistance: location * reach))
        }
    }
}
