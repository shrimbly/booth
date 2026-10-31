import BoothCore
import Foundation

/// Finds the engine (SPEC §2.3): `--engine`, the `enginePath` preference, `BOOTH_ENGINE`, the
/// Info.plist `BoothEnginePath`, the managed install, `~/.local/bin`, then the login shell's
/// PATH. The first candidate whose `app-info` answers with protocol 1 wins. A ready answer is
/// cached; the runner, setup and remixer use `installation`.
///
/// A slow `app-info` is not a broken engine: macOS may be asking whether Booth may access the
/// folder the engine lives in. After `validationTimeout` the search says it is waiting and keeps
/// waiting on the same process up to `responseTimeout`. If that passes too, the search stops at
/// that candidate (`.unresponsive`): lower-priority engines are not tried and setup must not
/// create a managed install over an engine that exists. Only when every candidate is absent or
/// broken does the search answer `.needsSetup(nil)`.
///
/// Two candidates are not taken as they are:
/// - The `booth` command inside Booth.app (also reached through Homebrew's link to it) is
///   skipped. It is a launcher for the managed install that would install the engine itself.
/// - A managed install older than the engine bundled with Booth, or whose last install never
///   finished, is not run: the search stops there with `.needsSetup(nil)` and
///   `managedInstallNeedsUpdate`, and setup updates it.
@MainActor
final class EngineLocator: EngineLocating {
    /// What one `app-info` run said about a candidate.
    enum Probe: Equatable {
        case valid(EngineInfo)
        /// Not executable, could not launch, exited without an info event, or another protocol.
        case rejected
        /// No answer within `responseTimeout`.
        case unresponsive
    }

    let toolchain: EngineToolchain
    /// When a slow `app-info` is reported as waiting (SPEC §2.3: five seconds).
    private let validationTimeout: TimeInterval
    /// How long `app-info` may take in all before its candidate counts as unresponsive.
    private let responseTimeout: TimeInterval
    private let launchArgument: String?
    private let storedPreference: () -> String?
    private let environment: [String: String]
    private let infoPlistPath: String?
    /// The engine source a managed install must match; nil skips the check.
    private let bundledEngineSource: URL?
    /// Booth.app, whose own files are never engines; nil when running unbundled.
    private let ownBundle: URL?

    /// The engine the last search (or setup) settled on, ready or not.
    private(set) var installation: EngineInstallation?
    private var installationSource: EngineCandidate.Source?
    private var cachedReady: EngineInstallation?
    /// The candidate the last search (or refresh) gave up on because it never answered.
    private(set) var unresponsiveCandidate: EngineCandidate?

    /// The last search stopped at an engine that didn't answer. Setup must not install then.
    var lastSearchTimedOut: Bool { unresponsiveCandidate != nil }

    /// The last search stopped at a managed install that doesn't match the bundled engine.
    private(set) var managedInstallNeedsUpdate = false

    init(
        toolchain: EngineToolchain,
        launchArgument: String?,
        storedPreference: @escaping () -> String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoPlistPath: String? = Bundle.main.object(forInfoDictionaryKey: EngineSearch.infoPlistKey) as? String,
        bundledEngineSource: URL? = ManagedEngineInstaller.bundledSource(),
        ownBundle: URL? = AppResources.isBundled ? Bundle.main.bundleURL : nil,
        validationTimeout: TimeInterval = 5,
        responseTimeout: TimeInterval = 180
    ) {
        self.toolchain = toolchain
        self.validationTimeout = validationTimeout
        self.responseTimeout = max(responseTimeout, validationTimeout)
        self.launchArgument = launchArgument
        self.storedPreference = storedPreference
        self.environment = environment
        self.infoPlistPath = infoPlistPath
        self.bundledEngineSource = bundledEngineSource
        self.ownBundle = ownBundle?.resolvingSymlinksInPath()
    }

    func locate(onWaiting: @escaping @MainActor (EngineCandidate) -> Void = { _ in }) async -> EngineAvailability {
        if let cachedReady { return .ready(cachedReady) }
        unresponsiveCandidate = nil
        managedInstallNeedsUpdate = false
        await toolchain.prepare()

        let candidates = EngineSearch.candidates(
            launchArgument: launchArgument, storedPreference: storedPreference(), environment: environment,
            infoPlistPath: infoPlistPath, home: toolchain.home)
        for candidate in candidates {
            if let settled = await consider(candidate, onWaiting: onWaiting) { return settled }
            if Task.isCancelled { return cancelled() }
        }
        if let path = await LoginShell.commandPath(EngineSearch.executableName, environment: toolchain.environment),
           !candidates.contains(where: { $0.path == path }),
           let settled = await consider(EngineCandidate(path: path, source: .loginShell), onWaiting: onWaiting) {
            return settled
        }
        Log.error("engine: no valid candidate; first-run setup will install one")
        installation = nil
        installationSource = nil
        return .needsSetup(nil)
    }

    /// Re-reads `app-info` for the current engine after setup changed what is installed.
    func refresh() async -> EngineAvailability {
        cachedReady = nil
        guard let current = installation else { return await locate() }
        let candidate = EngineCandidate(path: current.executable.path, source: installationSource ?? .managedInstall)
        switch await probe(current.executable, source: candidate.source) {
        case .valid(let info):
            return settle(on: EngineInstallation(executable: current.executable, info: info), source: candidate.source)
        case .unresponsive:
            return giveUp(on: candidate)
        case .rejected:
            return await locate()
        }
    }

