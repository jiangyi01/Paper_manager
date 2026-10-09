import Foundation

/// Explain's global shortcut (`assist.explain.hotkey`, default ⌃⌥E — D4): the Carbon modifier mask
/// it is registered with, the mapping from AppKit's modifier flags (the Settings recorder), the
/// combinations macOS refuses or the system already uses, and how it is written in menus. Pure;
/// the App's `HotKeyCenter` registers it through Carbon `RegisterEventHotKey`. Owned by the Explain
/// UI lane (A2).
package enum HotKeySpec {
    /// Carbon `EventModifiers` bits (HIToolbox Events.h).
    package enum Carbon {
        package static let command = 0x0100     // cmdKey
        package static let shift = 0x0200       // shiftKey
        package static let option = 0x0800      // optionKey
        package static let control = 0x1000     // controlKey
        package static let all = command | shift | option | control
    }

    /// `NSEvent.ModifierFlags` raw bits (device-independent).
    package enum Cocoa {
        package static let shift: UInt = 1 << 17
        package static let control: UInt = 1 << 18
        package static let option: UInt = 1 << 19
        package static let command: UInt = 1 << 20
    }

    /// Virtual key codes used by the rules (Carbon `kVK_*`).
    package enum Key {
        package static let e = 0x0E, returnKey = 0x24, tab = 0x30, space = 0x31, delete = 0x33, escape = 0x35
        package static let forwardDelete = 0x75, q = 0x0C, w = 0x0D, h = 0x04, m = 0x2E
        package static let three = 0x14, four = 0x15, five = 0x17
        /// ⌘ ⇧ ⇪ ⌥ ⌃ and their right-hand twins, fn: never a hotkey by themselves.
        package static let modifiers: Set<Int> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]
    }

    /// Why a combination can't be the shortcut.
    package enum Problem: String, Sendable, Equatable {
        /// No ⌃ or ⌘: plain keys, ⇧-only and ⌥-only / ⌥⇧-only combos (macOS refuses those since 15).
        case needsControlOrCommand
        /// A key that can't carry a shortcut (Esc, Return, Tab, Space, Delete, a modifier key).
        case reservedKey
        /// A shortcut the system or every app already uses (⌘Q, ⌘Tab, ⌘Space, the screenshot keys…).
        case systemShortcut
    }

    /// The Carbon mask of AppKit modifier flags (other bits ignored).
    package static func carbonModifiers(cocoaFlags: UInt) -> Int {
        var m = 0
        if cocoaFlags & Cocoa.command != 0 { m |= Carbon.command }
        if cocoaFlags & Cocoa.shift != 0 { m |= Carbon.shift }
        if cocoaFlags & Cocoa.option != 0 { m |= Carbon.option }
        if cocoaFlags & Cocoa.control != 0 { m |= Carbon.control }
        return m
    }

    /// The AppKit flags of a Carbon mask (menu key equivalents).
    package static func cocoaFlags(carbon: Int) -> UInt {
        var f: UInt = 0
        if carbon & Carbon.command != 0 { f |= Cocoa.command }
        if carbon & Carbon.shift != 0 { f |= Cocoa.shift }
        if carbon & Carbon.option != 0 { f |= Cocoa.option }
        if carbon & Carbon.control != 0 { f |= Cocoa.control }
        return f
    }

    /// nil: usable.
    package static func validate(_ k: AssistSettings.HotKey) -> Problem? {
        let mods = k.carbonModifiers & Carbon.all
        if Key.modifiers.contains(k.keyCode) || [Key.escape, Key.returnKey, Key.tab, Key.space, Key.delete,
                                                  Key.forwardDelete].contains(k.keyCode) {
            return .reservedKey
        }
        guard mods & (Carbon.control | Carbon.command) != 0 else { return .needsControlOrCommand }
        if isSystem(keyCode: k.keyCode, mods: mods) { return .systemShortcut }
        guard keyName(k.keyCode) != nil else { return .reservedKey }
        return nil
    }

    private static func isSystem(keyCode: Int, mods: Int) -> Bool {
        let cmd = Carbon.command, shift = Carbon.shift, ctrl = Carbon.control
        if mods == cmd, [Key.q, Key.w, Key.h, Key.m].contains(keyCode) { return true }
        // ⌘⇧3/4/5 and ⌃⌘⇧3/4 (screenshots, the screenshot toolbar).
        if [Key.three, Key.four, Key.five].contains(keyCode), mods == cmd | shift || mods == cmd | shift | ctrl { return true }
        return false
    }

    /// "⌃⌥E" (Apple's order: ⌃ ⌥ ⇧ ⌘, then the key).
    package static func display(_ k: AssistSettings.HotKey) -> String {
        let m = k.carbonModifiers
        var s = ""
        if m & Carbon.control != 0 { s += "⌃" }
        if m & Carbon.option != 0 { s += "⌥" }
        if m & Carbon.shift != 0 { s += "⇧" }
        if m & Carbon.command != 0 { s += "⌘" }
        return s + (keyName(k.keyCode) ?? "?")
    }

    /// The menu item key equivalent (lowercase letter / digit) and its AppKit flags; nil for keys a
    /// menu can't show the same way (F-keys are left out of menus).
    package static func menuKeyEquivalent(_ k: AssistSettings.HotKey) -> (key: String, flags: UInt)? {
        guard validate(k) == nil, let name = keyName(k.keyCode), name.count == 1 else { return nil }
        return (name.lowercased(), cocoaFlags(carbon: k.carbonModifiers))
    }

    /// The printed name of a key code (ANSI layout letters, digits, punctuation, F1–F12).
    package static func keyName(_ keyCode: Int) -> String? { names[keyCode] }

    private static let names: [Int: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9",
        0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]
}
