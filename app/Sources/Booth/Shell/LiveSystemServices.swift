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
        video: AVVideoInspector())
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

    func terminate() {
        NSApp.terminate(nil)
    }
}
