import BoothCore
import SwiftUI

/// Downloading the voice models, waiting for a slow engine to answer (often a macOS folder
/// access prompt), or the failure that stopped either.
struct FirstRunScreen: View {
    let model: AppModel

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = model.setupFailureMessage {
                ScreenTitle(Formatting.setupFailedTitle)
                Paragraph(failure).padding(.top, 3)
            } else if let waiting = model.setupWaitingText {
                // Nothing is downloading and there is no progress to show, so no bar.
                ScreenTitle(Formatting.engineWaitingTitle)
                Paragraph(waiting).padding(.top, 3)
            } else {
                ScreenTitle("Setting up")
                Paragraph("Booth downloads its voice models once. After that, everything runs on this Mac and nothing is uploaded.")
                    .padding(.top, 3)
                ProgressBar(fraction: model.setup.fraction, accessibilityLabel: "Setup progress")
                    .padding(.top, 12)
                HStack(spacing: 8) {
                    SecondaryLine(model.setupBytesText ?? "")
                    Spacer(minLength: 0)
                    SecondaryLine(model.setupTimeLeftText ?? "")
                }
                .padding(.top, 6)
            }
        }
    }
}

struct FirstRunFooter: View {
    let model: AppModel

    var body: some View {
        if model.setupFailureMessage != nil {
            Button("Try again", action: model.retrySetup)
                .buttonStyle(PillButtonStyle())
                .footerInset(.pill)
        } else {
            Button("Run in background", action: model.runSetupInBackground)
                .buttonStyle(TextActionButtonStyle(tone: .primary, weight: .medium))
                .footerInset(.text)
        }
    }
}
