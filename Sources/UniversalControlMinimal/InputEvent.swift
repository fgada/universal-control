import Foundation
import IOKit.hid

enum PacketKind: UInt8 {
    case session = 1
    case key = 2
    case button = 3
    case pointer = 4
    case wheel = 5
    case sync = 6
}

struct ModifierState: OptionSet, CustomStringConvertible, Sendable {
    let rawValue: UInt8

    static let leftControl = ModifierState(rawValue: 1 << 0)
    static let leftShift = ModifierState(rawValue: 1 << 1)
    static let leftOption = ModifierState(rawValue: 1 << 2)
    static let leftCommand = ModifierState(rawValue: 1 << 3)
    static let rightControl = ModifierState(rawValue: 1 << 4)
    static let rightShift = ModifierState(rawValue: 1 << 5)
    static let rightOption = ModifierState(rawValue: 1 << 6)
    static let rightCommand = ModifierState(rawValue: 1 << 7)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init?(usage: UInt16) {
        switch usage {
        case UInt16(kHIDUsage_KeyboardLeftControl):
            self = .leftControl
        case UInt16(kHIDUsage_KeyboardLeftShift):
            self = .leftShift
        case UInt16(kHIDUsage_KeyboardLeftAlt):
            self = .leftOption
        case UInt16(kHIDUsage_KeyboardLeftGUI):
            self = .leftCommand
        case UInt16(kHIDUsage_KeyboardRightControl):
            self = .rightControl
        case UInt16(kHIDUsage_KeyboardRightShift):
            self = .rightShift
        case UInt16(kHIDUsage_KeyboardRightAlt):
            self = .rightOption
        case UInt16(kHIDUsage_KeyboardRightGUI):
            self = .rightCommand
        default:
            return nil
        }
    }

    var description: String {
        var names: [String] = []
        if contains(.leftControl) { names.append("lctrl") }
        if contains(.leftShift) { names.append("lshift") }
        if contains(.leftOption) { names.append("lopt") }
        if contains(.leftCommand) { names.append("lcmd") }
        if contains(.rightControl) { names.append("rctrl") }
        if contains(.rightShift) { names.append("rshift") }
        if contains(.rightOption) { names.append("ropt") }
        if contains(.rightCommand) { names.append("rcmd") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }

    static func from<S: Sequence>(usages: S) -> ModifierState where S.Element == UInt16 {
        usages.reduce(into: ModifierState()) { state, usage in
            guard let modifier = ModifierState(usage: usage) else { return }
            state.insert(modifier)
        }
    }
}

enum InputEvent: Sendable {
    case key(product: String, usage: UInt16, isDown: Bool, timestamp: UInt64)
    case button(product: String, button: UInt8, isDown: Bool, timestamp: UInt64)
    case pointer(product: String, dx: Int16, dy: Int16, timestamp: UInt64)
    case wheel(product: String, deltaY: Int16, timestamp: UInt64)

    var logDescription: String {
        switch self {
        case let .key(product, usage, isDown, timestamp):
            return "[KBD] product=\(product) usage=\(usage) \(isDown ? "down" : "up") ts=\(timestamp)"
        case let .button(product, button, isDown, timestamp):
            return "[BTN] product=\(product) button=\(button) \(isDown ? "down" : "up") ts=\(timestamp)"
        case let .pointer(product, dx, dy, timestamp):
            return "[PTR] product=\(product) dx=\(dx) dy=\(dy) ts=\(timestamp)"
        case let .wheel(product, deltaY, timestamp):
            return "[WHL] product=\(product) wheel=\(deltaY) ts=\(timestamp)"
        }
    }
}

struct RemoteSyncState: Sendable {
    let modifierMask: UInt8
    let buttonMask: UInt8
    let pressedKeys: [UInt16]

    static let empty = RemoteSyncState(modifierMask: 0, buttonMask: 0, pressedKeys: [])
}

enum ToggleKey {
    static let remoteModeUsage = UInt16(kHIDUsage_KeyboardF19)
    static let jitterModeUsage = UInt16(kHIDUsage_KeyboardF18)
    static let usages: Set<UInt16> = [remoteModeUsage, jitterModeUsage]

    static func isToggleUsage(_ usage: UInt16) -> Bool {
        usages.contains(usage)
    }
}
