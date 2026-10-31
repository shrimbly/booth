import AppKit

/// Watches ⌥ for "Hold ⌥ to compare" by polling `NSEvent.modifierFlags` at 30 Hz while started.
/// Polling works whether or not Booth is frontmost and needs no Accessibility permission, which
/// a global event monitor for flag changes would.
@MainActor
final class OptionKeyMonitor: CompareKeyWatching {
    static let interval: TimeInterval = 1.0 / 30

    private let readFlags: () -> NSEvent.ModifierFlags
    private var timer: Timer?
    private var onChange: (@MainActor (Bool) -> Void)?
    private var isHeld = false

    init(readFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) {
        self.readFlags = readFlags
    }

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isHeld {
            isHeld = false
            onChange?(false)
        }
        onChange = nil
    }

    /// ⌥ alone: ⌘⌥ and ⌃⌥ are shortcuts, not a request to compare.
    static func isCompareChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option, .shift]) == .option
    }

    func poll() {
        guard onChange != nil else { return }
        let held = Self.isCompareChord(readFlags())
        guard held != isHeld else { return }
        isHeld = held
        onChange?(held)
    }
}
