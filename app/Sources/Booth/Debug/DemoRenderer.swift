import AppKit
import BoothCore
import SwiftUI
import UniformTypeIdentifiers

/// `--render-demo DIR`: draws the website's demo video as `DIR/frame-0001.png`… (30 fps, 2×),
/// using the real popover views and menu bar glyph over frozen fake models, as `--render-states`
/// does. It opens on a laptop's whole desktop at true size: a file is dragged from the desktop to
/// Booth's icon while the view zooms in on the menu bar, the popover springs open on the drop
/// zone, works on the file and shows it done, then closes and the view zooms back out. The desktop
/// picture is `DIR/wallpaper.jpg` if there is one (2880 × 1800 is sharp), else a plain gradient;
/// `DIR/poster.jpg`, if there is one, is a still of the file's video, and the Done screen shows it
/// as the picture. `site/tools/make-demo-video.sh` runs this and encodes the video.
@MainActor
enum DemoRenderer {
    /// The video's frame, in points.
    static let size = CGSize(width: 640, height: 400)
    static let framesPerSecond = 30.0
    static let duration = 11.9
    static let fileName = "demo-video.mp4"

    static func run(outputDir: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            Log.error("render-demo: cannot create \(outputDir.path): \(error)")
            return 1
        }
        let wallpaper = NSImage(contentsOf: outputDir.appendingPathComponent("wallpaper.jpg"))
        if wallpaper == nil { Log.info("render-demo: no wallpaper.jpg; drawing a gradient desktop") }
        let poster = NSImage(contentsOf: outputDir.appendingPathComponent("poster.jpg"))
        if poster == nil { Log.info("render-demo: no poster.jpg; the Done screen keeps the picture hidden") }
        let fileIcon = NSWorkspace.shared.icon(for: .mpeg4Movie)
        let frameCount = Int(duration * framesPerSecond)
        var failures = 0
        for index in 0..<frameCount {
            let scene = DemoScene(t: Double(index) / framesPerSecond, wallpaper: wallpaper, poster: poster, fileIcon: fileIcon)
            let url = outputDir.appendingPathComponent(String(format: "frame-%04d.png", index + 1))
            if !SnapshotRenderer.writePNG(of: scene, to: url) {
                failures += 1
                Log.error("render-demo: failed to render \(url.lastPathComponent)")
            }
        }
        Log.info("render-demo: wrote \(frameCount - failures) frames to \(outputDir.path)")
        return failures == 0 ? 0 : 1
    }
}

/// When things happen, in seconds from the start of the loop.
private enum Beat {
    /// The file is carried up to Booth's icon, held there until the popover springs open, then
    /// carried down into the drop zone and let go, as you would with the real app.
    static let dragStart = 0.5
    static let atIcon = 1.9
    static let leaveIcon = 2.4
    static let inZone = 2.9
    /// The view zooms in on the menu bar as the file nears it, and back out once the popover closes.
    static let zoomIn = 1.1
    static let zoomInEnd = 2.3
    /// The icon grows under the file and the popover springs open; the drop zone lights up
    /// ("Release to start") once the file is over it.
    static let hover = 1.75
    static let open = 2.15
    static let zoneHover = 2.7
    static let drop = 3.05
    static let working = 3.2
    static let done = 7.0
    static let close = 10.0
    static let closed = 10.3
    static let zoomOut = 10.45
    static let zoomOutEnd = 11.45
    /// The screens cross-fade, as the live popover's content does.
    static let fade = 0.24
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
private func progress(_ t: Double, from start: Double, over length: Double) -> Double { clamp01((t - start) / length) }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
/// A spring that goes a hair past its rest and settles, like the popover's opening.
private func springOut(_ x: Double) -> Double {
    let s = 0.9, u = x - 1
    return 1 + (s + 1) * u * u * u + s * u * u
}

/// A laptop's desktop at true size, filmed by a camera that zooms between the whole screen and
/// the top right corner, where the menu bar icon and the popover are.
private struct DemoScene: View {
    let t: Double
    let wallpaper: NSImage?
    let poster: NSImage?
    let fileIcon: NSImage

    /// A 15-inch laptop's screen, in points: the same shape as the video.
    static let screen = CGSize(width: 1440, height: 900)
    /// How much of the screen's width the camera shows, zoomed in.
    static let zoomedWidth = DemoRenderer.size.width

