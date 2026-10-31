import AppKit
import BoothCore

/// Builds the model, then the shell around it: the menu bar icon, the popover, ⌃⌥E, the Finder
/// Quick Action, notifications and files opened with Booth.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private(set) var model: AppModel?
    private var statusItem: StatusItemController?
    private var panel: PopoverPanelController?
    private var selectionShortcut: SelectionShortcut?
    private var servicesProvider: ServicesProvider?
    /// Nil when notifications are unavailable (outside an app bundle).
    private var notifier: UserNotifier?
    /// Files opened before the shell exists (`open -a Booth file.wav` at launch).
    private var pendingURLs: [URL] = []
    private var signalSources: [DispatchSourceSignal] = []

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if options.resetDefaults {
            Settings.resetStoredValues()
            Log.info("defaults reset")
        }
        BundledFonts.registerIfNeeded()
        let settings = Settings()
        let dependencies = options.demo
            ? AppDependencies(engine: .demo(), system: makeLiveSystemServices())
            : makeLiveDependencies(options: options, settings: settings)
        model = AppModel(settings: settings, dependencies: dependencies, finishHold: AppModel.finishHold)
        Log.info(options.demo ? "demo mode" : "live mode")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let statusItem = StatusItemController(model: model)
        let panel = PopoverPanelController(model: model) { [weak statusItem] in statusItem?.anchorRect }
        panel.isDragInProgress = { [weak statusItem] in statusItem?.isReceivingDrag ?? false }
        statusItem.onAnchorChange = { [weak panel] in panel?.anchorDidChange() }
        statusItem.onFilesDropped = { [weak panel] in panel?.takeKeyAfterDrop() }
        self.statusItem = statusItem
        self.panel = panel
        selectionShortcut = SelectionShortcut(model: model)

        let servicesProvider = ServicesProvider { [weak model] urls in model?.enqueue(urls) }
        self.servicesProvider = servicesProvider
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()

        if let notifier = model.dependencies.system.notifier as? UserNotifier {
            self.notifier = notifier
            followModel(model, with: notifier)
        }
        terminateCleanlyOnSignals()
        model.launch()

        let launchFiles = options.enqueue + pendingURLs
        pendingURLs = []
        if !launchFiles.isEmpty { model.enqueue(launchFiles) }
        if options.openAtLaunch { model.open() }
    }

    /// Open With, a drop on Booth in the Finder, or `open -a Booth file.wav`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model, statusItem != nil else {
            pendingURLs += urls
            return
        }
        Log.info("open: \(urls.map(\.path).joined(separator: ", "))")
        model.enqueue(urls)
    }

    /// Launching Booth again while it runs (Finder, Spotlight) opens the popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.open()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        // Jobs live only as long as Booth: a banner left in Notification Centre would point at
        // a job the next launch has never heard of, and its buttons would do nothing. The
        // removal is handed to the notification daemon and does not hold up quitting.
        notifier?.removeDeliveredNotifications()
        Log.info("terminated")
        Log.flush()
    }

    /// Ask for notification permission when the first job starts, and clear delivered banners
    /// once the popover shows what they announced.
    private func followModel(_ model: AppModel, with notifier: UserNotifier) {
        observeChanges(owner: notifier) { [weak model] notifier in
            guard let model else { return }
            if model.activeID != nil { notifier.askForPermissionIfNeeded() }
            if model.isOpen { notifier.removeDeliveredNotifications() }
        }
    }

    /// SIGTERM/SIGINT would otherwise kill the app outright, orphaning engine processes (they
    /// run in their own process group). Route them through a normal quit instead.
    private func terminateCleanlyOnSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Log.info("received signal \(signalNumber): quitting")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
