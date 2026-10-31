import BoothCore
import SwiftUI

/// The 3 pt progress bar used by Working and First run: `track` well, work-blue fill.
///
/// Progress arrives about four times a second, so the fill glides forward between updates. It
/// never glides back: a fall (a new job, a retried download) shows at once.
struct ProgressBar: View {
    let fraction: Double
    var accessibilityLabel = "Progress"

    @Environment(\.theme) private var theme
    /// The fraction last drawn, to tell a step forward from a fall.
    @State private var drawnFraction: Double?

    var body: some View {
        let clamped = min(1, max(0, fraction))
        let isForward = clamped >= (drawnFraction ?? clamped)
        Capsule()
            .fill(theme.track)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.work)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .frame(height: 3)
            .animation(isForward ? PopoverMotion.progress : nil, value: clamped)
            .onChange(of: clamped, initial: true) { _, newValue in drawnFraction = newValue }
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(Formatting.percent(clamped))%")
    }
}