    private static let menuBarHeight: CGFloat = 24
    /// Booth's icon, laid out by `MenuBar` left of the battery, Wi-Fi and clock.
    private static let iconCenter = CGPoint(x: screen.width - 209, y: 12)
    private static let fileStart = CGPoint(x: 560, y: 560)

    var body: some View {
        let width = cameraWidth
        let scale = DemoRenderer.size.width / width
        // The camera keeps the screen's top right corner in the frame's top right corner.
        ZStack(alignment: .topLeading) {
            desktop
            restingFile
            MenuBar(glyph: glyph, pressed: popoverOpacity > 0, width: Self.screen.width, zoom: scale)
            popover
            dragging
        }
        .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: -(Self.screen.width - width) * scale)
        .frame(width: DemoRenderer.size.width, height: DemoRenderer.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    /// How much of the screen's width is in view: all of it, or the corner, easing between them
    /// at a steady rate of zoom.
    private var cameraWidth: Double {
        let zoom = t < Beat.zoomOut
            ? easeInOut(progress(t, from: Beat.zoomIn, over: Beat.zoomInEnd - Beat.zoomIn))
            : 1 - easeInOut(progress(t, from: Beat.zoomOut, over: Beat.zoomOutEnd - Beat.zoomOut))
        let wide = Foundation.log(Double(Self.screen.width)), close = Foundation.log(Double(Self.zoomedWidth))
        return exp(wide + (close - wide) * zoom)
    }

    @ViewBuilder
    private var desktop: some View {
        if let wallpaper {
            Image(nsImage: wallpaper)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.screen.width, height: Self.screen.height)
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.36, green: 0.58, blue: 0.84), Color(red: 0.13, green: 0.55, blue: 0.62)], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: The menu bar icon

    private var glyph: (mode: GlyphMode, breathe: Double, scale: CGFloat) {
        if t < Beat.hover || t >= Beat.closed { return (.idle, 1, 1) }
        if t < Beat.drop { return (.target, 1, 1 + 0.14 * easeOut(progress(t, from: Beat.hover, over: 0.2))) }
        if t < Beat.done {
            // The drop pulse, then the lamp breathes once every 1.4 s.
            let pulse = 1 + 0.25 * (1 - easeOut(progress(t, from: Beat.drop, over: 0.3)))
            let phase = (t - Beat.drop).truncatingRemainder(dividingBy: GlyphRenderer.breathPeriod) / GlyphRenderer.breathPeriod
            return (.working, GlyphRenderer.breathe(atPhase: phase), pulse)
        }
        return (.done, 1, 1)
    }

    // MARK: The popover

    private var popoverOpacity: Double {
        if t < Beat.open || t >= Beat.closed { return 0 }
        if t >= Beat.close { return 1 - easeOut(progress(t, from: Beat.close, over: 0.18)) }
        return easeOut(progress(t, from: Beat.open, over: 0.16))
    }

    private var popoverScale: Double {
        if t >= Beat.close { return 1 - 0.02 * progress(t, from: Beat.close, over: 0.18) }
        return 0.95 + 0.05 * springOut(progress(t, from: Beat.open, over: 0.3))
    }

    /// The screens showing now, with their opacities; two at once while one fades into the next.
    private var screens: [(model: AppModel, opacity: Double)] {
        let file = DemoRenderer.fileName
        let working = AppModel.fixture(.working, progress: workProgress, file: file)
        // With a still of the video, Done shows the picture; without one it stays hidden.
        let aspect = poster.map { $0.size.width / max(1, $0.size.height) } ?? 16 / 9
        let done = AppModel.fixture(poster == nil ? .done : .doneVideo, file: file, videoAspect: aspect)
        if t < Beat.zoneHover { return [(AppModel.fixture(.idle), 1)] }
        if t < Beat.zoneHover + 0.12 {
            // The same panel, lighting up as the file comes over it.
            let x = progress(t, from: Beat.zoneHover, over: 0.12)
            return [(AppModel.fixture(.idle), 1 - x), (AppModel.fixture(.idleDropHover), x)]
        }
        if t < Beat.drop { return [(AppModel.fixture(.idleDropHover), 1)] }
        if t < Beat.drop + Beat.fade {
            let fade = handOver(progress(t, from: Beat.drop, over: Beat.fade))
            return [(AppModel.fixture(.idleDropHover), fade.leaving), (working, fade.arriving)]
        }
        if t < Beat.done { return [(working, 1)] }
        if t < Beat.done + Beat.fade {
            let fade = handOver(progress(t, from: Beat.done, over: Beat.fade))
            return [(working, fade.leaving), (done, fade.arriving)]
        }
        return [(done, 1)]
    }

