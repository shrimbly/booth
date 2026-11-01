import Foundation

/// Where Booth's menu bar icon goes the first time it appears: fourth from the right, after the
/// clock, Control Centre and the three icons nearest them. macOS adds a new icon at the left end
/// of the others instead, which on a full menu bar is behind the camera housing or off the screen.
///
/// macOS orders the icons by a preferred position each app keeps for its own: in points from the
/// screen's right edge less `inset`, where the icon was when macOS last placed it. An icon whose
/// position ties with another's goes to its left. Booth can't read the others' positions, only
/// see where the icons are, so it guesses from that and then corrects (`Search`).
public enum MenuBarPlacement {
    /// The clock and Control Centre, always the two at the right.
    public static let fixedIcons = 2
    /// Icons left between Booth and Control Centre.
    public static let iconsBefore = 3
    /// Measured on macOS 26: an icon whose right edge is 268 points in from the edge keeps 250.
    public static let inset = 18.0

    /// The preferred position that puts a new icon after `iconsBefore` of the movable icons,
    /// given the icons now in the menu bar (left and right edges, in points from the screen's
    /// left) and the screen's right edge. It aims at the middle of the last icon to pass, so a
    /// few points' error either way still lands between it and the next. Nil when there are no
    /// movable icons to go after: then the right end is as good as any.
    public static func preferredPosition(icons: [(minX: Double, maxX: Double)], screenMaxX: Double) -> Double? {
        let movable = icons.sorted { $0.maxX > $1.maxX }.dropFirst(fixedIcons)
        guard let last = movable.prefix(iconsBefore).last else { return nil }
        return max(0, screenMaxX - (last.minX + last.maxX) / 2 - inset)
    }

    /// Settling the icon once it is drawn. The other icons' positions are from wherever macOS
    /// last placed them, and one that has since slid along when an icon to its right went away
    /// still has its old one, so the first guess can land an icon off by one. Each try reports how
    /// many movable icons ended up on the icon's right; the next moves it the rest of the way, and
    /// halves the gap once it has been on both sides.
    public struct Search: Equatable, Sendable {
        public private(set) var position: Double
        /// The largest position that left the icon too far right, and the smallest too far left.
        private var tooFarRight: Double?
        private var tooFarLeft: Double?
        private var tries = 0
        public static let maxTries = 8
        /// About one icon's width.
        public static let step = 24.0

        public init(position: Double) {
            self.position = position
        }

        /// The next position to try after the icon settled with `count` movable icons on its right,
        /// of `available` in all; nil once it has the right number (all of them, when there are
        /// fewer than `iconsBefore`), or after `maxTries`.
        public mutating func next(iconsToTheRight count: Int, available: Int) -> Double? {
            let wanted = min(iconsBefore, available)
            guard count != wanted else { return nil }
            tries += 1
            guard tries < Self.maxTries else { return nil }
            if count < wanted {
                tooFarRight = max(tooFarRight ?? position, position)
            } else {
                tooFarLeft = min(tooFarLeft ?? position, position)
            }
            if let low = tooFarRight, let high = tooFarLeft {
                guard high - low > 1 else { return nil }
                position = (low + high) / 2
            } else {
                position = max(0, position + Double(wanted - count) * Self.step)
            }
            return position
        }
    }
}
