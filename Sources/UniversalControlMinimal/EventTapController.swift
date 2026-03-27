import ApplicationServices
import Foundation

final class EventTapController: @unchecked Sendable {
    private let remoteModeController: RemoteModeController
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?

    init(remoteModeController: RemoteModeController) {
        self.remoteModeController = remoteModeController
    }

    func start() -> Bool {
        let started = LockedFlag()
        let ready = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                return
            }

            started.value = self.installTap()
            ready.signal()

            guard started.value else { return }
            CFRunLoopRun()
        }

        thread.name = "event.tap.thread"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        ready.wait()
        return started.value
    }

    private func installTap() -> Bool {
        let events: [CGEventType] = [
            .keyDown,
            .keyUp,
            .flagsChanged,
            .mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]

        let mask = events.reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            // `kCGSessionEventTap` is stable, but the imported enum case name varies across toolchains.
            tap: CGEventTapLocation(rawValue: 1)!,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handleEventTap(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = runLoopSource
        return true
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode: CGKeyCode?
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        } else {
            keyCode = nil
        }

        if remoteModeController.shouldSuppress(eventType: type, keyCode: keyCode) {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