    /// The leaving screen is mostly gone before the arriving one shows, so the two panels, which
    /// differ in size, are never seen through each other for long.
    private func handOver(_ x: Double) -> (leaving: Double, arriving: Double) {
        (1 - easeOut(clamp01(x / 0.6)), easeOut(clamp01((x - 0.4) / 0.6)))
    }

    /// The job runs a couple of minutes for real; here it takes under four seconds.
    private var workProgress: Double {
        easeInOut(progress(t, from: Beat.working - 0.15, over: Beat.done - Beat.working - 0.1))
    }

    @ViewBuilder
    private var popover: some View {
        if popoverOpacity > 0 {
            let x = min(Self.iconCenter.x - PopoverRootView.width / 2, Self.screen.width - 8 - PopoverRootView.width)
            ZStack(alignment: .top) {
                ForEach(Array(screens.enumerated()), id: \.offset) { _, screen in
                    PopoverRootView(model: screen.model, chrome: .snapshot)
                        .environment(\.snapshotClock, max(0, t - Beat.working) * 1000)
                        .environment(\.snapshotPoster, poster)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(screen.opacity)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
            .scaleEffect(popoverScale, anchor: UnitPoint(x: (Self.iconCenter.x - x) / PopoverRootView.width, y: 0))
            .opacity(popoverOpacity)
            .offset(x: x, y: Self.menuBarHeight + 6)
        }
    }

    // MARK: The file and the cursor

    /// Where the file is let go of: inside the open popover's drop zone.
    private static let dropPoint = CGPoint(x: iconCenter.x - 20, y: 112)

    /// Where the dragged copy is at `time` (the middle of its top edge): up from the desktop to
    /// Booth's icon in an arc, held there while the popover springs open, then down into the drop zone.
    private func dragPoint(at time: Double) -> CGPoint {
        let icon = CGPoint(x: Self.iconCenter.x, y: Self.iconCenter.y + 6)
        if time < Beat.leaveIcon {
            let move = easeInOut(progress(time, from: Beat.dragStart, over: Beat.atIcon - Beat.dragStart))
            return CGPoint(
                x: Self.fileStart.x + (icon.x - Self.fileStart.x) * move,
                y: Self.fileStart.y + (icon.y - Self.fileStart.y) * move - sin(move * .pi) * 60)
        }
        let move = easeInOut(progress(time, from: Beat.leaveIcon, over: Beat.inZone - Beat.leaveIcon))
        return CGPoint(x: icon.x + (Self.dropPoint.x - icon.x) * move, y: icon.y + (Self.dropPoint.y - icon.y) * move)
    }

    /// The copy shrinks on its way up, and a little more as it's let go.
    private func dragScale(at time: Double) -> Double {
        let up = easeInOut(progress(time, from: Beat.dragStart, over: Beat.atIcon - Beat.dragStart))
        return 1 - 0.45 * up - 0.15 * progress(time, from: Beat.drop, over: 0.15)
    }

    /// The file on the desktop, selected. It stays put: dragging moves a see-through copy, as in Finder.
    private var restingFile: some View {
        FileIcon(poster: poster, fileIcon: fileIcon, selected: true)
            .position(x: Self.fileStart.x, y: Self.fileStart.y + 40)
    }

    @ViewBuilder
    private var dragging: some View {
        let ghost = t < Beat.dragStart ? 0 : 1 - progress(t, from: Beat.drop, over: 0.15)
        if ghost > 0 {
            let point = dragPoint(at: t), scale = dragScale(at: t)
            FileIcon(poster: poster, fileIcon: fileIcon, selected: false)
                .opacity(0.7 * ghost)
                .scaleEffect(scale, anchor: .top)
                .position(x: point.x, y: point.y + 40 * scale)
        }
        cursor(at: cursorPoint)
    }

    /// The pointer grabs the file and carries it, rests where it let go while Booth works, then
    /// heads back to the file as the view zooms out, so the loop starts where it ended.
    private var cursorPoint: CGPoint {
        func grip(_ time: Double) -> CGPoint {
            let point = dragPoint(at: time)
            return CGPoint(x: point.x + 8, y: point.y + 26 * min(1, dragScale(at: time) + 0.15))
        }
        if t < Beat.zoomOut { return grip(min(t, Beat.drop)) }
        let start = grip(0), dropped = grip(Beat.drop)
        let back = easeInOut(progress(t, from: Beat.zoomOut, over: DemoRenderer.duration - 0.2 - Beat.zoomOut))
        return CGPoint(x: dropped.x + (start.x - dropped.x) * back, y: dropped.y + (start.y - dropped.y) * back)
    }

    private func cursor(at point: CGPoint) -> some View {
        let arrow = NSCursor.arrow
        let size = arrow.image.size
        return Image(nsImage: arrow.image)
            .frame(width: size.width, height: size.height)
            .position(x: point.x - arrow.hotSpot.x + size.width / 2, y: point.y - arrow.hotSpot.y + size.height / 2)
    }
}

/// The video file on the desktop: its thumbnail over its name, highlighted when selected.
private struct FileIcon: View {
    let poster: NSImage?
    let fileIcon: NSImage
    let selected: Bool

    /// Finder's selection blue behind the name.
    private static let selectionBlue = Color(red: 0, green: 0.48, blue: 1)

    var body: some View {
        VStack(spacing: 3) {
            FileThumbnail(poster: poster, fileIcon: fileIcon)
                .padding(5)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.22))
                    }
                }
            Text(DemoRenderer.fileName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.selectionBlue)
                    }
                }
                .shadow(color: selected ? .clear : .black.opacity(0.6), radius: 1.5, y: 0.5)
                .fixedSize()
        }
    }
}

