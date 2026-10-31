import AppKit
import SwiftUI

/// Where the popover is being drawn.
enum PopoverChrome: Equatable {
    /// Inside the menu bar panel. The background is the shell's frosted glass, the signature
    /// animates, and system monitors (⌥ for compare) run.
    case live
    /// `--render-states`: the view draws its own solid glass panel and freezes every clock so
    /// the PNGs are deterministic.
    case snapshot
}

/// When the live popover last opened from closed, and the point on its glass's top edge it grows
/// from (under the menu bar icon), so the signature can play its reveal against the opening.
struct PopoverOpening: Equatable {
    var start: Date
    /// From the glass's left edge.
    var pivotX: CGFloat
}

private struct PopoverOpeningKey: EnvironmentKey {
    static let defaultValue: PopoverOpening? = nil
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

private struct PopoverChromeKey: EnvironmentKey {
    static let defaultValue = PopoverChrome.live
}

private struct SnapshotClockKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct SnapshotPosterKey: EnvironmentKey {
    static let defaultValue: NSImage? = nil
}

extension EnvironmentValues {
    /// The popover's colour tokens, resolved once from the colour scheme by `PopoverRootView`.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    /// Nil outside the live panel (snapshots, previews): the signature shows at rest.
    var popoverOpening: PopoverOpening? {
        get { self[PopoverOpeningKey.self] }
        set { self[PopoverOpeningKey.self] = newValue }
    }

    var popoverChrome: PopoverChrome {
        get { self[PopoverChromeKey.self] }
        set { self[PopoverChromeKey.self] = newValue }
    }

    /// Snapshots only: the moment, in milliseconds, the working bar's ripples are drawn at. Nil
    /// holds their still moment; `--render-demo` steps it to draw the frames of a video.
    var snapshotClock: Double? {
        get { self[SnapshotClockKey.self] }
        set { self[SnapshotClockKey.self] = newValue }
    }

    /// Snapshots only: a still of the video for the Done screen's picture. Nil draws the stand-in
    /// poster; `--render-demo` passes a frame of a real video.
    var snapshotPoster: NSImage? {
        get { self[SnapshotPosterKey.self] }
        set { self[SnapshotPosterKey.self] = newValue }
    }
}
