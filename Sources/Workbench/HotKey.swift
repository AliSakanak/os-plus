import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon's RegisterEventHotKey.
/// Unlike an event tap, this needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    /// Returns false if another app already owns this shortcut.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5752_4B42), id: id)  // 'WRKB'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr {
                let id = hotKeyID.id
                // Carbon delivers hot-key events on the main thread.
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(id: id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The shortcuts offered for "grab text". ⌘⇧2 sits next to the built-in ⌘⇧3/4/5 screenshot keys.
enum GrabShortcut: String, CaseIterable, Identifiable {
    case commandShift2, controlShift2, optionShift2

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commandShift2: "⌘⇧2"
        case .controlShift2: "⌃⇧2"
        case .optionShift2: "⌥⇧2"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_ANSI_2) }

    var modifiers: UInt32 {
        switch self {
        case .commandShift2: UInt32(cmdKey | shiftKey)
        case .controlShift2: UInt32(controlKey | shiftKey)
        case .optionShift2: UInt32(optionKey | shiftKey)
        }
    }
}
