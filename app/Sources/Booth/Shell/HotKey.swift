import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's `RegisterEventHotKey` is still the one API that
/// works from the background without Accessibility permission (an event tap would need it).
final class HotKey {
    /// `'BTHK'`: tells Booth's hot keys apart from any other in the process.
    fileprivate static let signature: OSType = 0x4254_484B
    private static var nextID: UInt32 = 1

    fileprivate let id: UInt32
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// `keyCode` is a virtual key code such as `kVK_ANSI_E`; `modifiers` combines Carbon masks
    /// such as `controlKey | optionKey`. Nil when the shortcut is taken or cannot be installed.
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyPressed, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installStatus == noErr else {
            Log.error("hot key: InstallEventHandler failed (\(installStatus))")
            return nil
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            Log.error("hot key: RegisterEventHotKey failed (\(registerStatus)); another app may own the shortcut")
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    fileprivate func fire() {
        // Carbon delivers hot key events on the main thread's run loop.
        MainActor.assumeIsolated { action() }
    }
}

private func hotKeyPressed(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    guard status == noErr, hotKeyID.signature == HotKey.signature, hotKeyID.id == hotKey.id else {
        return OSStatus(eventNotHandledErr)
    }
    hotKey.fire()
    return noErr
}
