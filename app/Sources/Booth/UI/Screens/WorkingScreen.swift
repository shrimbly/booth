import BoothCore
import SwiftUI

/// The file in the booth (WorkingSound.dc.html, option J). The whole popover is the progress
/// bar, and the percent on the left and the file name on the right are its only text. The fill
/// spreads from the left like sound from a speaker, with faint rings moving out through it; the
/// name stays out of focus until the fill has passed under it. VoiceOver reads the full status
/// line, and what is queued next, as the bar's value.
struct WorkingScreen: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let job = model.workingJob
        let progress = job?.progress ?? 0
        ZStack(alignment: .trailing) {
            RippleBarView(progress: progress, name: job?.name ?? "")
                // A new job (after Cancel, say) starts on a fresh bar, not the last job's fill.
                .id(job?.id)
                .animation(PopoverMotion.unlessReduced(PopoverMotion.progress, reduceMotion), value: progress)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(job?.name ?? "")
                .accessibilityValue([model.statusLine, model.queueLine].compactMap { $0 }.joined(separator: ". "))
                .accessibilityAddTraits(.updatesFrequently)
            // The × is drawn with the text, in both colours; this takes the click.
            Button(action: model.cancelActive) {
                Color.clear.frame(width: 24, height: 24)
            }
            .buttonStyle(BareButtonStyle())
            .padding(.trailing, WorkingRow.trailingInset)
            .accessibilityLabel("Cancel")
            .help("Cancel")
        }
    }
}

/// The bar, drawn at `progress` so it can glide between the engine's progress updates.
private struct RippleBarView: View, Animatable {
    var progress: Double
    let name: String

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.theme) private var theme
    @Environment(\.popoverChrome) private var chrome
    @Environment(\.snapshotClock) private var snapshotClock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The ripples' clock starts with the first bar shown.
    private static let epoch = Date()
    /// Snapshots and reduced motion hold this moment, with rings spread through the fill.
    static let stillMilliseconds = 12_000.0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let front = width * min(1, max(0, progress))
            ZStack {
                ripples(front: front)
                text(front: front, width: width)
            }
        }
        .frame(height: RippleBar.height)
        .background(theme.inkTrack)
    }

    @ViewBuilder
    private func ripples(front: Double) -> some View {
        if chrome == .snapshot || reduceMotion {
            let milliseconds = chrome == .snapshot ? snapshotClock ?? Self.stillMilliseconds : Self.stillMilliseconds
            RippleCanvas(front: front, milliseconds: milliseconds)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                RippleCanvas(front: front, milliseconds: context.date.timeIntervalSince(Self.epoch) * 1000)
            }
        }
    }

    /// The text, once per colour and focus, each drawing masked to where it belongs.
    private func text(front: Double, width: Double) -> some View {
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        return ZStack {
            WorkingRow(percent: percent, name: name, color: theme.text, showsMarks: true, nameLayer: nil)
                .mask(gradient(WorkingText.marks, front: front, width: width))
            ForEach(Array(WorkingText.nameLayers.enumerated()), id: \.offset) { _, layer in
                WorkingRow(percent: percent, name: name, color: layer.onFill ? theme.onInk : theme.text, showsMarks: false, nameLayer: layer)
                    .mask(gradient(layer.fade, front: front, width: width))
            }
            WorkingRow(percent: percent, name: name, color: theme.onInk, showsMarks: true, nameLayer: nil)
                .mask(gradient(WorkingText.marksOnFill, front: front, width: width))
        }
    }

    private func gradient(_ fade: FrontFade, front: Double, width: Double) -> LinearGradient {
        LinearGradient(
            stops: fade.stops(front: front, width: width).map { Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location) },
            startPoint: .leading, endPoint: .trailing)
    }
}

/// The fill, its rings and the faint ring ahead of it.
private struct RippleCanvas: View {
    let front: Double
    let milliseconds: Double

    @Environment(\.theme) private var theme

    /// Points along each ring's visible arc.
    private static let samples = 24

    var body: some View {
        Canvas { context, size in
            let fill = RippleBar.fillRadius(front: front)
            let lead = RippleBar.leadRing(milliseconds: milliseconds, front: front)
            context.stroke(ellipse(rx: lead.rx, ry: lead.ry), with: .color(theme.text.opacity(lead.alpha)), lineWidth: lead.lineWidth)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: RippleBar.fillSoftness))
                layer.fill(ellipse(rx: fill, ry: RippleBar.verticalRadius(fill)), with: .color(theme.ink0))
            }
            let rings = RippleBar.rings(milliseconds: milliseconds, front: front)
            guard !rings.isEmpty else { return }
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: RippleBar.ringSoftness))
                for ring in rings {
                    let path = arc(of: ring, height: size.height)
                    layer.stroke(path, with: .color(theme.ink3.opacity(ring.bandAlpha)), lineWidth: ring.bandWidth)
                    layer.stroke(path, with: .color(theme.ink3.opacity(ring.alpha)), lineWidth: ring.lineWidth)
                }
            }
        }
    }

    private func ellipse(rx: Double, ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: RippleBar.sourceX - rx, y: RippleBar.midY - ry, width: 2 * rx, height: 2 * ry))
    }

    /// The part of the ring that can show (its right-hand side, within a little of the bar's
    /// height), each point nudged sideways by the ring's waver.
    private func arc(of ring: RippleBar.Ring, height: Double) -> Path {
        let reach = height / 2 + 6
        let span = ring.ry > reach ? asin(reach / ring.ry) : .pi / 2
        var path = Path()
        for i in 0...Self.samples {
            let theta = -span + 2 * span * Double(i) / Double(Self.samples)
            let y = RippleBar.midY + ring.ry * sin(theta)
            let x = RippleBar.sourceX + ring.rx * cos(theta) + RippleBar.waver(y: y, seed: ring.seed, milliseconds: milliseconds)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

/// One drawing of the bar's text. Every drawing lays out alike, so the layers line up; each
/// shows only its own parts: the percent and ×, or one focus of the name.
private struct WorkingRow: View {
    let percent: Int
    let name: String
    let color: Color
    let showsMarks: Bool
    let nameLayer: WorkingText.NameLayer?

    static let trailingInset: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .leading)
                .opacity(showsMarks ? 1 : 0)
            Text(name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                // File names keep their extension visible, as in Finder.
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .blur(radius: nameLayer?.blur ?? 0)
                .opacity(nameLayer?.opacity ?? 0)
            IconView(.close, size: 14)
                .frame(width: 24, height: 24)
                .opacity(showsMarks ? 0.7 : 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, Self.trailingInset)
        .frame(maxHeight: .infinity)
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
}
