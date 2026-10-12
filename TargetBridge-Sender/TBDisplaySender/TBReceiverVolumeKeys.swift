import Foundation

/// One press of a hardware volume key, decoded from an `NX_SYSDEFINED`
/// (`NSEvent.EventType.systemDefined`) event. Kept free of AppKit so the
/// decoding and stepping rules can be unit-tested without an event tap.
struct TBVolumeKeyEvent: Equatable {
    enum Key: Equatable {
        case up
        case down
        case mute
    }

    /// `NSEvent.EventSubtype` of an aux-control-button event
    /// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS` in IOKit's `ev_keymap.h`).
    static let auxControlSubtype: Int16 = 8

    /// Key codes from IOKit's `ev_keymap.h`.
    static let soundUpKeyCode = 0      // NX_KEYTYPE_SOUND_UP
    static let soundDownKeyCode = 1    // NX_KEYTYPE_SOUND_DOWN
    static let muteKeyCode = 7         // NX_KEYTYPE_MUTE

    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B

    var key: Key
    var isDown: Bool
    var isRepeat: Bool

    /// Decodes an event's `subtype` and `data1`. Returns `nil` for anything
    /// that is not one of the three volume keys, so play/pause, brightness and
    /// keyboard-backlight keys keep flowing through untouched.
    ///
    /// `data1` layout (see `ev_keymap.h` and `IOHIDSystem`):
    /// bits 16–31 hold the key code, bits 8–15 the key state (`0x0A` down,
    /// `0x0B` up) and bit 0 the auto-repeat flag.
    static func decode(subtype: Int16, data1: Int) -> TBVolumeKeyEvent? {
        guard subtype == auxControlSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let keyState = (keyFlags & 0xFF00) >> 8

        let key: Key
        switch keyCode {
        case soundUpKeyCode: key = .up
        case soundDownKeyCode: key = .down
        case muteKeyCode: key = .mute
        default: return nil
        }

        let isDown: Bool
        switch keyState {
        case keyDownState: isDown = true
        case keyUpState: isDown = false
        default: return nil
        }

        return TBVolumeKeyEvent(key: key, isDown: isDown, isRepeat: (keyFlags & 0x1) != 0)
    }
}

/// Stepping rules for driving a receiver's 0…1 volume level from the sender's
/// volume keys. Mirrors what macOS does with its own output device: the keys
/// move along a 16-step grid, or a 64-step grid while Shift+Option are held,
/// and snap onto the grid so a level set from a slider lands on a round value
/// after a single press.
enum TBReceiverVolumeKeys {
    /// macOS uses sixteen volume steps for a bare key press.
    static let coarseStep = 1.0 / 16.0
    /// Shift+Option divides each step into four, as the system HUD does.
    static let fineStep = 1.0 / 64.0

    /// Level restored by a mute press when nothing was remembered — the same
    /// default a new session starts with.
    static let unmuteFallbackLevel = 0.5

    enum Direction {
        case up
        case down
    }

    /// Moves `level` one step in `direction`, snapping onto the step grid.
    /// Stepping up from a value between two grid points lands on the next
    /// point above; stepping down lands on the next point below, so a press
    /// never skips a step or stays put because of floating-point drift.
    static func step(_ level: Double, _ direction: Direction, fine: Bool = false) -> Double {
        let stepSize = fine ? fineStep : coarseStep
        let units = level / stepSize
        // Tolerance absorbs the rounding error of a level that is already on
        // the grid (e.g. 0.5625 / 0.0625 computes to 9.000000000000002).
        let tolerance = 1e-6
        let target: Double
        switch direction {
        case .up: target = (units + tolerance).rounded(.down) + 1
        case .down: target = (units - tolerance).rounded(.up) - 1
        }
        return min(1.0, max(0.0, target * stepSize))
    }

    /// Mute toggle built on the plain level, since the wire protocol carries
    /// only a level and older receivers know nothing about a mute flag.
    /// Muting drops the level to zero and remembers where it was; a second
    /// press restores it.
    static func toggleMute(level: Double, remembered: Double?) -> (level: Double, remembered: Double?) {
        if level > 0 {
            return (0, level)
        }
        return (remembered ?? unmuteFallbackLevel, nil)
    }
}
