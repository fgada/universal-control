import Foundation
import IOKit.hid

enum PacketType: UInt8 {
    case keyDown = 1
    case keyUp = 2
    case buttonDown = 3
    case buttonUp = 4
    case moveX = 5
    case moveY = 6
    case wheel = 7
    case modifier = 8
}

struct ModifierState: OptionSet, CustomStringConvertible {
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

    init?(usage: UInt32) {
        switch usage {
        case UInt32(kHIDUsage_KeyboardLeftControl):
            self = .leftControl
        case UInt32(kHIDUsage_KeyboardLeftShift):
            self = .leftShift
        case UInt32(kHIDUsage_KeyboardLeftAlt):
            self = .leftOption
        case UInt32(kHIDUsage_KeyboardLeftGUI):
            self = .leftCommand
        case UInt32(kHIDUsage_KeyboardRightControl):
            self = .rightControl
        case UInt32(kHIDUsage_KeyboardRightShift):
            self = .rightShift
        case UInt32(kHIDUsage_KeyboardRightAlt):
            self = .rightOption
        case UInt32(kHIDUsage_KeyboardRightGUI):
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
}

enum InputEvent {
    case key(product: String, usage: UInt16, isDown: Bool, timestamp: UInt64)
    case modifier(product: String, state: ModifierState, timestamp: UInt64)
    case button(product: String, button: UInt8, isDown: Bool, timestamp: UInt64)
    case moveX(product: String, delta: Int16, timestamp: UInt64)
    case moveY(product: String, delta: Int16, timestamp: UInt64)
    case wheel(product: String, delta: Int16, timestamp: UInt64)

    var packetType: PacketType {
        switch self {
        case let .key(_, _, isDown, _):
            return isDown ? .keyDown : .keyUp
        case .modifier:
            return .modifier
        case let .button(_, _, isDown, _):
            return isDown ? .buttonDown : .buttonUp
        case .moveX:
            return .moveX
        case .moveY:
            return .moveY
        case .wheel:
            return .wheel
        }
    }

    var logDescription: String {
        switch self {
        case let .key(product, usage, isDown, timestamp):
            return "[KBD] product=\(product) usage=\(usage) \(isDown ? "down" : "up") ts=\(timestamp)"
        case let .modifier(product, state, timestamp):
            return "[MOD] product=\(product) state=\(state) ts=\(timestamp)"
        case let .button(product, button, isDown, timestamp):
            return "[BTN] product=\(product) button=\(button) \(isDown ? "down" : "up") ts=\(timestamp)"
        case let .moveX(product, delta, timestamp):
            return "[PTR] product=\(product) dx=\(delta) ts=\(timestamp)"
        case let .moveY(product, delta, timestamp):
            return "[PTR] product=\(product) dy=\(delta) ts=\(timestamp)"
        case let .wheel(product, delta, timestamp):
            return "[WHL] product=\(product) wheel=\(delta) ts=\(timestamp)"
        }
    }
}
