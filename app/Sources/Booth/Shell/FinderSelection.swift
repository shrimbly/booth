import AppKit

/// The items selected in Finder, read over Apple Events (SPEC §3.8). The first use asks the
/// user to let Booth control Finder (`NSAppleEventsUsageDescription` in Info.plist).
enum FinderSelection {
    enum Failure: Error, Equatable {
        /// The user said no to Booth controlling Finder (errAEEventNotPermitted).
        case notPermitted
        /// Finder didn't answer within `timeoutSeconds` (errAETimeout): it is busy or hung.
        case notResponding
        case failed(String)
    }

    /// How long to wait for Finder's answer. Booth's main thread waits with it, so this is far
    /// below the 2-minute Apple Event default.
    static let timeoutSeconds = 10

    private static let errAEEventNotPermitted = -1743
    private static let errAETimeout = -1712

    private static let source = """
        with timeout of \(timeoutSeconds) seconds
            tell application "Finder" to set selectedItems to selection as alias list
        end timeout
        set selectedPaths to {}
        repeat with selectedItem in selectedItems
            set end of selectedPaths to POSIX path of selectedItem
        end repeat
        return selectedPaths
        """

    /// Blocks while Finder answers (and, the first time, while the user decides), for at most
    /// `timeoutSeconds`. NSAppleScript belongs on the main thread.
    @MainActor
    static func selectedFiles() -> Result<[URL], Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("could not build the script")) }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            Log.error("Finder selection: \(message) (\(number))")
            switch number {
            case errAEEventNotPermitted: return .failure(.notPermitted)
            case errAETimeout: return .failure(.notResponding)
            default: return .failure(.failed(message))
            }
        }
        guard result.numberOfItems > 0 else { return .success([]) }
        let paths = (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
        return .success(paths.map { URL(fileURLWithPath: $0) })
    }
}
