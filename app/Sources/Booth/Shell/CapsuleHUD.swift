import AppKit
import SwiftUI

/// The capsule that confirms ⌃⌥E (SPEC §3.8, Surfaces.dc.html): a work-colour dot and one line
/// such as "In the booth: voice-memo.m4a", centred under the menu bar. It ignores the mouse
/// and fades out after two seconds.
@MainActor
final class CapsuleHUD {
    private static let height: CGFloat = 30
    private static let maxWidth: CGFloat = 480
    private static let menuBarGap: CGFloat = 6
    private static let visibleDuration: TimeInterval = 2

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CapsuleLabel>?
    private var generation = 0

    func show(_ text: String) {
        let (panel, hostingView) = makePanelIfNeeded()
        // Hug the text up to the cap; past it the name gives way in the middle.
        let idealWidth = NSHostingView(rootView: CapsuleLabel(text: text, width: nil).fixedSize()).fittingSize.width
        let width = min(Self.maxWidth, ceil(idealWidth))
        hostingView.rootView = CapsuleLabel(text: text, width: width)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Centred on the screen (not the visible frame, which a side Dock pushes over), just
        // under the menu bar.
        let menuBarBottom = screen?.visibleFrame.maxY ?? frame.maxY
        panel.setFrame(NSRect(
            x: (frame.midX - width / 2).rounded(), y: menuBarBottom - Self.menuBarGap - Self.height,
            width: width, height: Self.height), display: true)
        panel.invalidateShadow()

        generation += 1
        let shownGeneration = generation
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        Log.info("capsule: \(text)")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration) { [weak self] in
            self?.fadeOut(ifStill: shownGeneration)
        }
    }

    private func fadeOut(ifStill shownGeneration: Int) {
        guard shownGeneration == generation, let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer message may have arrived during the fade; leave it on screen.
                guard let self, shownGeneration == self.generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func makePanelIfNeeded() -> (NSPanel, NSHostingView<CapsuleLabel>) {
        if let panel, let hostingView { return (panel, hostingView) }
        let frame = NSRect(x: 0, y: 0, width: 200, height: Self.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let chrome = GlassChromeView(cornerRadius: Self.height / 2, continuousCorners: false)
        chrome.frame = frame
        let hostingView = NSHostingView(rootView: CapsuleLabel(text: "", width: nil))
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.frame = chrome.bounds
        hostingView.autoresizingMask = [.width, .height]
        chrome.addSubview(hostingView)
        panel.contentView = chrome

        self.panel = panel
        self.hostingView = hostingView
        return (panel, hostingView)
    }
}

/// Surfaces.dc.html: 30 pt tall, 12 pt left / 14 pt right, a 6 pt dot, an 8 pt gap, 12 pt text.
/// Given a `width` narrower than the text needs, the text truncates in the middle and the dot
/// stays; nil hugs the text.
struct CapsuleLabel: View {
    let text: String
    let width: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.work)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.resolve(colorScheme).text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(width: width, height: 30)
        .accessibilityElement(children: .combine)
    }
}
