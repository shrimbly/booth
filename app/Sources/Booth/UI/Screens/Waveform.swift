import BoothCore
import SwiftUI

/// The Done screen's 56-bar waveform. Bars left of the playhead are drawn in `text` (`text2`
/// while comparing), the rest in `wave`; over the picture, white and dimmed white instead. Click
/// or drag to seek.
///
/// The playhead moves 30 times a second while playing, but a bar changes colour only once per
/// 56th of the clip, so the waveform is equatable on what it draws and reads out: `playedBars`
/// and `percent` rather than the playhead itself.
struct Waveform: View, Equatable {
    /// Normalised levels from `WaveformBars.levels`.
    let levels: [Double]
    /// How many bars, from the first, are left of the playhead (`playedBars(playhead:count:)`).
    let playedBars: Int
    /// The playhead in whole percent, for VoiceOver.
    let percent: Int
    let isComparing: Bool
    /// Drawn over the video, on its dark scrim.
    var onPicture = false
    /// The playhead now, for VoiceOver's adjustments.
    let playhead: () -> Double
    let onSeek: (Double) -> Void

    /// The bars left of `playhead`: those with `index / count < playhead`, which always run
    /// from the first.
    static func playedBars(playhead: Double, count: Int) -> Int {
        var played = 0
        while played < count && Double(played) / Double(count) < playhead { played += 1 }
        return played
    }

    /// Alike when they draw and read out alike; the closures always act on the same model.
    static func == (a: Waveform, b: Waveform) -> Bool {
        a.levels == b.levels && a.playedBars == b.playedBars && a.percent == b.percent
            && a.isComparing == b.isComparing && a.onPicture == b.onPicture
    }

    @Environment(\.theme) private var theme

    static let height = CGFloat(WaveformBars.minHeight + WaveformBars.maxExtra)

    var body: some View {
        // Read here, not in the GeometryReader's closure, so a light/dark switch redraws the
        // bars although `==` leaves the theme out.
        let theme = theme
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(forBar: index, theme: theme))
                        // Whole points, like the mockup's Math.round, keep bars crisp.
                        .frame(height: WaveformBars.height(forLevel: levels[index]).rounded())
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard proxy.size.width > 0 else { return }
                onSeek(min(1, max(0, drag.location.x / proxy.size.width)))
            })
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(percent)%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(1, playhead() + 0.05))
            case .decrement: onSeek(max(0, playhead() - 0.05))
            @unknown default: break
            }
        }
    }

    private func color(forBar index: Int, theme: Theme) -> Color {
        let isPlayed = index < playedBars
        if onPicture {
            guard isPlayed else { return .white.opacity(0.4) }
            return .white.opacity(isComparing ? 0.7 : 1)
        }
        guard isPlayed else { return theme.wave }
        return isComparing ? theme.text2 : theme.text
    }
}
