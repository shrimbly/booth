import Foundation
import ServiceManagement

/// "Open at login" through `SMAppService.mainApp` (SPEC §2.5). Booth only registers itself once
/// it is installed in /Applications or ~/Applications, so a copy run from a build folder never
/// becomes the login item. The switch shows the stored preference either way.
final class LoginItem: LoginItemControlling {
    func setEnabled(_ enabled: Bool) {
        guard AppResources.isBundled, Bundle.main.bundleIdentifier != nil else {
            Log.info("open at login (\(enabled)): skipped, not running from an app bundle")
            return
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard Self.isInstalled else {
                    Log.info("open at login: not registering \(Bundle.main.bundlePath); install Booth in /Applications or ~/Applications")
                    return
                }
                switch service.status {
                case .enabled:
                    return
                case .requiresApproval:
                    Log.info("open at login: waiting for approval in System Settings → General → Login Items")
                    return
                default:
                    try service.register()
                    Log.info("open at login: registered (\(Self.describe(service.status)))")
                }
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return }
                try service.unregister()
                Log.info("open at login: unregistered")
            }
        } catch {
            Log.error("open at login (\(enabled)) failed: \(error.localizedDescription)")
        }
    }

    private static var isInstalled: Bool {
        let parent = Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return [ "/Applications", userApplications ].contains { parent == $0 || parent.hasPrefix($0 + "/") }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }
}