    /// Adopts an engine first-run setup just installed.
    func adopt(_ found: EngineInstallation) -> EngineAvailability {
        managedInstallNeedsUpdate = false
        return settle(on: found, source: .managedInstall)
    }

    /// Runs `<path> app-info` once and checks the protocol. Logs every outcome.
    ///
    /// `onSlow` fires if there is no answer after `validationTimeout`; the same process is then
    /// given until `responseTimeout` before the candidate counts as unresponsive.
    func probe(
        _ executable: URL, source: EngineCandidate.Source? = nil, onSlow: (@MainActor () -> Void)? = nil
    ) async -> Probe {
        let label = "engine \(executable.path)" + (source.map { " [\($0.rawValue)]" } ?? "")
        let process = EngineProcess(
            executable: executable, arguments: ["app-info"], workingDirectory: nil,
            environment: toolchain.environment, label: "app-info")
        let started = Date()
        var wasSlow = false
        let validationTimeout = validationTimeout
        let responseTimeout = responseTimeout
        do {
            let (events, exit) = try await process.runToCompletion(
                timeout: responseTimeout, slowAfter: validationTimeout,
                onSlow: {
                    wasSlow = true
                    Log.info("\(label): app-info has not answered after \(Self.seconds(validationTimeout)) s; waiting up to \(Self.seconds(responseTimeout)) s (macOS may be asking whether Booth may access this folder)")
                    onSlow?()
                })
            let info = events.lazy.compactMap { event -> EngineInfo? in
                if case .info(let info) = event { return info }
                return nil
            }.last
            if wasSlow {
                let elapsed = Self.seconds(Date().timeIntervalSince(started))
                Log.info(info != nil ? "\(label): app-info answered after \(elapsed) s" : "\(label): app-info ended after \(elapsed) s")
            }
            guard let info else {
                if exit.timedOut {
                    Log.error("\(label): app-info did not answer within \(Self.seconds(responseTimeout)) s")
                    return .unresponsive
                }
                Log.error("\(label): app-info gave no info event (exit \(exit.status)) \(exit.stderrTail.lastMeaningfulLine ?? "")")
                return .rejected
            }
            guard info.protocolVersion == engineProtocolVersion else {
                Log.error("\(label): protocol \(info.protocolVersion), Booth speaks \(engineProtocolVersion)")
                return .rejected
            }
            return .valid(info)
        } catch {
            Log.error("\(label): \(error.localizedDescription)")
            return .rejected
        }
    }

    // MARK: - Private

    /// The search's answer if `candidate` settles it (valid, or unresponsive), nil to go on.
    private func consider(
        _ candidate: EngineCandidate, onWaiting: @escaping @MainActor (EngineCandidate) -> Void
    ) async -> EngineAvailability? {
        let path = candidate.path
        let source = candidate.source.rawValue
        guard FileManager.default.isExecutableFile(atPath: path) else {
            Log.info("engine candidate \(path) [\(source)]: not found")
            return nil
        }
        let executable = URL(fileURLWithPath: path)
        if let ownBundle, EngineSearch.isInside(executable.resolvingSymlinksInPath().path, directory: ownBundle.path) {
            Log.info("engine candidate \(path) [\(source)]: Booth's own `booth` command, not an engine; skipped")
            return nil
        }
        if candidate.source == .managedInstall,
           !ManagedEngineInstaller.isCurrent(home: toolchain.home, source: bundledEngineSource) {
            Log.info("engine candidate \(path) [\(source)]: doesn't match the engine bundled with Booth; setup will update it")
            installation = nil
            installationSource = nil
            managedInstallNeedsUpdate = true
            return .needsSetup(nil)
        }
        switch await probe(executable, source: candidate.source, onSlow: { onWaiting(candidate) }) {
        case .valid(let info):
            let readiness = info.ready ? "ready" : "missing \(info.missing.joined(separator: ", "))"
            Log.info("engine candidate \(path) [\(source)]: version \(info.version), \(readiness)")
            return settle(on: EngineInstallation(executable: executable, info: info), source: candidate.source)
        case .rejected:
            Log.info("engine candidate \(path) [\(source)]: rejected")
            return nil
        case .unresponsive:
            return giveUp(on: candidate)
        }
    }

    private func settle(on found: EngineInstallation, source: EngineCandidate.Source) -> EngineAvailability {
        installation = found
        installationSource = source
        unresponsiveCandidate = nil
        guard found.info.ready else {
            cachedReady = nil
            return .needsSetup(found)
        }
        cachedReady = found
        return .ready(found)
    }

    /// Quitting: launch nothing more. Nobody acts on the answer.
    private func cancelled() -> EngineAvailability {
        Log.info("engine: search cancelled")
        installation = nil
        installationSource = nil
        return .needsSetup(nil)
    }

    private func giveUp(on candidate: EngineCandidate) -> EngineAvailability {
        Log.error("engine candidate \(candidate.path) [\(candidate.source.rawValue)]: not answering; the search stops here (no other engine is tried and nothing is installed)")
        installation = nil
        installationSource = nil
        cachedReady = nil
        unresponsiveCandidate = candidate
        return .unresponsive(candidate)
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
