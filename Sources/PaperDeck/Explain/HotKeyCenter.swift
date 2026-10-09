import AppKit
import Carbon.HIToolbox
import PaperDeckCore

/// How registering the shortcut went (Settings shows it next to the recorder).
enum HotKeyRegistration: Equatable {
    case notRegistered
    /// `assist.mode` is off: no global shortcut is held until the user turns Explain & Ask on.
    case switchedOff
    case registered
    /// Another app holds the combination (`eventHotKeyExistsErr`).
    case inUse
    /// A combination macOS refuses or the system uses (`HotKeySpec.validate`).
    case invalid(HotKeySpec.Problem)
    case failed(Int32)
}

/// The global shortcut behind a protocol, so the coordinator's logic never needs a real hotkey
/// (renders and tests use a recorder; nothing in the test target registers one).
protocol HotKeyRegistering: AnyObject {
    /// Replaces the registered shortcut with `key`; `handler` runs on the main thread when it fires.
    func register(_ key: AssistSettings.HotKey, handler: @escaping () -> Void) -> HotKeyRegistration
    func unregister()
}

/// The one global shortcut through Carbon `RegisterEventHotKey` (LN §3, dive-capture §1): no
/// Accessibility or Input Monitoring permission. Carbon calls the C trampoline below on the main
/// run loop; the trampoline is `nonisolated` (a C function pointer can't be a MainActor function)
/// and hops back with `MainActor.assumeIsolated`. Owned by the Explain UI lane (A2).
final class CarbonHotKeyCenter: HotKeyRegistering {
    static let shared = CarbonHotKeyCenter()
    /// 'PDKY'.
    static let signature: OSType = 0x5044_4B59
    static let explainID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    private init() {}

    func register(_ key: AssistSettings.HotKey, handler: @escaping () -> Void) -> HotKeyRegistration {
        unregister()
        if let problem = HotKeySpec.validate(key) { return .invalid(problem) }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.explainID)
        let status = RegisterEventHotKey(UInt32(key.keyCode), UInt32(key.carbonModifiers & HotKeySpec.Carbon.all), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            return status == OSStatus(eventHotKeyExistsErr) ? .inUse : .failed(status)
        }
        hotKeyRef = ref
        self.handler = handler
        return .registered
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        handler = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), explainHotKeyTrampoline, 1, &spec, nil, &handlerRef)
    }

    fileprivate func fire(_ id: EventHotKeyID) {
        guard id.signature == Self.signature, id.id == Self.explainID else { return }
        handler?()
    }
}

/// Carbon's callback (a C function pointer: no captures, not MainActor). Application-target events
/// arrive on the main thread, so the hop back is `assumeIsolated` (DESIGN.md:282-286).
nonisolated private func explainHotKeyTrampoline(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                                 _ user: UnsafeMutableRawPointer?) -> OSStatus {
    var id = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard err == noErr else { return err }
    MainActor.assumeIsolated { CarbonHotKeyCenter.shared.fire(id) }
    return noErr
}
