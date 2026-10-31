import BoothCore
import SwiftUI

/// Engine, three switches and the shortcut. The only screen that takes no drops.
struct SettingsScreen: View {
    let model: AppModel

    @Environment(\.theme) private var theme

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
                IconButton(icon: .back, iconSize: 15, label: "Back", action: model.back)
                Text("Settings")
                    .textStyle(.title)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, -2)
            .padding(.leading, -7)

            SegmentedControl(
                options: EngineChoice.allCases, selection: settings.engine, title: \.label,
                accessibilityLabel: "Engine", onSelect: model.setEngine)
                .padding(.top, 10)
            Text(settings.engine.note)
                .textStyle(.secondary)
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(spacing: 0) {
                SettingsRow("Keep the original video") {
                    BoothSwitch(label: "Keep the original video", isOn: settings.keepVideo, onToggle: model.setKeepVideo)
                }
                SettingsRow("Skip music separation") {
                    BoothSwitch(label: "Skip music separation", isOn: settings.noSplit, onToggle: model.setNoSplit)
                }
                SettingsRow("Open at login") {
                    BoothSwitch(label: "Open at login", isOn: settings.openAtLogin, onToggle: model.setOpenAtLogin)
                }
                SettingsRow("Enhance selected files", hasBottomRule: true) {
                    Text("⌃⌥E")
                        .textStyle(.action)
                        .tracking(0.08 * 12)
                        .foregroundStyle(theme.text2)
                        .accessibilityLabel("Control Option E")
                }
            }
            .padding(.top, 6)
        }
    }
}

struct SettingsFooter: View {
    let model: AppModel

    @Environment(\.theme) private var theme

    var body: some View {
        // Version on the left, Quit on the right, across the content width.
        HStack(spacing: 10) {
            Text(model.version)
                .monospacedDigit()
                .foregroundStyle(theme.text2)
                .accessibilityLabel("Version \(model.version)")
            Spacer(minLength: 0)
            Button("Quit Booth", action: model.quit)
                .buttonStyle(TextActionButtonStyle(tone: .primary))
        }
        .font(TextStyle.secondary.font)
        .frame(width: DoneScreen.contentWidth, height: TextStyle.secondary.lineHeight)
        .footerInset(.text)
    }
}

/// Settings rows are separated by half-point rules.
private let hairline: CGFloat = 0.5

/// A 32 pt row with a hairline rule above (and below, for the last row).
private struct SettingsRow<Accessory: View>: View {
    let title: String
    let hasBottomRule: Bool
    let accessory: Accessory

    @Environment(\.theme) private var theme

    init(_ title: String, hasBottomRule: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.hasBottomRule = hasBottomRule
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .textStyle(.body)
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
            accessory
        }
        .frame(minHeight: 32)
        .padding(.top, hairline)
        .padding(.bottom, hasBottomRule ? hairline : 0)
        .overlay(alignment: .top) { rule }
        .overlay(alignment: .bottom) {
            if hasBottomRule { rule }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.sep)
            .frame(height: hairline)
    }
}
