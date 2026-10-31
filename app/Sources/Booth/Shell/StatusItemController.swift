import AppKit
import BoothCore

/// The menu bar icon (SPEC §3.7, §3.8): draws `AppModel.glyphMode`, toggles the popover on
/// click, and takes dropped files — hovering a file for 0.7 s springs the popover open.
@MainActor
final class StatusItemController: NSObject {
    private static let springLoadDelay: TimeInterval = 0.7
    private static let scaleDuration: CFTimeInterval = 0.24
    private static let targetScale = 1.14
    private static let pulseScale = 1.25

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let dropTarget = FileDropTarget()
    private var scale = Transition(1, curve: .iconSpring)
    private var mode: GlyphMode = .idle
    private var isHighlighted = false
    private var frameTimer: Timer?
    private var frameInterval: TimeInterval?
    private var springLoadTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var reduceMotionObserver: NSObjectProtocol?
    private var windowMoveObservers: [NSObjectProtocol] = []
    private var visibilityObservers: [NSObjectProtocol] = []
    // Nobody sees the menu bar while the displays sleep or another user's session is on screen.
    private var displaysAsleep = false
    private var sessionInactive = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configureDropTarget()
        observeEnvironment()
        observeChanges(owner: self) { controller in controller.modelDidChange() }
    }

    /// The status item's slot in the menu bar, in screen coordinates; the popover hangs off it.
    var anchorRect: NSRect? {
        statusItem.button?.window?.frame
    }

    /// An acceptable file is being dragged over the icon. The popover does not activate the
    /// app when it springs open mid-drag.
    var isReceivingDrag: Bool { dropTarget.isHovering }

    /// Called when the icon moves: placed in the menu bar after launch, moved by the user,
    /// or carried to another display's menu bar.
    var onAnchorChange: (() -> Void)?

    /// Called after files dropped on the icon are queued (the popover may have sprung open).
    var onFilesDropped: (() -> Void)?

    // MARK: Setup

    private func configureButton() {
        guard let button = statusItem.button else {
            Log.error("status item has no button")
            return
        }
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Booth")
        button.image = GlyphRenderer.image(.idle, ink: menuBarInk)

        let dropView = StatusItemDropView(target: dropTarget)
        dropView.frame = button.bounds
        dropView.autoresizingMask = [.width, .height]
        button.addSubview(dropView)
        Log.info("status item ready")
    }

    private func observeEnvironment() {
        // Template modes follow the menu bar by themselves; the coloured working image has to be
        // redrawn when the menu bar flips between light and dark.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.redraw() }
        }
        // The status item's window is only placed in the menu bar after launch finishes.
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.windowDidMove(notification.object as? NSWindow) }
            }
            windowMoveObservers.append(observer)
        }
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.modelDidChange() }
        }
        // A long job can run for an hour with the displays asleep; the lamp stops breathing then.
        for name in [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.visibilityDidChange(notification.name) }
            }
            visibilityObservers.append(observer)
        }
    }

    private func configureDropTarget() {
        dropTarget.onHoverChange = { [weak self] hovering in
            self?.dragHoverChanged(hovering)
        }
        dropTarget.onDrop = { [weak self] urls in
            guard let self else { return }
            Log.info("dropped on the menu bar icon: \(urls.map(\.lastPathComponent).joined(separator: ", "))")
            model.enqueue(urls)
            onFilesDropped?()
        }
    }

    // MARK: Events

    private func windowDidMove(_ window: NSWindow?) {
        guard let window, window === statusItem.button?.window else { return }
        Log.info("status item at \(NSStringFromRect(window.frame))")
        onAnchorChange?()
    }

    private func visibilityDidChange(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: displaysAsleep = true
        case NSWorkspace.screensDidWakeNotification: displaysAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: return
        }
        redraw()
        updateFrameTimer()
    }

    @objc private func buttonClicked() {
        model.toggleOpen()
        applyHighlight()
    }

    private func dragHoverChanged(_ hovering: Bool) {
        model.iconTarget = hovering
        springLoadTimer?.invalidate()
        springLoadTimer = nil
        guard hovering else { return }
        let timer = Timer(timeInterval: Self.springLoadDelay, target: self, selector: #selector(springLoad), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        springLoadTimer = timer
    }

    /// Main.dc.html: a file held over the icon for 0.7 s opens the popover on `viewOnOpen`.
    @objc private func springLoad() {
        springLoadTimer = nil
        guard dropTarget.isHovering, !model.isOpen else { return }
        Log.info("spring-loaded open")
        model.open()
    }

    // MARK: Rendering

    private func modelDidChange() {
        mode = model.glyphMode
        let isOpen = model.isOpen
        let pulse = model.pulse
        updateAccessibilityValue()

        let reduceMotion = Motion.prefersReducedMotion
        let targetScale: Double
        if mode == .target {
            targetScale = Self.targetScale
        } else if pulse && !reduceMotion {
            targetScale = Self.pulseScale
        } else {
            targetScale = 1
        }
        scale.retarget(targetScale, duration: reduceMotion ? 0 : Self.scaleDuration, at: CACurrentMediaTime())

        let highlighted = isOpen || mode == .target
        if highlighted != isHighlighted {
            isHighlighted = highlighted
            applyHighlight()
        }
        redraw()
        updateFrameTimer()
    }

    /// A click clears the button's highlight when its tracking ends, after the action has run,
    /// so the highlight is (re)applied on the next turn of the run loop.
    private func applyHighlight() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem.button?.highlight(isHighlighted)
        }
    }

    private func redraw() {
        guard let button = statusItem.button else { return }
        let now = CACurrentMediaTime()
        let breathe = Motion.prefersReducedMotion || !isVisible
            ? 1 // Reduce Motion, or nobody to see it: the lamp stays lit and does not breathe.
            : GlyphRenderer.breathe(atPhase: now.truncatingRemainder(dividingBy: GlyphRenderer.breathPeriod) / GlyphRenderer.breathPeriod)
        button.image = GlyphRenderer.image(mode, breathe: breathe, scale: scale.value(at: now), ink: menuBarInk)
    }

    /// Someone could be looking at the menu bar.
    private var isVisible: Bool { !displaysAsleep && !sessionInactive }

    /// 60 fps while the icon grows or shrinks, 24 fps while the lamp breathes, otherwise idle.
    private func updateFrameTimer() {
        let interval: TimeInterval?
        if !scale.isSettled(at: CACurrentMediaTime()) {
            interval = 1.0 / 60
        } else if mode == .working && !Motion.prefersReducedMotion && isVisible {
            interval = 1.0 / 24
        } else {
            interval = nil
        }
        guard interval != frameInterval else { return }
        frameTimer?.invalidate()
        frameTimer = nil
        frameInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(frameTick), userInfo: nil, repeats: true)
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    @objc private func frameTick() {
        redraw()
        updateFrameTimer()
    }

    /// The menu bar's own text colour, for the one non-template image.
    private var menuBarInk: NSColor {
        let isDark = statusItem.button?.effectiveAppearance.isDark ?? NSApp.effectiveAppearance.isDark
        return isDark ? .white : NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
    }

    private func updateAccessibilityValue() {
        let value: String?
        switch mode {
        case .working: value = model.statusLine ?? (model.setup.isRunning ? "Setting up" : nil)
        case .done: value = "Finished"
        case .attention: value = "Needs attention"
        case .idle, .target: value = nil
        }
        statusItem.button?.setAccessibilityValue(value)
    }
}

/// Lies over the status bar button and receives file drags for it.
///
/// AppKit picks the drag destination by hit-testing, so this view has to be hittable; it hands
/// ordinary clicks straight to the button underneath so the icon still behaves natively.
private final class StatusItemDropView: NSView {
    private let target: FileDropTarget

    init(target: FileDropTarget) {
        self.target = target
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        target.draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        target.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        target.draggingExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        target.performDrop(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        target.draggingEnded()
    }
}
