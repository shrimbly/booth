import BoothCore
import Foundation

/// The real app's dependencies: the live engine side plus the live system side.
@MainActor
func makeLiveDependencies(options: LaunchOptions, settings: Settings) -> AppDependencies {
    AppDependencies(engine: makeLiveEngineServices(options: options, settings: settings), system: makeLiveSystemServices())
}

/// The real engine: the `booth` CLI found by `EngineLocator`, run as child processes, and
/// an AVAudioEngine preview. `options.enginePath` is the `--engine` override and
/// `settings.enginePath` the stored one (SPEC §2.3 resolution order).
@MainActor
func makeLiveEngineServices(options: LaunchOptions, settings: Settings) -> EngineServices {
    let toolchain = EngineToolchain()
    let locator = EngineLocator(
        toolchain: toolchain, launchArgument: options.enginePath, storedPreference: { settings.enginePath })
    // Jobs aren't persisted, so nothing from an earlier launch can be played or saved again:
    // keep none, but spare the last hour's folders, which may be another Booth's live job.
    JobCache.pruneInBackground(root: AppModel.defaultStemsRoot, keep: 0, sparingWithin: JobCachePolicy.launchGracePeriod)
    return EngineServices(
        locator: locator,
        jobs: EngineJobRunner(locator: locator),
        setup: SetupRunner(locator: locator, installer: ManagedEngineInstaller(toolchain: toolchain)),
        remixer: EngineRemixer(locator: locator),
        player: PreviewPlayer(),
        compareKey: OptionKeyMonitor())
}
