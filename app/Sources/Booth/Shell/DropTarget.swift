import AppKit
import BoothCore

/// Reads dropped or pasted files off a pasteboard.
enum FilePasteboard {
    private static let legacyFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Every file URL on the pasteboard, in order. Services may still hand over the legacy
    /// filenames list instead of file URLs.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        let paths = pasteboard.propertyList(forType: legacyFilenamesType) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// The files Booth takes: audio and video, judged the same way `AppModel.enqueue` judges them.
    static func supportedFiles(on pasteboard: NSPasteboard) -> [URL] {
        OutputNaming.partition(fileURLs(on: pasteboard)).supported
    }
}

/// The decisions behind a file drop zone, shared by the menu bar icon and the open popover.
/// Views forward their `NSDraggingDestination` calls here.
///
/// Only drags carrying at least one audio or video file are accepted; anything else gets no
/// highlight and no drop (SPEC §3.8).
@MainActor
final class FileDropTarget {
    /// Whether drops are welcome right now (the popover refuses them on Settings).
    var isEnabled: () -> Bool = { true }
    /// An acceptable drag entered (true) or left, was dropped or was refused (false).
    var onHoverChange: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    private(set) var isHovering = false
    // Reading the pasteboard on every mouse move is wasteful; a drag's files never change.
    private var cachedSequenceNumber: Int?
    private var cachedFiles: [URL] = []

    func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let operation = isEnabled() && !files(in: info).isEmpty ? Self.operation(for: info.draggingSourceOperationMask) : []
        setHovering(!operation.isEmpty)
        return operation
    }

    func draggingExited() {
        setHovering(false)
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        let files = files(in: info)
        setHovering(false)
        cachedSequenceNumber = nil
        guard isEnabled(), !files.isEmpty else { return false }
        onDrop?(files)
        return true
    }

    func draggingEnded() {
        setHovering(false)
        cachedSequenceNumber = nil
    }

    private func files(in info: NSDraggingInfo) -> [URL] {
        if cachedSequenceNumber != info.draggingSequenceNumber {
            cachedSequenceNumber = info.draggingSequenceNumber
            cachedFiles = FilePasteboard.supportedFiles(on: info.draggingPasteboard)
        }
        return cachedFiles
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChange?(hovering)
    }

    /// Booth reads the file and writes a new one beside it, so "copy" is the honest badge.
    private static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for candidate in [NSDragOperation.copy, .generic, .link] where mask.contains(candidate) {
            return candidate
        }
        return []
    }
}