/// A video as Finder shows it: a thumbnail of its picture in the picture's own shape, here with a
/// play mark so it reads as a video even small. Without a still, the system's movie icon.
private struct FileThumbnail: View {
    let poster: NSImage?
    let fileIcon: NSImage

    var body: some View {
        if let poster {
            let width: CGFloat = 88
            Image(nsImage: poster)
                .resizable()
                .frame(width: width, height: width * poster.size.height / max(1, poster.size.width))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1.5)
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
        } else {
            Image(nsImage: fileIcon)
                .resizable()
                .frame(width: 64, height: 64)
        }
    }
}

/// A macOS menu bar over the desktop: Finder's menus on the left; Booth's icon, battery, Wi-Fi
/// and the clock on the right, in white as on a bright wallpaper.
private struct MenuBar: View {
    let glyph: (mode: GlyphMode, breathe: Double, scale: CGFloat)
    let pressed: Bool
    let width: CGFloat
    /// The camera's zoom, so the icon is drawn at the frame's own pixels.
    let zoom: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("Finder").fontWeight(.bold)
                ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            }
            .padding(.leading, 20)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                ZStack {
                    if pressed {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white.opacity(0.24))
                            .frame(width: 30, height: 20)
                    }
                    if let icon = glyphImage {
                        Image(decorative: icon.image, scale: icon.scale)
                            .renderingMode(glyph.mode.isTemplate ? .template : .original)
                    }
                }
                .frame(width: 30, height: 24)
                Image(systemName: "battery.75percent")
                    .font(.system(size: 15))
                    .frame(width: 28)
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                Text("Sun 1 Nov  9:41")
                    .frame(width: 104, alignment: .trailing)
            }
            .padding(.trailing, 12)
        }
        .font(.system(size: 13, weight: .medium))
        .frame(width: width, height: 24)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.2), radius: 1)
    }

    /// Booth's icon, drawn into a bitmap at the frame's pixels beforehand: an `NSImage` that
    /// AppKit draws partway through the frame upsets how the rest of it composites, and the
    /// signature's cross-fades come out uneven.
    private var glyphImage: (image: CGImage, scale: CGFloat)? {
        let size = GlyphRenderer.size
        let pixels = Int((size.width * displayScale * zoom).rounded(.up))
        let scale = CGFloat(pixels) / size.width
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The glyph's user space is y down.
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: 0, y: -size.height)
        let ink = glyph.mode.isTemplate ? NSColor.black : .white
        GlyphRenderer.draw(glyph.mode, breathe: glyph.breathe, scale: glyph.scale, ink: ink.cgColor, in: context)
        return context.makeImage().map { ($0, scale) }
    }
}
