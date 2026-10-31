import Foundation

/// First-run setup can have two phases: installing the managed engine (`uv sync`, measured by
/// how much its virtual environment has grown) and downloading models (`setup --events`, which
/// reports bytes itself). The First run screen shows one bar, so this folds both into a single
/// `SetupProgress`: install bytes first, model bytes after.
public struct SetupProgressCombiner: Equatable, Sendable {
    public static let installPhase = "engine"
    public static let installLabel = "Installing the engine"
    /// The engine's virtual environment after `uv sync` from uv.lock (torch dominates): 537 MB
    /// measured on arm64.
    public static let typicalEnvironmentBytes: Int64 = 540_000_000
    /// What `setup --events` downloads when nothing is cached (SPEC §1.2).
    public static let typicalModelBytes: Int64 = 1_130_000_000

    /// 0 when the engine is already installed and only models are missing.
    public let installBytesExpected: Int64
    /// The model download size: an estimate until the engine reports its real total.
    public private(set) var modelBytesTotal: Int64

    public init(installBytesExpected: Int64, modelBytesTotal: Int64 = typicalModelBytes) {
        self.installBytesExpected = max(0, installBytesExpected)
        self.modelBytesTotal = max(0, modelBytesTotal)
    }

    /// The install phase after `elapsed` seconds, with the environment `bytesInstalled` larger
    /// than when it started. The real final size is only known at the end, so progress stops
    /// just short of the estimate instead of overshooting it.
    public func installing(bytesInstalled: Int64, elapsed: TimeInterval) -> SetupProgress {
        let done = min(max(0, bytesInstalled), installBytesExpected * 98 / 100)
        let total = installBytesExpected + modelBytesTotal
        var eta: Double?
        if elapsed >= 3, done > 0 {
            // Downloads usually move at about the speed packages arrived.
            let bytesPerSecond = Double(done) / elapsed
            eta = Double(total - done) / bytesPerSecond
        }
        return SetupProgress(
            phase: Self.installPhase, label: Self.installLabel, bytesDone: done, bytesTotal: total, eta: eta)
    }

    /// The model phase: the engine's own event, shifted past the finished install.
    public mutating func downloading(_ event: SetupProgress) -> SetupProgress {
        // An engine that reports `progress` also reports its real total, which is 0 when
        // nothing needs downloading; without it, 0 only means "not known yet".
        if event.bytesTotal > 0 || event.progress != nil { modelBytesTotal = max(0, event.bytesTotal) }
        let modelTotal = max(modelBytesTotal, event.bytesDone)
        let total = installBytesExpected + modelTotal
        let progress = event.progress.map { fraction in
            total > 0 ? (Double(installBytesExpected) + fraction * Double(modelTotal)) / Double(total) : fraction
        }
        return SetupProgress(
            phase: event.phase, label: event.label,
            bytesDone: installBytesExpected + max(0, event.bytesDone),
            bytesTotal: total,
            eta: event.eta,
            progress: progress)
    }
}
