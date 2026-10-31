import AppKit
import BoothCore
import UserNotifications

/// "<name> is out of the booth." (SPEC §3.8): posted when a job finishes while the popover is
/// closed, with "Show in Finder" and "Compare" actions. Clicking the banner itself is Compare.
@MainActor
final class UserNotifier: NSObject, Notifying {
    private enum Identifier {
        static let category = "studio.booth.job-finished"
        static let compare = "studio.booth.compare"
        static let showInFinder = "studio.booth.show-in-finder"
        static let jobKey = "jobID"
    }

    var onAction: (@MainActor (NotificationAction, Job.ID) -> Void)?

    private let center: UNUserNotificationCenter
    private var hasAskedForPermission = false

    /// Nil outside an app bundle: UNUserNotificationCenter needs a bundle identifier and traps
    /// without one (`swift run`, the bare build product).
    static func makeIfAvailable() -> UserNotifier? {
        guard AppResources.isBundled, Bundle.main.bundleIdentifier != nil else {
            Log.info("notifications off: not running from an app bundle")
            return nil
        }
        return UserNotifier()
    }

    private override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        // Set before launch finishes so a click that relaunches Booth is not lost.
        center.delegate = self
        let showInFinder = UNNotificationAction(identifier: Identifier.showInFinder, title: "Show in Finder", options: [])
        let compare = UNNotificationAction(identifier: Identifier.compare, title: "Compare", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Identifier.category, actions: [showInFinder, compare], intentIdentifiers: []),
        ])
    }

    /// AppModel calls this at launch. Booth waits for the first job before asking, so the
    /// question arrives when it makes sense (see `askForPermissionIfNeeded`).
    func requestAuthorization() {}

    /// Asks once per launch, and only if the user has never answered.
    func askForPermissionIfNeeded() {
        guard !hasAskedForPermission else { return }
        hasAskedForPermission = true
        Task { _ = await ensureAuthorized() }
    }

    func postJobFinished(_ job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "Booth"
        content.body = Formatting.notificationBody(name: job.name)
        content.categoryIdentifier = Identifier.category
        content.userInfo = [Identifier.jobKey: job.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else {
                Log.info("notification skipped (not allowed): \(content.body)")
                return
            }
            do {
                try await center.add(request)
                Log.info("notification: \(content.body)")
            } catch {
                Log.error("notification failed: \(error.localizedDescription)")
            }
        }
    }

    /// Main.dc.html hides the banner once the popover opens: what it announced is on screen.
    /// Quitting clears them too, since the jobs they point at do not outlive Booth.
    func removeDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
    }

    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                Log.info("notifications \(granted ? "allowed" : "declined")")
                return granted
            } catch {
                Log.error("notification permission request failed: \(error.localizedDescription)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    fileprivate func handleResponse(actionIdentifier: String, jobID: Job.ID) {
        let action: NotificationAction = actionIdentifier == Identifier.showInFinder ? .showInFinder : .compare
        Log.info("notification action \(actionIdentifier) for \(jobID)")
        onAction?(action, jobID)
    }
}

extension UserNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let jobID = (response.notification.request.content.userInfo[Identifier.jobKey] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let jobID, actionIdentifier != UNNotificationDismissActionIdentifier {
                    self.handleResponse(actionIdentifier: actionIdentifier, jobID: jobID)
                }
            }
            completionHandler()
        }
    }

    /// Booth may be the active app while the popover is closed; show the banner anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Stands in for `UserNotifier` outside an app bundle, where notifications cannot work.
final class UnavailableNotifier: Notifying {
    var onAction: (@MainActor (NotificationAction, Job.ID) -> Void)?

    func requestAuthorization() {}

    func postJobFinished(_ job: Job) {
        Log.info("notification (unbundled, not shown): \(Formatting.notificationBody(name: job.name))")
    }
}
