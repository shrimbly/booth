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

    /// The name macOS gives an app's first status item, and a second one the icon takes turns
    /// with while it settles: changing names makes macOS place it by the new name's position.
    private static let itemName = "Item-0"
    private static let settlingName = "Booth settling"
    /// The first launch's search for the icon's place; nil once it has settled.
    private var settling: MenuBarPlacement.Search?
    private var settlingCheck: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        let firstPosition = Self.placeOnFirstLaunch()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        settling = firstPosition.map { MenuBarPlacement.Search(position: $0) }
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

    /// Where macOS keeps an icon's place, by the icon's name (`MenuBarPlacement`).
    private static func positionKey(_ name: String) -> String {
        "NSStatusItem Preferred Position \(name)"
    }

    /// macOS adds a new icon at the left end of the others, which on a full menu bar is behind
    /// the camera housing or off the screen, so a first launch shows no icon at all. Until it is
    /// moved, Booth's goes fourth from the right instead (`MenuBarPlacement`): this is the first
    /// guess, which `settle()` corrects once the icon is drawn. Nil after the first launch.
    private static func placeOnFirstLaunch() -> Double? {
        let key = positionKey(itemName)
        guard UserDefaults.standard.object(forKey: key) == nil else { return nil }
        let menuBar = menuBarIcons()
        let guess = menuBar.flatMap { menuBar in
            MenuBarPlacement.preferredPosition(icons: menuBar.icons.map { ($0.minX, $0.maxX) }, screenMaxX: menuBar.screenMaxX)
        }
        UserDefaults.standard.set(guess ?? 0, forKey: key)
        Log.info("status item: first placement, preferred position \(Int(guess ?? 0)) among \(menuBar?.icons.count ?? 0) icons")
        return guess ?? 0
    }

    /// The icons in the main display's menu bar, from the window list: their frames need no
    /// permission (their names would).
    private static func menuBarIcons() -> (icons: [(number: Int, minX: Double, maxX: Double)], screenMaxX: Double)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let icons = windows.compactMap { window -> (number: Int, minX: Double, maxX: Double)? in
            guard window[kCGWindowLayer as String] as? Int == level,
                  let number = window[kCGWindowNumber as String] as? Int,
                  // Stand-ins the window server draws while an icon is dragged.
                  window[kCGWindowOwnerName as String] as? String != "Window Server",
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  // In the main display's menu bar (window-list coordinates start at its top left).
                  frame.minY < 2, frame.height < 60, frame.width >= 12,
                  frame.minX >= screen.frame.minX, frame.maxX <= screen.frame.maxX + 4
            else { return nil }
            return (number, Double(frame.minX), Double(frame.maxX))
        }
        return (icons, Double(screen.frame.maxX))
    }

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
        Log.info("status item at \(NSStringFromRect(window.frame))\(Self.isHidden(window.frame) ? " (hidden: off the screen or behind the camera housing)" : "")")
        onAnchorChange?()
        if settling != nil { checkSettling(after: 0.25) }
    }

    /// Off every screen, or partly under a camera housing (between the menu bar's two halves).
    private static func isHidden(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) else {
            return true
        }
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        return frame.maxX > left.maxX && frame.minX < right.minX
    }

    // MARK: Settling the first placement

    private func checkSettling(after delay: TimeInterval) {
        settlingCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
        settlingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }

    /// Counts the movable icons between Booth's and Control Centre, and moves it until there
    /// are three (`MenuBarPlacement.Search`).
    private func settle() {
        guard var search = settling, let window = statusItem.button?.window,
              // Placed in a menu bar at all, hidden or not.
              window.frame.minY >= 0,
              let menuBar = Self.menuBarIcons()
        else { return }
        let others = menuBar.icons.filter { $0.number != window.windowNumber }
        let available = max(0, others.count - MenuBarPlacement.fixedIcons)
        let toTheRight = max(0, others.filter { $0.minX >= window.frame.maxX - 1 }.count - MenuBarPlacement.fixedIcons)
        if let next = search.next(iconsToTheRight: toTheRight, available: available) {
            settling = search
            move(to: next)
        } else {
            settling = nil
            keep(search.position)
            Log.info("status item: settled with \(toTheRight) of \(available) icons between it and Control Centre (preferred position \(Int(search.position)))")
        }
    }

    /// Places the icon by `position`. macOS rereads a position when the icon's name changes, so
    /// the icon takes turns between its two.
    private func move(to position: Double) {
        let name = statusItem.autosaveName == Self.settlingName ? Self.itemName : Self.settlingName
        UserDefaults.standard.set(position, forKey: Self.positionKey(name))
        statusItem.autosaveName = name
        Log.info("status item: trying preferred position \(Int(position))")
        checkSettling(after: 0.4)
    }

    /// Ends under its usual name at `position`, and leaves nothing of the other behind.
    private func keep(_ position: Double) {
        let defaults = UserDefaults.standard
        if statusItem.autosaveName != Self.itemName {
            defaults.set(position, forKey: Self.positionKey(Self.itemName))
            statusItem.autosaveName = Self.itemName
        }
        defaults.removeObject(forKey: Self.positionKey(Self.settlingName))
        defaults.removeObject(forKey: "NSStatusItem Visible \(Self.settlingName)")
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
