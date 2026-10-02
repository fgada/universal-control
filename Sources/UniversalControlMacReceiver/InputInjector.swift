import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class InputInjector {
    private static let allowedGestureEventTypes: Set<UInt32> = [18, 19, 20, 29, 30, 31, 32]
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    // The sender is a US keyboard. Tag key events as ANSI so a JIS receiver
    // translates symbol keys by US positions instead of its built-in JIS layout.
    private static let ansiKeyboardType: Int64 = 40
    // JIS-only keys (Yen, Underscore, keypad comma, Eisu, Kana) keep the
    // receiver's own keyboard type so they still behave as JIS keys.
    private static let jisOnlyKeyCodes: Set<CGKeyCode> = [0x5D, 0x5E, 0x5F, 0x66, 0x68]

    // Typing text as synthetic Unicode key events drops symbols when an IME is
    // active or events arrive too quickly, so paste through the clipboard instead.
    func sendText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            fputs("Failed to write text to the clipboard.\n", stderr)
            return
        }

        let mapping = MacKeyMapping(CGKeyCode(kVK_ANSI_V))
        let commandMask: UInt8 = 0b0000_1000 // Left GUI (Command)
        sendKey(mapping, isDown: true, modifierMask: commandMask)
        sendKey(mapping, isDown: false, modifierMask: commandMask)

        print("Pasted \(text.utf8.count) UTF-8 bytes into the focused field.")
    }

    func sendKey(_ mapping: MacKeyMapping, isDown: Bool, modifierMask: UInt8) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: mapping.keyCode,
            keyDown: isDown
        ) else {
            fputs("Failed to create keyboard event.\n", stderr)
            return
        }

        event.flags = flags(modifierMask: modifierMask, mapping: mapping, isDown: isDown)
        applyKeyboardType(to: event, mapping: mapping)
        event.post(tap: .cghidEventTap)
    }

    func sendSystemFunctionKey(_ systemFunctionKey: MacSystemFunctionKey, isDown: Bool, isRepeat: Bool = false, modifierMask: UInt8) {
        let keyState = isDown ? 0x0A : 0x0B
        let data1 = (systemFunctionKey.keyType << 16) | (keyState << 8) | (isRepeat ? 0x1 : 0)
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: UInt(keyState << 8) | UInt(HIDUsageMapper.eventFlags(for: modifierMask).rawValue)
        )
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        )?.cgEvent else {
            fputs("Failed to create system function key event.\n", stderr)
            return
        }

        event.post(tap: .cghidEventTap)
    }

    func sendKanaABCToggle(modifierMask: UInt8) {
        let currentInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let isASCIICapable = TISGetInputSourceProperty(
            currentInputSource,
            kTISPropertyInputSourceIsASCIICapable
        ).map { property in
            Unmanaged<CFBoolean>.fromOpaque(property).takeUnretainedValue() == kCFBooleanTrue
        } ?? true

        // JIS Kana selects Japanese input; JIS Eisu selects ABC input.
        let keyCode: CGKeyCode = isASCIICapable ? 0x68 : 0x66
        let destination = isASCIICapable ? "kana" : "ABC"
        let mapping = MacKeyMapping(keyCode)
        print("kana_abc_toggle: switching to \(destination)")
        sendKey(mapping, isDown: true, modifierMask: modifierMask)
        sendKey(mapping, isDown: false, modifierMask: modifierMask)
    }

    func sendKeyRepeat(_ mapping: MacKeyMapping, modifierMask: UInt8) {
        guard let event = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: mapping.keyCode,
            keyDown: true
        ) else {
            fputs("Failed to create keyboard repeat event.\n", stderr)
            return
        }

        event.flags = flags(modifierMask: modifierMask, mapping: mapping, isDown: true)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        applyKeyboardType(to: event, mapping: mapping)
        event.post(tap: .cghidEventTap)
    }

    func sendRelativePointer(dx: Int16, dy: Int16, buttonMask: UInt8, modifierMask: UInt8) {
        guard dx != 0 || dy != 0 else { return }

        let currentLocation = CGEvent(source: eventSource)?.location ?? .zero
        let targetLocation = CGPoint(
            x: currentLocation.x + CGFloat(dx),
            y: currentLocation.y + CGFloat(dy)
        )
        let drag = dragEvent(for: buttonMask)
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: drag.type,
            mouseCursorPosition: targetLocation,
            mouseButton: drag.button
        ) else {
            fputs("Failed to create pointer event.\n", stderr)
            return
        }

        event.flags = HIDUsageMapper.eventFlags(for: modifierMask)
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)
    }

    func sendButton(_ button: UInt8, isDown: Bool, clickCount: UInt8, modifierMask: UInt8) {
        guard let mapping = mouseButtonMapping(button: button, isDown: isDown) else { return }

        let currentLocation = CGEvent(source: eventSource)?.location ?? .zero
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: mapping.type,
            mouseCursorPosition: currentLocation,
            mouseButton: mapping.button
        ) else {
            fputs("Failed to create mouse button event.\n", stderr)
            return
        }

        event.flags = HIDUsageMapper.eventFlags(for: modifierMask)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        event.post(tap: .cghidEventTap)
    }

    func sendWheel(deltaY: Int16, modifierMask: UInt8) {
        guard deltaY != 0 else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        ) else {
            fputs("Failed to create scroll event.\n", stderr)
            return
        }

        event.flags = HIDUsageMapper.eventFlags(for: modifierMask)
        event.post(tap: .cghidEventTap)
    }

    func sendGesture(_ data: Data, modifierMask: UInt8) {
        guard let event = CGEvent(withDataAllocator: kCFAllocatorDefault, data: data as CFData) else {
            fputs("Failed to restore gesture event.\n", stderr)
            return
        }
        guard Self.allowedGestureEventTypes.contains(event.type.rawValue) else {
            fputs("Ignoring non-gesture event in gesture packet.\n", stderr)
            return
        }

        if let currentEvent = CGEvent(source: eventSource) {
            event.location = currentEvent.location
            event.timestamp = currentEvent.timestamp
        }
        event.setSource(eventSource)
        event.flags = HIDUsageMapper.eventFlags(for: modifierMask)
        event.post(tap: .cghidEventTap)
    }

    private func applyKeyboardType(to event: CGEvent, mapping: MacKeyMapping) {
        guard !Self.jisOnlyKeyCodes.contains(mapping.keyCode) else { return }
        event.setIntegerValueField(.keyboardEventKeyboardType, value: Self.ansiKeyboardType)
    }

    private func flags(modifierMask: UInt8, mapping: MacKeyMapping, isDown: Bool) -> CGEventFlags {
        var eventFlags = HIDUsageMapper.eventFlags(for: modifierMask)
        if mapping.addsFunctionFlag, isDown {
            eventFlags.insert(.maskSecondaryFn)
        }
        if mapping.addsNumericPadFlag {
            eventFlags.insert(.maskNumericPad)
        }
        return eventFlags
    }

    private func dragEvent(for buttonMask: UInt8) -> (type: CGEventType, button: CGMouseButton) {
        if buttonMask & 0b001 != 0 { return (.leftMouseDragged, .left) }
        if buttonMask & 0b010 != 0 { return (.rightMouseDragged, .right) }
        if buttonMask & 0b100 != 0 { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    private func mouseButtonMapping(
        button: UInt8,
        isDown: Bool
    ) -> (type: CGEventType, button: CGMouseButton)? {
        switch (button, isDown) {
        case (1, true): (.leftMouseDown, .left)
        case (1, false): (.leftMouseUp, .left)
        case (2, true): (.rightMouseDown, .right)
        case (2, false): (.rightMouseUp, .right)
        case (3, true): (.otherMouseDown, .center)
        case (3, false): (.otherMouseUp, .center)
        default: nil
        }
    }
}
