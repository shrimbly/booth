import BoothCore
import Foundation
import Observation

/// Where settings persist. `UserDefaults` in the app; an in-memory store in tests and snapshots.
protocol SettingsStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: SettingsStore {}

final class InMemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// User preferences (SPEC §2.5). Change them through `AppModel`'s settings intents so side
/// effects (login item) happen; read them here.
@MainActor
@Observable
final class Settings {
    enum Key {
        static let engine = "engine"
        static let keepVideo = "keepVideo"
        static let noSplit = "noSplit"
        static let openAtLogin = "openAtLogin"
        static let enginePath = "enginePath"
        static let showVideo = "showVideo"
        static let all = [engine, keepVideo, noSplit, openAtLogin, enginePath, showVideo]
    }

    /// Studio / Clean / Quick → sidon / mossformer2 / df3.
    var engine: EngineChoice {
        didSet { store.set(engine.rawValue, forKey: Key.engine) }
    }

    /// false → `--audio-only`.
    var keepVideo: Bool {
        didSet { store.set(keepVideo, forKey: Key.keepVideo) }
    }

    /// true → `--no-split`.
    var noSplit: Bool {
        didSet { store.set(noSplit, forKey: Key.noSplit) }
    }

    /// The stored preference; whether the login item is really registered is up to the shell.
    var openAtLogin: Bool {
        didSet { store.set(openAtLogin, forKey: Key.openAtLogin) }
    }

    /// The Done screen shows a video job's picture. Off until the user turns it on; then it stays on.
    var showVideo: Bool {
        didSet { store.set(showVideo, forKey: Key.showVideo) }
    }

    /// Engine executable override chosen by the user (not the `--engine` flag).
    var enginePath: String? {
        didSet {
            if let enginePath, !enginePath.isEmpty {
                store.set(enginePath, forKey: Key.enginePath)
            } else {
                store.removeObject(forKey: Key.enginePath)
            }
        }
    }

    @ObservationIgnored private let store: SettingsStore

    init(store: SettingsStore = UserDefaults.standard) {
        self.store = store
        engine = (store.object(forKey: Key.engine) as? String).flatMap(EngineChoice.init(rawValue:)) ?? .studio
        keepVideo = store.object(forKey: Key.keepVideo) as? Bool ?? true
        noSplit = store.object(forKey: Key.noSplit) as? Bool ?? false
        openAtLogin = store.object(forKey: Key.openAtLogin) as? Bool ?? true
        showVideo = store.object(forKey: Key.showVideo) as? Bool ?? false
        enginePath = (store.object(forKey: Key.enginePath) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `--reset-defaults`.
    static func resetStoredValues(in store: SettingsStore = UserDefaults.standard) {
        for key in Key.all { store.removeObject(forKey: key) }
    }

    /// Options for a new enhance run under the current preferences.
    func runOptions(output: URL, stemsDirectory: URL, mix: Mix = .standard) -> RunOptions {
        RunOptions(
            output: output, stemsDirectory: stemsDirectory, engine: engine,
            splitMusic: !noSplit, keepVideo: keepVideo, mix: mix)
    }
}

/// Settings → Updates: not asked yet, asking, or what the latest release said.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(Release)
    case failed
}

enum AppInfo {
    static let bundleIdentifier = "studio.booth.Booth"

    /// `CFBundleShortVersionString`, or "0.1.0" when running outside the bundle.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
