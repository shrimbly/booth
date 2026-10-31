import BoothCore
import SwiftUI

/// The Done screen's 56-bar waveform. Bars left of the playhead are drawn in `text` (`text2`
/// while comparing), the rest in `wave`; over the picture, white and dimmed white instead. Click
/// or drag to seek.
struct Waveform: View {
    /// Normalised levels from `WaveformBars.levels`.
    let levels: [Double]
    let playhead: Double
    let isComparing: Bool
    /// Drawn over the video, on its dark scrim.
    var onPicture = false
    let onSeek: (Double) -> Void

    @Environment(\.theme) private var theme

    static let height = CGFloat(WaveformBars.minHeight + WaveformBars.maxExtra)

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(forBar: index))
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
        .accessibilityValue("\(Formatting.percent(playhead))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(1, playhead + 0.05))
            case .decrement: onSeek(max(0, playhead - 0.05))
            @unknown default: break
            }
        }
    }

    private func color(forBar index: Int) -> Color {
        let isPlayed = Double(index) / Double(levels.count) < playhead
        if onPicture {
            guard isPlayed else { return .white.opacity(0.4) }
            return .white.opacity(isComparing ? 0.7 : 1)
        }
        guard isPlayed else { return theme.wave }
        return isComparing ? theme.text2 : theme.text
    }
}
