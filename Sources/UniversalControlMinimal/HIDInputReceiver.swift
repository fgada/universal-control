import Foundation
import IOKit.hid

final class HIDInputReceiver: @unchecked Sendable {
    private let eventSink: @Sendable (InputEvent) -> Void
    private let queue = DispatchQueue(label: "hid.receiver.queue", qos: .userInteractive)

    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?

    init(eventSink: @escaping @Sendable (InputEvent) -> Void) {
        self.eventSink = eventSink
    }

    func run() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.start() else {
                exit(EXIT_FAILURE)
            }
            CFRunLoopRun()
        }
    }

    private func start() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        runLoop = CFRunLoopGetCurrent()

        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        let matches: [CFDictionary] = [
            keyboardMatch as CFDictionary
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let receiver = Unmanaged<HIDInputReceiver>.fromOpaque(context).takeUnretainedValue()
            receiver.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let receiver = Unmanaged<HIDInputReceiver>.fromOpaque(context).takeUnretainedValue()
            receiver.handleDeviceRemoved(device)
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let receiver = Unmanaged<HIDInputReceiver>.fromOpaque(context).takeUnretainedValue()
            receiver.handleInputValue(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let message = ioReturnMessage(result)
            fputs("IOHIDManagerOpen failed: \(result) (\(message))\n", stderr)
            return false
        }

        print("HIDInputReceiver started")
        print("Input Monitoring permission is required to observe global input on macOS.")
        return true
    }

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        let product = stringProperty(kIOHIDProductKey, device: device) ?? "unknown"
        let vendorID = intProperty(kIOHIDVendorIDKey, device: device)?.description ?? "?"
        let productID = intProperty(kIOHIDProductIDKey, device: device)?.description ?? "?"
        print("Connected: \(product) vendor: \(vendorID) product: \(productID)")
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let product = stringProperty(kIOHIDProductKey, device: device) ?? "unknown"
        print("Removed: \(product)")
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)

        let usagePage = IOHIDElementGetUsagePage(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let timestamp = IOHIDValueGetTimeStamp(value)
        let product = stringProperty(kIOHIDProductKey, device: device) ?? "Unknown"

        guard usagePage == UInt32(kHIDPage_KeyboardOrKeypad) else {
            return
        }

        let usage = IOHIDElementGetUsage(element)
        handleKeyboard(product: product, usage: usage, value: intValue, timestamp: timestamp)
    }

    private func handleKeyboard(product: String, usage: UInt32, value: CFIndex, timestamp: UInt64) {
        let isDown = value != 0
        eventSink(.key(product: product, usage: UInt16(clamping: usage), isDown: isDown, timestamp: timestamp))
    }

    private func stringProperty(_ key: String, device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func intProperty(_ key: String, device: IOHIDDevice) -> Int? {
        if let number = IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func ioReturnMessage(_ value: IOReturn) -> String {
        if value == kIOReturnNotPermitted {
            return "Input Monitoring permission missing"
        }
        return "check macOS privacy settings or HID access"
    }
}
