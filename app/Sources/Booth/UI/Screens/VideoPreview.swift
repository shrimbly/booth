import AVFoundation
import AppKit
import BoothCore
import SwiftUI

/// The Done screen's picture: the job's video, muted, kept on the preview's clock. The sound is
/// always the stem mix (PreviewPlayer), so the sliders and ⌥ keep working. The playhead is where
/// the sound is heard, output latency included, so lips match the voice on Bluetooth too.
/// Clicking the picture plays or pauses like the play button. It spans `DoneScreen.pictureWidth`;
/// a video taller than the box is pillarboxed on black.
///
/// ImageRenderer can't draw an AVPlayerLayer, so snapshots show a stand-in poster.
struct VideoPreview: View {
    let video: PreviewVideo
    let isPlaying: Bool
    let playhead: Double
    let onTap: () -> Void

    @Environment(\.popoverChrome) private var chrome
    @Environment(\.snapshotPoster) private var snapshotPoster

    /// Concentric with the frame's 10 pt corners, 1.5 pt border and the picture's 4 pt inset.
    static let cornerRadius: CGFloat = 5

    var body: some View {
        let maxHeight = chrome == .snapshot ? VideoSync.maxHeight : Self.liveMaxHeight
        ZStack {
            Color.black
            switch chrome {
            case .live:
                PlayerLayerView(
                    url: video.url, time: video.time(atPlayhead: playhead), end: video.time(atPlayhead: 1),
                    isPlaying: isPlaying)
            case .snapshot:
                if let snapshotPoster {
                    Image(nsImage: snapshotPoster)
                        .resizable()
                        .aspectRatio(video.aspect, contentMode: .fill)
                } else {
                    PosterStandIn()
                        .aspectRatio(video.aspect, contentMode: .fit)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: VideoSync.height(aspect: video.aspect, width: DoneScreen.pictureWidth, maxHeight: maxHeight))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isPlaying ? "Pauses the preview" : "Plays the preview")
        .accessibilityAction(.default, onTap)
    }

    /// `VideoSync.maxHeight`, less on a short screen so the tallest Done screen still fits.
    private static var liveMaxHeight: Double {
        let visible = Double(NSScreen.main?.visibleFrame.height ?? 900)
        return min(VideoSync.maxHeight, max(90, visible - 330))
    }
}

/// An AVPlayerLayer whose muted player follows `time` and `isPlaying`. The player exists as long
/// as the view does: hiding the picture, leaving the Done screen or focusing another job removes
/// the view and releases it.
private struct PlayerLayerView: NSViewRepresentable {
    let url: URL
    /// Where the video should be now, in seconds on its timeline.
    let time: Double
    /// Where the preview ends on the video's timeline.
    let end: Double
    let isPlaying: Bool

    func makeCoordinator() -> VideoClock { VideoClock() }

    func makeNSView(context: Context) -> PlayerLayerHost {
        let view = PlayerLayerHost()
        view.playerLayer.player = context.coordinator.player
        return view
    }

    func updateNSView(_ view: PlayerLayerHost, context: Context) {
        context.coordinator.follow(url: url, time: time, end: end, isPlaying: isPlaying)
    }

    static func dismantleNSView(_ view: PlayerLayerHost, coordinator: VideoClock) {
        view.playerLayer.player = nil
        coordinator.stop()
    }
}

/// Keeps a muted AVPlayer on the preview's clock. Playing, it runs freely and is re-seeked only
/// once it drifts past `VideoSync.playingTolerance`, aiming ahead by how long seeks take; paused,
/// it is seeked to the exact frame so scrubbing the waveform moves the picture. Seeks never pile
/// up: one runs at a time, and when it lands the latest position is checked again.
@MainActor
private final class VideoClock {
    /// What a seek is taken to need before one has been timed (seconds).
    static let initialSeekLatency = 0.1
    /// The furthest a seek while playing aims ahead (seconds), so one slow seek can't send the
    /// next ones far past the sound.
    static let maxSeekLead = 0.5

    let player = AVPlayer()
    private var url: URL?
    private var target = 0.0
    private var end = 0.0
    private var isPlaying = false
    private var isSeeking = false
    /// How long recent seeks took to land, averaged. The sound moves on while a seek decodes, so
    /// a seek while playing aims this far ahead instead of landing behind and seeking again.
    private var seekLatency = initialSeekLatency

    init() {
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
    }

    func follow(url: URL, time: Double, end: Double, isPlaying: Bool) {
        if url != self.url {
            self.url = url
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        let moved = time != target
        target = time
        self.end = end
        self.isPlaying = isPlaying
        if !isPlaying {
            if player.rate != 0 { player.pause() }
        } else if player.rate == 0 && moved {
            // After Play the playhead holds still until the sound reaches the output; the
            // picture starts when it moves rather than run ahead of the voice.
            player.play()
        }
        reconcile()
    }

    func stop() {
        url = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func reconcile() {
        guard !isSeeking, url != nil else { return }
        let current = player.currentTime().seconds
        guard VideoSync.needsSeek(current: current, expected: target, isPlaying: isPlaying) else { return }
        isSeeking = true
        // Running, aim where the sound will be when the seek lands; paused, or waiting for the
        // sound to start, at the exact frame.
        let destination = isPlaying && player.rate != 0 ? min(target + seekLatency, end) : target
        // The first seek also opens the file, which says nothing about the next ones.
        let timed = player.currentItem?.status == .readyToPlay
        let started = CACurrentMediaTime()
        player.seek(
            to: CMTime(seconds: destination, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            let took = CACurrentMediaTime() - started
            Task { @MainActor [weak self] in
                guard let self else { return }
                isSeeking = false
                if finished && timed { seekLatency = min(Self.maxSeekLead, (seekLatency + took) / 2) }
                // Paused, a scrub may have moved on while this seek ran. Playing, the next
                // playhead tick checks the drift again.
                if !isPlaying { reconcile() }
            }
        }
    }
}

/// A layer-backed view whose layer is the player layer. Clicks pass through to SwiftUI.
private final class PlayerLayerHost: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        // SwiftUI's clip shape doesn't reach into an AppKit view; round the layer itself.
        playerLayer.cornerRadius = VideoPreview.cornerRadius
        playerLayer.cornerCurve = .continuous
        playerLayer.cornerCurve = .continuous
        playerLayer.masksToBounds = true
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { playerLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A neutral video frame for snapshots: a softly lit backdrop and a speaker's silhouette.
private struct PosterStandIn: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = min(size.width, size.height)
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.36), Color(white: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color(white: 0.48))
                    .frame(width: unit * 0.3, height: unit * 0.3)
                    .position(x: size.width / 2, y: size.height * 0.42)
                Capsule()
                    .fill(Color(white: 0.48))
                    .frame(width: unit * 0.7, height: unit * 0.5)
                    .position(x: size.width / 2, y: size.height * 0.98)
            }
        }
    }
}
