import AppKit
import BoothCore
import SwiftUI

/// The popover window: borderless, never main, able to take key focus for keyboard control
/// without necessarily activating the app (it may open mid-drag, while Finder is active).
final class PopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Links the panel and its SwiftUI content.
@MainActor
@Observable
final class PopoverPresentation {
    /// The content only exists while the panel is on screen or animating, so a closed popover
    /// does no work while jobs tick.
    var isPresented = false
    /// The content reports its laid-out height here.
    @ObservationIgnored var onContentHeightChange: ((CGFloat) -> Void)?
    /// When the panel last opened from closed, and where it grows from, for the signature's reveal.
    var opening: PopoverOpening?
}

/// The SwiftUI side of the panel, glass included; the window around it is clear.
///
/// The content reports its own height, so the window follows every change of size, whatever
/// caused it. It sits at the top of a hosting view taller than any popover, so SwiftUI always
/// has room to lay it out in full, and the window only has to be tall enough to show it.
struct PopoverContent: View {
    let model: AppModel
    let presentation: PopoverPresentation

    var body: some View {
        if presentation.isPresented {
            PopoverRootView(model: model)
                .environment(\.popoverOpening, presentation.opening)
                .frame(width: PopoverPanelController.width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    presentation.onContentHeightChange?(height)
                }
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Shows `PopoverRootView` under the menu bar icon while `model.isOpen` (SPEC §3.2):
/// - positioned 6 pt under the menu bar, right-aligned to the icon, kept 8 pt inside the screen;
/// - height follows the content with the top edge pinned; SwiftUI springs the glass to its new
///   height on a screen change, and any other change is immediate;
/// - opens with a fade plus a drop-and-grow spring out of the icon, and closes with a smaller,
///   quicker lift and shrink; reopening or closing part way picks up from where it is (Reduce
///   Motion: fades only);
/// - closes on a click outside (not on picking up a file to drag in), Esc, the icon, or
///   another app coming to the front;
/// - takes dropped files on every screen but Settings, and the keyboard after a drop.
///
/// Holding ⌥ to compare is AppModel's job (`CompareKeyWatching`), not the window's.
@MainActor
final class PopoverPanelController {
    static let width: CGFloat = 320
    private static let menuBarGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    /// How far the glass drops as it opens (and lifts as it closes).
    private static let openLift = CGFloat(PanelOpening.lift)
    /// Clear space in the window above the glass, as tall as the lift, so the glass's rounded
    /// top is never cut off while it drops into place. The glass still hangs `menuBarGap` under
    /// the menu bar.
    private static let headroom = openLift
    /// The hosting view is always this tall, more than any popover: SwiftUI lays the content
    /// out in full at the top, and the window shows as much of it as the content needs.
    private static let hostHeight: CGFloat = 1000
    /// SwiftUI's frame resizing (`PopoverMotion.screenChange`, `sectionOpen`).
    private static let resizeDuration: CFTimeInterval = PopoverMotion.screenChangeSettleSeconds
    /// Opening: the glass fades in quickly while it drops `openLift` and grows from
    /// `openScale` out of the icon on a soft spring that settles without a visible bounce.
    private static let openFadeDuration: CFTimeInterval = 0.15
    private static let openScale = CGFloat(PanelOpening.startScale)
    /// Closing is quicker and smaller than opening: a short lift and shrink towards the icon
    /// under a fast fade.
    private static let closeFadeDuration: CFTimeInterval = 0.14
    private static let closePopDuration: CFTimeInterval = 0.16
    private static let closeScale: CGFloat = 0.98
    private static let closeLift: CGFloat = 3

    /// True while a file drag is over the icon: springing open must not steal activation from
    /// the app the drag came from.
    var isDragInProgress: () -> Bool = { false }

    private enum Phase {
        case hidden, shown, hiding
    }

    private let model: AppModel
    private let anchor: () -> NSRect?
    private let panel: PopoverPanel
    private let container: PopoverContainerView
    private let hostingView: PopoverHostingView
    private let presentation = PopoverPresentation()
    private let dropTarget = FileDropTarget()
    private var phase = Phase.hidden
    /// Bumped whenever a hide is started or abandoned, so a stale fade-out cannot order out a
    /// panel that has since been reopened.
    private var hideGeneration = 0
    private var layoutScheduled = false
    private var layoutAnimates = false
    /// When SwiftUI's animation of the glass to a new height would end. Until then the window
    /// holds the taller of the old and new heights (the rest of it is clear), then fits the
    /// content. Animating the window itself lags the content by a frame or more, enough to clip
    /// the frame's border or bare the glass under it.
    private var resizeEnd: CFTimeInterval?
    private var resizeTicker: FrameTicker?
    /// While the glass scales and lifts to open or close, the window's shadow is redrawn every
    /// frame so it stays on the glass instead of hanging where the glass will be.
    private var motionEnd: CFTimeInterval = 0
    private var motionTicker: FrameTicker?
    /// The SwiftUI content's own height, as last reported; nil until the content of the
    /// current presentation has been laid out.
    private var contentHeight: CGFloat?
    private var eventMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    /// Where a left press outside the popover began, until it is released or becomes a drag.
    private var pressStartedElsewhere: NSPoint?
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
        let initialFrame = NSRect(x: 0, y: 0, width: Self.width, height: 160)
        panel = PopoverPanel(contentRect: initialFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        container = PopoverContainerView(frame: initialFrame, dropTarget: dropTarget)
        hostingView = PopoverHostingView(rootView: PopoverContent(model: model, presentation: presentation))
        presentation.onContentHeightChange = { [weak self] height in self?.contentHeightDidChange(height) }
        configurePanel()
        configureDropTarget()
        observeChanges(owner: self) { controller in controller.modelDidChange() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleLayout() }
        }
    }

    // MARK: Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false // The model decides when the popover closes.
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none // Booth animates the popover itself.
        panel.isMovable = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.setAccessibilityLabel("Booth")

        // The content hangs from the top of the window, under the headroom, and nothing slides
        // while the window grows or shrinks. The window's size comes from the content's
        // reports, never from the hosting view, so it needs no intrinsic size.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .minYMargin]
        hostingView.frame = NSRect(
            x: 0, y: container.bounds.height - Self.headroom - Self.hostHeight, width: Self.width, height: Self.hostHeight)
        hostingView.dropTarget = dropTarget
        container.addSubview(hostingView)
        panel.contentView = container
    }

    private func configureDropTarget() {
        dropTarget.isEnabled = { [weak self] in
            guard let self else { return false }
            return phase == .shown && model.acceptsDrops
        }
        dropTarget.onHoverChange = { [weak self] hovering in
            guard let self, model.dropHover != hovering else { return }
            model.dropHover = hovering
        }
        dropTarget.onDrop = { [weak self] urls in
            guard let self else { return }
            Log.info("dropped on the popover: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            model.enqueue(urls)
            takeKeyAfterDrop()
        }
    }

    /// A drag from Finder leaves Finder active and the panel without the keyboard, so Esc and
    /// ⌘W would go to Finder. The panel does not activate Booth, so it can take the keyboard
    /// without pulling Booth to the front. Called after a drop on the popover or, when the drag
    /// sprang the popover open, on the menu bar icon.
    func takeKeyAfterDrop() {
        guard phase == .shown else { return }
        panel.makeKey()
        Log.info("popover took the keyboard after a drop (key: \(panel.isKeyWindow))")
    }

    // MARK: Following the model

    private func modelDidChange() {
        if model.isOpen {
            present()
        } else {
            dismiss()
        }
    }

    private func present() {
        let resuming: Bool
        switch phase {
        case .shown:
            return
        case .hiding:
            // Reopened mid-close: `animateIn` takes over from wherever the close has got to.
            hideGeneration += 1
            resuming = true
        case .hidden:
            resuming = false
        }
        if !resuming {
            // Recorded before the content exists, so the signature's first frame is its reveal's.
            // A reopen mid-close keeps the reveal it already had.
            // Until `animateIn` measures it, the pivot is the last one, else under an icon at the
            // right edge.
            presentation.opening = PopoverOpening(start: Date(), pivotX: presentation.opening?.pivotX ?? Self.width - 16)
        }
        presentation.isPresented = true
        phase = .shown
        // The content has just been created; lay it out so it reports its height before the
        // window appears.
        hostingView.layoutSubtreeIfNeeded()
        layout()
        let activates = !isDragInProgress()
        if activates {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        animateIn(resuming: resuming)
        installEventMonitors()
        Log.info("popover shown at \(NSStringFromRect(panel.frame)) under icon \(anchor().map(NSStringFromRect) ?? "nil")\(activates ? "" : " without activating (drag in progress)")")
    }

    private func dismiss() {
        guard phase == .shown else { return }
        phase = .hiding
        hideGeneration += 1
        let generation = hideGeneration
        removeEventMonitors()
        animateOut { [weak self] in
            guard let self, phase == .hiding, hideGeneration == generation else { return }
            panel.orderOut(nil)
            container.layer?.removeAnimation(forKey: AnimationKey.pop)
            resizeTicker?.stop()
            resizeTicker = nil
            motionTicker?.stop()
            motionTicker = nil
            resizeEnd = nil
            presentation.isPresented = false
            contentHeight = nil
            phase = .hidden
            Log.info("popover hidden")
        }
        returnFocusIfIdle()
    }

    /// Esc or a second click on the icon leaves Booth active with no window to type into; hand
    /// the keyboard back to whichever app had it.
    private func returnFocusIfIdle() {
        guard NSApp.isActive else { return }
        let otherWindowOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeKey }
        if !otherWindowOpen { NSApp.deactivate() }
    }

    // MARK: Layout

    /// The menu bar icon moved (or was only just placed): follow it.
    func anchorDidChange() {
        guard phase == .shown else { return }
        layout()
    }

    private func scheduleLayout(animated: Bool = false) {
        layoutAnimates = layoutAnimates || animated
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layoutScheduled = false
            let animated = layoutAnimates
            layoutAnimates = false
            guard phase == .shown else { return }
            layout(animated: animated)
        }
    }

    private func contentHeightDidChange(_ height: CGFloat) {
        let previous = contentHeight
        contentHeight = height
        guard height != previous, phase == .shown else { return }
        // SwiftUI may be animating the glass to its new height (a screen change does; the queue
        // line just appears). Making room costs nothing when it isn't, since the extra window
        // is clear, whereas fitting at once would cut off a shrinking glass.
        scheduleLayout(animated: previous != nil)
    }

    /// Fits the window to the content, or, while SwiftUI animates the glass to a new height,
    /// to the taller of the two; on every frame of that animation the shadow is redrawn to
    /// follow the glass.
    private func layout(animated: Bool = false) {
        let now = CACurrentMediaTime()
        let height = max(1, ceil(contentHeight ?? measuredContentHeight()))
        if animated && panel.isVisible && !Motion.prefersReducedMotion {
            resizeEnd = now + Self.resizeDuration
        }
        if let resizeEnd, now >= resizeEnd { self.resizeEnd = nil }
        let room = resizeEnd == nil ? height : max(height, panel.frame.height - Self.headroom)
        let frame = panelFrame(contentHeight: room)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        panel.invalidateShadow()
        if resizeEnd == nil {
            resizeTicker?.stop()
            resizeTicker = nil
        } else if resizeTicker == nil {
            resizeTicker = FrameTicker(view: container) { [weak self] _ in
                guard let self, phase == .shown else { return }
                layout()
            }
        }
    }

    /// The content's height before it has reported one. SwiftUI reports during the first layout
    /// pass, so this is only a fallback.
    private func measuredContentHeight() -> CGFloat {
        let root = PopoverRootView(model: model)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
        return NSHostingController(rootView: root)
            .sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
    }

    /// Under the icon, right edges aligned, clamped inside the visible frame of the icon's screen.
    /// Until the icon has a place in a menu bar, the top right of the main screen stands in.
    /// The glass hangs `menuBarGap` under the menu bar; the window starts `headroom` above it.
    private func panelFrame(contentHeight height: CGFloat) -> NSRect {
        // Right after launch the status item window passes through empty and off-screen frames.
        let placedIcon = anchor().flatMap { icon -> (NSRect, NSScreen)? in
            guard icon.width > 0, icon.height > 0 else { return nil }
            let center = NSPoint(x: icon.midX, y: icon.midY)
            return NSScreen.screens.first { $0.frame.contains(center) }.map { (icon, $0) }
        }
        let screen = placedIcon?.1 ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let iconFrame = placedIcon?.0 ?? NSRect(x: visible.maxX, y: visible.maxY, width: 0, height: 0)
        let width = Self.width
        let x = min(max(iconFrame.maxX - width, visible.minX + Self.screenMargin), visible.maxX - Self.screenMargin - width)
        let glassTop = min(iconFrame.minY, visible.maxY) - Self.menuBarGap
        return NSRect(x: x.rounded(), y: (glassTop - height).rounded(), width: width, height: height + Self.headroom)
    }

    // MARK: Open and close motion

    private enum AnimationKey {
        static let pop = "booth.pop"
    }

    /// Fades in, drops `openLift` and grows from `openScale` out of the icon. `resuming`
    /// (reopened mid-close) starts both from what is on screen instead of from fully closed.
    private func animateIn(resuming: Bool) {
        if !resuming { panel.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.openFadeDuration
            context.timingFunction = CubicBezier.cssEase.mediaTimingFunction
            panel.animator().alphaValue = 1
        }
        guard let layer = container.layer else { return }
        guard !Motion.prefersReducedMotion else {
            layer.removeAnimation(forKey: AnimationKey.pop)
            return
        }
        let away = awayTransform(of: layer, scale: Self.openScale, lift: Self.openLift)
        if !resuming { presentation.opening?.pivotX = pivotX(in: layer.bounds) }
        let animation = CASpringAnimation(
            perceptualDuration: PanelOpening.spring.perceptualDuration, bounce: CGFloat(PanelOpening.spring.bounce))
        animation.keyPath = "transform"
        animation.fromValue = NSValue(caTransform3D: resuming ? onScreenTransform(of: layer) : away)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = animation.settlingDuration
        // Replaces a close still running under the same key.
        layer.add(animation, forKey: AnimationKey.pop)
        keepShadowOnGlass(for: animation.duration)
    }

    /// The reverse, quicker and without the overshoot, from wherever the open has got to. Ease
    /// out, like every response to a click or Esc: most of the change shows at once.
    private func animateOut(completion: @escaping @MainActor () -> Void) {
        if !Motion.prefersReducedMotion, let layer = container.layer {
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: onScreenTransform(of: layer))
            animation.toValue = NSValue(caTransform3D: awayTransform(of: layer, scale: Self.closeScale, lift: Self.closeLift))
            animation.duration = Self.closePopDuration
            animation.timingFunction = CubicBezier.easeOut.mediaTimingFunction
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: AnimationKey.pop)
            keepShadowOnGlass(for: animation.duration)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.closeFadeDuration
            context.timingFunction = CubicBezier.easeOut.mediaTimingFunction
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// The transform as drawn right now, part way through an open or close or at rest.
    private func onScreenTransform(of layer: CALayer) -> CATransform3D {
        layer.presentation()?.transform ?? layer.transform
    }

    /// Redraws the window's shadow every frame for `duration`, so it follows the glass.
    private func keepShadowOnGlass(for duration: CFTimeInterval) {
        motionEnd = max(motionEnd, CACurrentMediaTime() + duration)
        guard motionTicker == nil else { return }
        motionTicker = FrameTicker(view: container) { [weak self] time in
            guard let self else { return }
            panel.invalidateShadow()
            if time >= motionEnd {
                motionTicker?.stop()
                motionTicker = nil
            }
        }
    }

    /// Lifted `lift` (into the headroom) and scaled to `scale` about the glass's top edge, under
    /// the icon, so the popover grows out of the icon it hangs from. (The mockup pivots on the
    /// top centre because its icon sits over the middle; Booth hangs the popover right-aligned
    /// under the icon.) AppKit anchors a view's layer at its bottom-left corner (y up), so the
    /// pivot is applied by hand.
    private func awayTransform(of layer: CALayer, scale: CGFloat, lift: CGFloat) -> CATransform3D {
        let bounds = layer.bounds
        let anchorPoint = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let pivot = CGPoint(x: pivotX(in: bounds) - anchorPoint.x, y: bounds.maxY - Self.headroom - anchorPoint.y)
        var transform = CATransform3DMakeTranslation(pivot.x, pivot.y + lift, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
    }

    /// The icon's centre across the glass, or the glass's centre before the icon has a place.
    private func pivotX(in bounds: CGRect) -> CGFloat {
        guard let icon = anchor(), icon.width > 0 else { return bounds.midX }
        return min(max(icon.midX - panel.frame.minX, bounds.minX), bounds.maxX)
    }

    // MARK: Closing on outside clicks and Esc

    private func installEventMonitors() {
        removeEventMonitors()
        let outsideMouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.mouseEventElsewhere(type) }
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
        eventMonitors = [outsideMouse, keys].compactMap { $0 }
        // Switching apps (⌘-Tab, Mission Control) closes the popover like a click elsewhere. A
        // press in another app also activates it; that case is left to the mouse handling.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                self?.closeUnlessChoosingFiles()
            }
        }
        // Booth is often not the active app while the popover is up (it opened mid-drag, or a
        // file was dropped from Finder), so it never resigns; watch for any other app coming
        // to the front instead.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isBooth = activated?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            guard !isBooth else { return }
            MainActor.assumeIsolated { self?.otherAppDidActivate() }
        }
    }

    /// Like a click elsewhere, unless the user is still pressing (a press in that app, left to
    /// the mouse handling) or dragging a file over the icon.
    private func otherAppDidActivate() {
        guard NSEvent.pressedMouseButtons == 0, !isDragInProgress() else { return }
        closeUnlessChoosingFiles()
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        pressStartedElsewhere = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// A left press in another app closes the popover when it is released, unless it became a
    /// drag: the user may be bringing a file from Finder to the open popover (Main.dc.html only
    /// closes on a click on the desk, never on picking up a file).
    private func mouseEventElsewhere(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            pressStartedElsewhere = NSEvent.mouseLocation
        case .leftMouseDragged:
            if let origin = pressStartedElsewhere, hypot(NSEvent.mouseLocation.x - origin.x, NSEvent.mouseLocation.y - origin.y) > 4 {
                pressStartedElsewhere = nil
            }
        case .leftMouseUp:
            guard pressStartedElsewhere != nil else { return }
            pressStartedElsewhere = nil
            closeUnlessChoosingFiles()
        default:
            closeUnlessChoosingFiles()
        }
    }

    private func closeUnlessChoosingFiles() {
        // Clicks inside the file chooser are delivered to its out-of-process view, so they look
        // like clicks elsewhere. Keep the popover while the chooser is up.
        if NSApp.windows.contains(where: { $0 is NSOpenPanel && $0.isVisible }) { return }
        model.close()
    }

    /// True when the key was Booth's to handle.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == KeyCode.escape && modifiers.isEmpty {
            model.close()
            return true
        }
        // With no menu bar of its own, Booth answers the usual shortcuts here.
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "w": model.close()
        case "q": model.quit()
        case ",": model.showSettings()
        default: return false
        }
        return true
    }

    private enum KeyCode {
        static let escape: UInt16 = 53
    }
}

/// Calls back once per frame of the display a view is on, with the time that frame will show,
/// until stopped.
@MainActor
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private let tick: @MainActor (CFTimeInterval) -> Void

    init(view: NSView, tick: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.tick = tick
        super.init()
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The display link holds on to its target until it is invalidated.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        tick(link.targetTimestamp)
    }
}

/// The panel's content view: carries the open/close transform and receives file drags.
private final class PopoverContainerView: NSView {
    private let dropTarget: FileDropTarget

    init(frame: NSRect, dropTarget: FileDropTarget) {
        self.dropTarget = dropTarget
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget.draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget.draggingExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget.performDrop(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTarget.draggingEnded()
    }
}

/// Hosts the SwiftUI content, and routes file drags to the panel's drop target should SwiftUI
/// ever register the view for drags itself.
private final class PopoverHostingView: NSHostingView<PopoverContent> {
    weak var dropTarget: FileDropTarget?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget?.draggingExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget?.performDrop(sender) ?? false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTarget?.draggingEnded()
    }
}
