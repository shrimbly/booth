import AppKit
import BoothCore
import UniformTypeIdentifiers

/// The system side used by the real app and by --demo.
@MainActor
func makeLiveSystemServices() -> SystemServices {
    SystemServices(
        notifier: UserNotifier.makeIfAvailable() ?? UnavailableNotifier(),
        loginItem: LoginItem(),
        workspace: LiveWorkspace(),
        video: AVVideoInspector(),
        updates: GitHubUpdates())
}

/// Open panel, Finder reveal and quit through AppKit.
final class LiveWorkspace: WorkspaceActing {
    func chooseMediaFiles(completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Exactly the types `AppModel.enqueue` takes, so nothing it would refuse can be picked.
        var types: [UTType] = []
        for type in OutputNaming.supportedExtensions.compactMap({ UTType(filenameExtension: $0) }) where !types.contains(type) {
            types.append(type)
        }
        panel.allowedContentTypes = types
        panel.message = "Choose audio or video to enhance"
        // The popover floats at pop-up menu level; the chooser must come out above it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate()
        panel.begin { response in
            completion(response == .OK ? panel.urls : [])
        }
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func terminate() {
        NSApp.terminate(nil)
    }
}

/// The latest release from GitHub's API (60 unauthenticated requests an hour is plenty for a
/// button).
final class GitHubUpdates: UpdateChecking {
    struct BadAnswer: Error {
        var status: Int
    }

    func latestRelease() async throws -> Release {
        var request = URLRequest(url: UpdateCheck.latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Booth/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let release = Release(gitHubJSON: data) else { throw BadAnswer(status: status) }
        return release
    }
}
