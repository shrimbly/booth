import AVFoundation
import BoothCore

/// Reads a file's first video track for the Done screen's picture: its display aspect (rotation
/// and non-square pixels included) and where the audio starts on the file's timeline.
struct AVVideoInspector: VideoInspecting {
    func inspect(_ url: URL) async -> VideoTraits? {
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (size, transform, descriptions) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            guard size.width > 0, size.height > 0 else { return nil }
            // A quarter turn (phone video shot upright) swaps width and height on screen.
            let quarterTurn = abs(transform.b) > abs(transform.a)
            let pixelAspect = descriptions.first.flatMap(Self.pixelAspect) ?? 1
            var audioStart = 0.0
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                audioStart = try await Self.mediaStart(of: audio)
            }
            return VideoTraits(
                aspect: VideoSync.displayAspect(
                    width: size.width, height: size.height, quarterTurn: quarterTurn, pixelAspect: pixelAspect),
                audioStart: audioStart.isFinite ? max(0, audioStart) : 0)
        } catch {
            Log.error("video: cannot read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// When a track's first sample plays. A late-starting stream in an MP4 or MOV is an empty edit
    /// followed by the media, and the track's time range still starts at 0.
    private static func mediaStart(of track: AVAssetTrack) async throws -> Double {
        let (range, segments) = try await track.load(.timeRange, .segments)
        if let media = segments.first(where: { !$0.isEmpty }) {
            return media.timeMapping.target.start.seconds
        }
        return range.start.seconds
    }

    /// Horizontal ÷ vertical pixel spacing, when the track says (anamorphic video).
    private static func pixelAspect(_ description: CMFormatDescription) -> Double? {
        guard let ratio = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
            let horizontal = (ratio[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue,
            let vertical = (ratio[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue,
            horizontal > 0, vertical > 0
        else { return nil }
        return horizontal / vertical
    }
}
