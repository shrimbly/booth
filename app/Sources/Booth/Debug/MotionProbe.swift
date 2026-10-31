import AppKit
import BoothCore
import SwiftUI

/// `--motion-probe`: plays the popover's transitions on a fixed schedule in a plain window at the
/// top left of the main screen, so they can be recorded (`screencapture -v -R`, with `region`)
/// and stepped through frame by frame, then quits. Prints each step's time since the first.
@MainActor
enum MotionProbe {
    /// The window, in top-left screen points: the region to record.
    static let region = CGRect(x: 160, y: 80, width: 360, height: 280)
    static let leadIn = 1.5
    static let stepSeconds = 1.2
    /// Under an icon at the panel's right edge.
    static let pivotX: CGFloat = PopoverPanelController.width - 16

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        BundledFonts.registerIfNeeded()
        let stage = Stage()
        let screen = NSScreen.screens.first?.frame ?? .zero
        let frame = NSRect(x: region.minX, y: screen.maxY - region.maxY, width: region.width, height: region.height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = NSColor(white: 0.86, alpha: 1)
        window.contentView = NSHostingView(rootView: StageView(stage: stage))
        window.orderFrontRegardless()

        let steps: [(name: String, act: @MainActor () -> Void)] = [
            ("open", { stage.opening = PopoverOpening(start: Date(), pivotX: MotionProbe.pivotX) }),
            ("drop hover on", { stage.model.dropHover = true }),
            ("drop hover off", { stage.model.dropHover = false }),
            ("working", { stage.model = .fixture(.working) }),
            ("done", { stage.model = .fixture(.done) }),
            ("mix open", { withAnimation(PopoverMotion.sectionOpen) { stage.model.toggleMix() } }),
            ("mix closed", { withAnimation(PopoverMotion.sectionClose) { stage.model.toggleMix() } }),
            ("idle", { stage.model = .fixture(.idle) }),
            ("settings", { stage.model.showSettings() }),
            ("back", { stage.model.back() }),
        ]
        let start = Date()
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + leadIn + Double(index) * stepSeconds) {
                print(String(format: "probe %.3f %@", Date().timeIntervalSince(start), step.name))
                fflush(stdout)
                step.act()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + leadIn + Double(steps.count) * stepSeconds) { exit(0) }
        app.run()
        exit(0)
    }
}

@MainActor
@Observable
private final class Stage {
    var model = AppModel.fixture(.idle)
    /// Nil until the "open" step: the panel is shut.
    var opening: PopoverOpening?
}

/// The popover, opening the way the panel opens it (`PanelOpening`: a spring from 95% about the
/// pivot, dropping into place, under a 150 ms fade), so the signature's reveal plays against it.
private struct StageView: View {
    let stage: Stage

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = stage.opening.map { context.date.timeIntervalSince($0.start) }
            let pose = PanelOpening.pose(at: seconds ?? 0)
            PopoverRootView(model: stage.model)
                .environment(\.popoverOpening, stage.opening)
                .scaleEffect(pose.scale, anchor: UnitPoint(x: MotionProbe.pivotX / PopoverPanelController.width, y: 0))
                .offset(y: -pose.lift)
                .opacity(seconds.map { 1 - pow(1 - min(1, $0 / 0.15), 3) } ?? 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
