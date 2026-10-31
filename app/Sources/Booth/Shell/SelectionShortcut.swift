import AppKit
import BoothCore
import Carbon.HIToolbox

/// ⌃⌥E, "Enhance selected files" (SPEC §3.8): puts the audio and video selected in Finder in the
/// booth and confirms with the capsule, without opening anything.
@MainActor
final class SelectionShortcut {
    /// Shown when Booth may not read the Finder selection; it would otherwise look like nothing
    /// was selected, forever.
    static let finderAccessDeniedText = "Allow Booth to control Finder in System Settings"
    /// Shown when Finder doesn't answer in time, so a busy Finder doesn't read as no selection.
    static let finderNotRespondingText = "Finder didn't answer in time. Try again"

    private let model: AppModel
    private let capsule = CapsuleHUD()
    private var hotKey: HotKey?

    init(model: AppModel) {
        self.model = model
        hotKey = HotKey(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey) { [weak self] in
            self?.enhanceSelection()
        }
        if hotKey != nil { Log.info("registered ⌃⌥E") }
    }

    private func enhanceSelection() {
        Log.info("⌃⌥E pressed")
        switch FinderSelection.selectedFiles() {
        case .success(let urls):
            // The capsule says what happened; the Error screen would open the popover.
            let accepted = model.enqueue(urls, reportingRejections: false)
            if accepted.isEmpty && !urls.isEmpty {
                capsule.show(Formatting.unsupportedSelectionText(count: urls.count))
            } else {
                capsule.show(Formatting.capsuleText(enqueuedNames: accepted.map(\.lastPathComponent)))
            }
        case .failure(.notPermitted):
            capsule.show(Self.finderAccessDeniedText)
        case .failure(.notResponding):
            capsule.show(Self.finderNotRespondingText)
        case .failure(.failed):
            capsule.show(Formatting.nothingSelectedText)
        }
    }
}
