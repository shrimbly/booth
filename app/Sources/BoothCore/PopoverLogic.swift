import Foundation

/// The popover's screens (Popover.dc.html `view`).
public enum PopoverScreen: String, CaseIterable, Sendable {
    case firstrun, idle, working, done, settings, error

    /// Every screen but Settings takes a dropped file.
    public var acceptsDrops: Bool { self != .settings }

    /// The gear sits on the drop zone, setup and Done. Working is all progress bar.
    public var showsGear: Bool { self == .idle || self == .firstrun }

    /// The "Booth" signature belongs to the drop zone and setup only.
    public var showsSignature: Bool { self == .idle || self == .firstrun }
}

/// The border around the popover's frame.
public enum FrameStyle: Sendable {
    /// No border: every screen but the drop zone.
    case none
    /// The drop zone's dotted outline.
    case dotted
    /// A file is over a screen that takes it: a solid outline on a faint fill.
    case dropTarget
}

/// Menu bar icon states (Glyph.dc.html, brand "booth").
public enum GlyphMode: String, CaseIterable, Sendable {
    case idle, target, working, done, attention

    /// Working is drawn in colour; every other mode is a template image.
    public var isTemplate: Bool { self != .working }
}

/// The inputs the prototype's view logic reads, as plain values.
public struct PopoverContext: Equatable, Sendable {
    public var isOpen: Bool
    /// The screen the app asked for (`s.view`); the one shown is `PopoverLogic.effectiveScreen`.
    public var requested: PopoverScreen
    /// Setup is running or failed (`s.setup < 1`).
    public var setupIncomplete: Bool
    public var setupFailed: Bool
    /// An error is waiting to be read (`s.errorFile`).
    public var hasError: Bool
    /// `s.activeId`
    public var hasActiveJob: Bool
    /// `s.focusId`
    public var hasFocus: Bool
    /// The focused job exists and is done.
    public var focusIsDone: Bool
    /// A job finished while the popover was closed.
    public var unseen: Bool
    /// A file is being dragged over the menu bar icon.
    public var iconTarget: Bool
    /// The focused job has just finished on Working, which shows it full for a moment before
    /// Done takes over.
    public var focusIsFinishing: Bool

    public init(
        isOpen: Bool = false, requested: PopoverScreen = .idle, setupIncomplete: Bool = false,
        setupFailed: Bool = false, hasError: Bool = false, hasActiveJob: Bool = false,
        hasFocus: Bool = false, focusIsDone: Bool = false, unseen: Bool = false, iconTarget: Bool = false,
        focusIsFinishing: Bool = false
    ) {
        self.isOpen = isOpen
        self.requested = requested
        self.setupIncomplete = setupIncomplete
        self.setupFailed = setupFailed
        self.hasError = hasError
        self.hasActiveJob = hasActiveJob
        self.hasFocus = hasFocus
        self.focusIsDone = focusIsDone
        self.unseen = unseen
        self.iconTarget = iconTarget
        self.focusIsFinishing = focusIsFinishing
    }
}

/// Main.dc.html's view logic as pure functions.
public enum PopoverLogic {
    /// The screen to show when the popover opens (`viewOnOpen`).
    public static func viewOnOpen(_ c: PopoverContext) -> PopoverScreen {
        if c.setupIncomplete { return .firstrun }
        if c.hasError { return .error }
        if c.hasActiveJob { return .working }
        if c.unseen { return .done }
        if c.requested == .done && c.hasFocus { return .done }
        if c.requested == .settings { return .settings }
        return .idle
    }

    /// The screen actually shown for the requested one (`effectiveView`): a request for a
    /// screen whose data is gone falls back gracefully.
    public static func effectiveScreen(_ c: PopoverContext) -> PopoverScreen {
        switch c.requested {
        case .settings:
            return .settings
        case _ where c.setupIncomplete:
            return .firstrun
        case .error where c.hasError:
            return .error
        case .working:
            if c.hasActiveJob || c.focusIsFinishing { return .working }
            return c.focusIsDone ? .done : .idle
        case .done:
            return c.focusIsDone ? .done : .idle
        case .firstrun, .error, .idle:
            return .idle
        }
    }

    /// The menu bar icon's state.
    public static func glyphMode(_ c: PopoverContext) -> GlyphMode {
        if c.iconTarget { return .target }
        if (c.hasError || c.setupFailed) && !c.isOpen { return .attention }
        if c.hasActiveJob || (c.setupIncomplete && !c.setupFailed) { return .working }
        if c.unseen { return .done }
        return .idle
    }

    /// The dotted outline marks the drop zone only; any screen that takes files shows the
    /// drop-target outline while one is over it.
    public static func frameStyle(screen: PopoverScreen, dropHover: Bool) -> FrameStyle {
        if dropHover && screen.acceptsDrops { return .dropTarget }
        return screen == .idle ? .dotted : .none
    }
}
