import Foundation

/// Byte-level progress of first-run setup.
public struct SetupProgressInfo: Equatable, Sendable {
    public var phase: String
    public var label: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// Seconds remaining, when the engine has estimated it.
    public var eta: Double?
    /// The engine's own overall fraction, when it reports one (see `SetupProgress.progress`).
    public var progress: Double?

    public init(
        phase: String = "", label: String = "", bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
        eta: Double? = nil, progress: Double? = nil
    ) {
        self.phase = phase
        self.label = label
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.eta = eta
        self.progress = progress
    }

    public init(_ event: SetupProgress) {
        self.init(
            phase: event.phase ?? "", label: event.label ?? "",
            bytesDone: event.bytesDone, bytesTotal: event.bytesTotal, eta: event.eta, progress: event.progress)
    }

    /// 0…1: the engine's fraction when it gives one, else bytes done over the total (0 until
    /// the total is known).
    public var fraction: Double {
        if let progress { return min(1, max(0, progress)) }
        guard bytesTotal > 0 else { return 0 }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }
}

/// Whether the engine can take jobs.
public enum SetupState: Equatable, Sendable {
    /// Launch: the engine is being located. Jobs wait, but no setup screen is shown.
    case checking
    /// The engine's `app-info` is slow to answer (often a macOS prompt about the folder it
    /// lives in, `folder` as the user would write it). Jobs wait; the First run screen says so.
    case waitingForEngine(folder: String)
    case ready
    /// Installing models (the First run screen).
    case running(SetupProgressInfo)
    case failed(message: String)

    public var isReady: Bool { self == .ready }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isWaitingForEngine: Bool {
        if case .waitingForEngine = self { return true }
        return false
    }

    /// Running, waiting for the engine, or failed: the popover shows the First run screen.
    public var showsSetupScreen: Bool { isRunning || isFailed || isWaitingForEngine }

    /// Progress for the first-run bar and the working glyph; 1 once ready.
    public var fraction: Double {
        switch self {
        case .ready: 1
        case .running(let info): info.fraction
        case .checking, .waitingForEngine, .failed: 0
        }
    }

    /// Folds a `setup --events` event into the state.
    public mutating func apply(_ event: EngineEvent) {
        switch event {
        case .setup(let progress):
            self = .running(SetupProgressInfo(progress))
        case .done:
            self = .ready
        case .error(let error):
            self = .failed(message: error.message)
        case .setupStatus(let status) where status.ready:
            self = .ready
        default:
            break
        }
    }
}
