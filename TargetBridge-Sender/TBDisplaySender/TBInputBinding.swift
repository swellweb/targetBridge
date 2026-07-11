import AppKit
import Foundation

/// A keyboard shortcut: a key plus a stable modifier bitmask.
///
/// Modifiers use our own bits (independent of AppKit/CoreGraphics) so they
/// persist reliably: control = 1, option = 2, shift = 4, command = 8.
struct TBInputShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt32

    static let control: UInt32 = 1 << 0
    static let option:  UInt32 = 1 << 1
    static let shift:   UInt32 = 1 << 2
    static let command: UInt32 = 1 << 3

    /// (bit, left-hand modifier key code), in a stable nesting order.
    static let modifierTable: [(bit: UInt32, keyCode: UInt16)] = [
        (control, 59),
        (option,  58),
        (shift,   56),
        (command, 55)
    ]

    var hasModifiers: Bool { modifiers != 0 }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= control }
        if flags.contains(.option)  { m |= option }
        if flags.contains(.shift)   { m |= shift }
        if flags.contains(.command) { m |= command }
        return m
    }

    /// Display string such as `⌃⌥←` or `⌘⇧A`.
    var displayString: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option  != 0 { s += "⌥" }
        if modifiers & Self.shift   != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        s += TBKeyCodeNames.name(for: keyCode)
        return s
    }
}

/// A per-session binding: pressing `trigger` on the receiver runs `action` on
/// the sender while the receiver is the input master.
struct TBInputBinding: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var trigger: TBInputShortcut
    var action: TBInputShortcut
    var enabled: Bool = true
}

enum TBInputBindingEngine {
    static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62: return true
        default: return false
        }
    }

    static func modifierBit(for keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 59, 62: return TBInputShortcut.control
        case 58, 61: return TBInputShortcut.option
        case 56, 60: return TBInputShortcut.shift
        case 54, 55: return TBInputShortcut.command
        default: return nil
        }
    }

    /// Find the enabled binding whose trigger matches `keyCode` + exact `modifiers`.
    static func match(keyCode: UInt16, modifiers: UInt32, in bindings: [TBInputBinding]) -> TBInputBinding? {
        bindings.first { $0.enabled && $0.trigger.keyCode == keyCode && $0.trigger.modifiers == modifiers }
    }
}

/// Human-readable names for common virtual key codes (for shortcut display).
enum TBKeyCodeNames {
    private static let table: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",",
        47: ".", 44: "/", 42: "\\", 50: "`"
    ]

    static func name(for keyCode: UInt16) -> String {
        table[keyCode] ?? "key\(keyCode)"
    }
}
