import AppKit
import ApplicationServices
import Carbon.HIToolbox

// macOS decides per keyboard model, Fn state, and the "Use F1, F2, etc. keys as
// standard function keys" setting whether a top-row key is an F-key or a system
// function key. The raw HID usage is always F1-F12, so the function row is read
// from the event tap instead: F-keys arrive as keyDown/keyUp, system function
// keys as NX_SYSDEFINED.
enum FunctionKey {
    private static let usagesByKeyCode: [CGKeyCode: UInt16] = [
        CGKeyCode(kVK_F1): UInt16(kHIDUsage_KeyboardF1),
        CGKeyCode(kVK_F2): UInt16(kHIDUsage_KeyboardF2),
        CGKeyCode(kVK_F3): UInt16(kHIDUsage_KeyboardF3),
        CGKeyCode(kVK_F4): UInt16(kHIDUsage_KeyboardF4),
        CGKeyCode(kVK_F5): UInt16(kHIDUsage_KeyboardF5),
        CGKeyCode(kVK_F6): UInt16(kHIDUsage_KeyboardF6),
        CGKeyCode(kVK_F7): UInt16(kHIDUsage_KeyboardF7),
        CGKeyCode(kVK_F8): UInt16(kHIDUsage_KeyboardF8),
        CGKeyCode(kVK_F9): UInt16(kHIDUsage_KeyboardF9),
        CGKeyCode(kVK_F10): UInt16(kHIDUsage_KeyboardF10),
        CGKeyCode(kVK_F11): UInt16(kHIDUsage_KeyboardF11),
        CGKeyCode(kVK_F12): UInt16(kHIDUsage_KeyboardF12)
    ]
    private static let usages = Set(usagesByKeyCode.values)

    static func isFunctionRowUsage(_ usage: UInt16) -> Bool {
        usages.contains(usage)
    }

    static func usage(forKeyCode keyCode: CGKeyCode) -> UInt16? {
        usagesByKeyCode[keyCode]
    }
}

struct SystemFunctionKeyEvent {
    static let systemDefinedEventType = CGEventType(rawValue: 14)! // NX_SYSDEFINED
    private static let auxControlButtonsSubtype: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h. Brightness and
    // keyboard illumination stay on the sender because they drive its hardware.
    private static let usagesByKeyType: [Int: UInt16] = [
        0: SyntheticUsage.volumeUp, // NX_KEYTYPE_SOUND_UP
        1: SyntheticUsage.volumeDown, // NX_KEYTYPE_SOUND_DOWN
        7: SyntheticUsage.mute, // NX_KEYTYPE_MUTE
        16: SyntheticUsage.playPause, // NX_KEYTYPE_PLAY
        17: SyntheticUsage.nextTrack, // NX_KEYTYPE_NEXT
        18: SyntheticUsage.previousTrack, // NX_KEYTYPE_PREVIOUS
        19: SyntheticUsage.nextTrack, // NX_KEYTYPE_FAST
        20: SyntheticUsage.previousTrack // NX_KEYTYPE_REWIND
    ]

    let usage: UInt16
    let isDown: Bool
    let isRepeat: Bool

    init?(_ event: CGEvent) {
        guard event.type == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype else {
            return nil
        }

        let data1 = nsEvent.data1
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        guard let usage = Self.usagesByKeyType[keyType] else { return nil }

        self.usage = usage
        isDown = (keyFlags & 0xFF00) >> 8 == 0x0A
        isRepeat = keyFlags & 0x1 != 0
    }
}
