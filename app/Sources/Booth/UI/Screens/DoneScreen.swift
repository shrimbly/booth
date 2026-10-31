import BoothCore
import SwiftUI

/// A finished file: compare with the original, play, and remix live from the saved stems. The
/// picture (video jobs) and the mix sliders sit behind the "Video" and "Mix" toggles, and the
/// file's actions share their row: Open and Done, or Revert and Save once the mix has changed.
/// Shown, the picture leads, nearly edge to edge, with play and the waveform over its bottom.
struct DoneScreen: View {
    let model: AppModel

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The frame's content width: 307 pt less 2 × (1.5 pt border + 15 pt padding).
    static let contentWidth: CGFloat = 274
    /// The picture sits 4 pt in from the frame, nearer than the content's 13 pt top and 15 pt side
    /// padding: it reaches out by the difference.
    static let pictureReach = (top: CGFloat(13 - 4), side: CGFloat(15 - 4))
    static let pictureWidth = contentWidth + 2 * pictureReach.side

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let video = model.shownVideo {
                VideoPreview(video: video, isPlaying: model.isPlaying, playhead: model.playhead, onTap: model.togglePlay)
                    .overlay(alignment: .bottom) { PictureControls(model: model) }
                    .clipShape(RoundedRectangle(cornerRadius: VideoPreview.cornerRadius, style: .continuous))
                    .padding(.horizontal, -Self.pictureReach.side)
                    .padding(.top, -Self.pictureReach.top)
                    .padding(.bottom, 12)
                    .transition(.swap(reduceMotion: reduceMotion, scale: 0.98, arriving: .revealing))
            }
            if let label = model.backgroundJobLabel {
                BackgroundJobButton(label: label, action: model.switchToActive)
                    .padding(.bottom, 6)
            }
            // No corner button on Done, so the name may run the full width.
            ScreenTitle(model.focusJob?.name ?? "", clearsCorner: false)
            CompareControl(isComparing: model.isComparing, setComparing: model.setComparing)
                .textStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)

            if model.shownVideo == nil {
                HStack(spacing: 8) {
                    PlayButton(isPlaying: model.isPlaying, action: model.togglePlay)
                    Waveform(
                        levels: model.waveformLevels, playhead: model.playhead,
                        isComparing: model.isComparing, onSeek: model.seek(to:))
                }
                .padding(.top, 12)
                .transition(.swap(reduceMotion: reduceMotion, arriving: .revealing))
            }

            HStack(spacing: 6) {
                if model.canShowVideo {
                    let isOn = model.shownVideo != nil
                    ToggleChip(
                        icon: .film, title: "Video", isOn: isOn,
                        accessibilityLabel: isOn ? "Hide video" : "Show video"
                    ) { animated(opening: !isOn, model.toggleVideo) }
                }
                ToggleChip(
                    icon: .sliders, title: "Mix", isOn: model.isMixOpen,
                    accessibilityLabel: model.isMixOpen ? "Hide mix" : "Show mix"
                ) { animated(opening: !model.isMixOpen, model.toggleMix) }
                Spacer(minLength: 0)
                DoneActions(model: model)
            }
            .padding(.top, 10)

            if model.isMixOpen {
                VStack(spacing: 0) {
                    MixSlider(label: "Speech", value: model.mix.speech) { update(\.speech, $0) }
                    MixSlider(label: "Background", value: model.mix.background) { update(\.background, $0) }
                    // No music found: the slider is left out rather than shown disabled.
                    if model.musicDetected {
                        MixSlider(label: "Music", value: model.mix.music) { update(\.music, $0) }
                    }
                }
                .padding(.top, 6)
                .transition(.swap(reduceMotion: reduceMotion, scale: 0.98, arriving: .revealing))
            }
        }
    }

    /// Showing or hiding a section resizes the popover the way a screen change does: opening
    /// grows at once, closing first lets the section go soft.
    private func animated(opening: Bool, _ change: () -> Void) {
        let animation = opening ? PopoverMotion.sectionOpen : PopoverMotion.sectionClose
        withAnimation(PopoverMotion.unlessReduced(animation, reduceMotion), change)
    }

    private func update(_ stem: WritableKeyPath<Mix, Int>, _ value: Int) {
        var mix = model.mix
        mix[keyPath: stem] = value
        model.setMix(mix)
    }
}

/// The right end of the chips' row: Open (in Finder) and Done, or Revert and Save while the
/// mix has unsaved changes. Done is hidden until the changes are saved or reverted.
private struct DoneActions: View {
    let model: AppModel

    var body: some View {
        if model.isMixDirty {
            ChipButton(title: "Revert", action: model.revertMix)
                .disabled(model.isSaving)
            ChipButton(title: saveTitle, action: model.saveMix)
                .disabled(model.isSaving)
                .help(model.saveError?.message ?? "")
        } else {
            ChipButton(icon: .finder, title: "Open", accessibilityLabel: "Open in Finder", action: model.revealInFinder)
                .help("Show in Finder")
            ChipButton(title: "Done", action: model.closeDone)
        }
    }

    private var saveTitle: String {
        if model.isSaving { return "Saving…" }
        return model.saveError == nil ? "Save" : "Try again"
    }
}

/// "● In the booth: name · 34%" — the job still running while you listen; switches to Working.
private struct BackgroundJobButton: View {
    let label: String
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.work)
                    .frame(width: 6, height: 6)
                Text(label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textStyle(.secondary)
            .foregroundStyle(theme.text2)
        }
        .buttonStyle(BareButtonStyle())
    }
}

/// "Hold ⌥ to compare": press and hold (pointer, or Space/Return when focused) to hear the
/// original. Holding ⌥ does the same (AppModel watches it through `CompareKeyWatching`).
private struct CompareControl: View {
    let isComparing: Bool
    let setComparing: (Bool) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Text(isComparing ? "Playing the original" : "Hold ⌥ to compare")
            .fontWeight(isComparing ? .semibold : .regular)
            .foregroundStyle(isComparing ? theme.text : theme.text2)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: setComparing)
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return], phases: [.down, .up]) { press in
                setComparing(press.phase == .down)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isComparing ? "Playing the original" : "Compare with the original")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setComparing(!isComparing) }
    }
}

/// Play and the waveform over the bottom of the picture, on a scrim that keeps them readable on
/// any frame. The scrim lets clicks through to the picture, which plays and pauses too.
private struct PictureControls: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .bottom, endPoint: .top)
                .frame(height: 64)
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                PlayButton(isPlaying: model.isPlaying, onPicture: true, action: model.togglePlay)
                Waveform(
                    levels: model.waveformLevels, playhead: model.playhead,
                    isComparing: model.isComparing, onPicture: true, onSeek: model.seek(to:))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    /// Over the picture: a light button with a dark glyph, the reverse of the usual.
    var onPicture = false
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            IconView(isPlaying ? .pause : .play, size: 12)
                .foregroundStyle(onPicture ? Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255) : theme.inverse)
                .frame(width: 26, height: 26)
                .background(onPicture ? Color.white.opacity(0.92) : theme.text, in: Circle())
        }
        .buttonStyle(BareButtonStyle())
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

