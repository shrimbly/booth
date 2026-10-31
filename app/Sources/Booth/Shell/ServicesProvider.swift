import AppKit

/// The Finder Quick Action "Enhance with Booth" (SPEC §3.8). Info.plist's `NSServices` entry
/// names `enhanceWithBooth` as its `NSMessage`; AppKit calls it with the selected files.
/// Nothing opens: the menu bar icon starts working.
final class ServicesProvider: NSObject {
    private let enqueue: @MainActor ([URL]) -> Void

    init(enqueue: @escaping @MainActor ([URL]) -> Void) {
        self.enqueue = enqueue
    }

    @objc func enhanceWithBooth(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = FilePasteboard.fileURLs(on: pasteboard)
        Log.info("service: enhance \(urls.map(\.lastPathComponent).joined(separator: ", "))")
        guard !urls.isEmpty else {
            error.pointee = "No files were passed to Booth."
            return
        }
        // AppKit delivers service requests on the main thread.
        MainActor.assumeIsolated { enqueue(urls) }
    }
}
