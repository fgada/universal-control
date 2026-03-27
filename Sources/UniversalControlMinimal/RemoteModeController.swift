import ApplicationServices
import Foundation
import IOKit.hid

final class RemoteModeController: @unchecked Sendable {
    private enum Mode {
        case local
        case remote
    }

    private let sender: UDPEventSender
    private let queue = DispatchQueue(label: "remote.mode.controller.queue", qos: .userInteractive)
    private let packetEncoder = PacketEncoder()
    private let pointerFlushTimer: DispatchSourceTimer
    private let keyRepeatTimer: DispatchSourceTimer
    private let syncTimer: DispatchSourceTimer
    private let keyRepeatConfiguration = KeyRepeatConfiguration.load()

    private var mode: Mode = .local
    private var physicalPressedKeys: Set<UInt16> = []
    private var physicalPressedButtons: Set<UInt8> = []
    private var pendingPointerDX: Int32 = 0
    private var pendingPointerDY: Int32 = 0
    private var pendingWheelLinesY: Double = 0
    private var toggleSuppressionActive = false
    private var repeatablePressedKeysInOrder: [UInt16] = []
    private var repeatingKeyUsage: UInt16?
    private var nextKeyRepeatAtUptimeNanoseconds: UInt64?

    init(sender: UDPEventSender) {
        self.sender = sender

        pointerFlushTimer = DispatchSource.makeTimerSource(queue: queue)
        pointerFlushTimer.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(1))

        keyRepeatTimer = DispatchSource.makeTimerSource(queue: queue)
        keyRepeatTimer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))

        syncTimer = DispatchSource.makeTimerSource(queue: queue)
        syncTimer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))

        pointerFlushTimer.setEventHandler { [weak self] in
            self?.flushPointerIfNeeded()
        }

        keyRepeatTimer.setEventHandler { [weak self] in
            self?.emitKeyRepeatIfNeeded()
        }

        syncTimer.setEventHandler { [weak self] in
            self?.sendSyncIfNeeded()
        }

        pointerFlushTimer.resume()
        keyRepeatTimer.resume()
        syncTimer.resume()
    }

    func handle(_ event: InputEvent) {
        queue.sync {
            switch event {
            case let .key(_, usage, isDown, _):
                handleKey(usage: usage, isDown: isDown)

            case let .button(_, button, isDown, _):
                handleButton(button: button, isDown: isDown)

            case let .pointer(_, dx, dy, _):
                guard mode == .remote else { return }
                pendingPointerDX += Int32(dx)
                pendingPointerDY += Int32(dy)

            case let .wheel(_, deltaY, _):
                guard mode == .remote else { return }
                sender.send(packetEncoder.wheel(deltaY: deltaY))
            }
        }
    }

    func handleCapturedEvent(type: CGEventType, event: CGEvent) {
        queue.sync {
            switch type {
            case .mouseMoved,
                 .leftMouseDragged,
                 .rightMouseDragged,
                 .otherMouseDragged:
                handleCapturedPointerMotion(event)

            case .leftMouseDown,
                 .leftMouseUp,
                 .rightMouseDown,
                 .rightMouseUp,
                 .otherMouseDown,
                 .otherMouseUp:
                handleCapturedButton(event)

            case .scrollWheel:
                handleCapturedScroll(event)

            default:
                break
            }
        }
    }

    func shouldSuppress(eventType: CGEventType, keyCode: CGKeyCode?) -> Bool {
        queue.sync {
            if mode == .remote {
                return eventType.isRemoteSuppressed
            }

            guard toggleSuppressionActive else { return false }
            guard eventType == .keyDown || eventType == .keyUp || eventType == .flagsChanged else { return false }
            guard let keyCode else { return false }
            return ToggleKeyCode.all.contains(keyCode)
        }
    }

    private func handleKey(usage: UInt16, isDown: Bool) {
        updatePhysicalKeyState(usage: usage, isDown: isDown)

        if isDown, usage == ToggleChord.returnUsage, currentModifiers.hasToggleModifiers {
            toggleSuppressionActive = true
            toggleRemoteMode()
        }

        defer { clearToggleSuppressionIfNeeded() }

        guard mode == .remote else {
            if !isDown {
                handleReleasedRepeatableKey(usage)
            }
            return
        }

        guard !shouldSuppressForwarding(for: usage) else {
            if !isDown {
                handleReleasedRepeatableKey(usage)
            }
            return
        }

        sender.send(packetEncoder.key(usage: usage, isDown: isDown))

        guard isRepeatableKey(usage) else {
            if !isDown {
                handleReleasedRepeatableKey(usage)
            }
            return
        }

        if isDown {
            handlePressedRepeatableKey(usage)
        } else {
            handleReleasedRepeatableKey(usage)
        }
    }

    private func handleButton(button: UInt8, isDown: Bool) {
        updatePhysicalButtonState(button: button, isDown: isDown)

        guard mode == .remote else { return }
        sender.send(packetEncoder.button(button, isDown: isDown))
    }

    private func handleCapturedPointerMotion(_ event: CGEvent) {
        guard mode == .remote else { return }

        let dx = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int16(clamping: event.getIntegerValueField(.mouseEventDeltaY))
        guard dx != 0 || dy != 0 else { return }

        pendingPointerDX += Int32(dx)
        pendingPointerDY += Int32(dy)
    }

    private func handleCapturedButton(_ event: CGEvent) {
        let button = UInt8(clamping: event.getIntegerValueField(.mouseEventButtonNumber) + 1)
        let isDown: Bool

        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            isDown = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            isDown = false
        default:
            return
        }

        handleButton(button: button, isDown: isDown)
    }

    private func handleCapturedScroll(_ event: CGEvent) {
        guard mode == .remote else { return }

        let deltaY = normalizedScrollLines(from: event)
        guard deltaY != 0 else { return }

        sender.send(packetEncoder.wheel(deltaY: deltaY))
    }

    private func normalizedScrollLines(from event: CGEvent) -> Int16 {
        let discreteLines = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        if discreteLines != 0 {
            pendingWheelLinesY = 0
            return Int16(clamping: discreteLines)
        }

        let fixedPointLines = Double(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)) / 65536.0
        guard fixedPointLines != 0 else { return 0 }

        pendingWheelLinesY += fixedPointLines
        let wholeLines = Int(pendingWheelLinesY.rounded(.towardZero))
        pendingWheelLinesY -= Double(wholeLines)
        return Int16(clamping: wholeLines)
    }

    private func toggleRemoteMode() {
        switch mode {
        case .local:
            mode = .remote
            pendingWheelLinesY = 0
            stopKeyRepeat()
            repeatablePressedKeysInOrder.removeAll()
            sender.send(packetEncoder.session(active: true))
            sendSync()
            print("Remote mode enabled")

        case .remote:
            mode = .local
            pendingPointerDX = 0
            pendingPointerDY = 0
            pendingWheelLinesY = 0
            stopKeyRepeat()
            repeatablePressedKeysInOrder.removeAll()
            sender.send(packetEncoder.session(active: false))
            print("Remote mode disabled")
        }
    }

    private func flushPointerIfNeeded() {
        guard mode == .remote else {
            pendingPointerDX = 0
            pendingPointerDY = 0
            return
        }

        guard pendingPointerDX != 0 || pendingPointerDY != 0 else { return }

        let dx = Int16(clamping: pendingPointerDX)
        let dy = Int16(clamping: pendingPointerDY)
        pendingPointerDX = 0
        pendingPointerDY = 0
        sender.send(packetEncoder.pointer(dx: dx, dy: dy))
    }

    private func sendSyncIfNeeded() {
        guard mode == .remote else { return }
        sendSync()
    }

    private func emitKeyRepeatIfNeeded() {
        guard mode == .remote else { return }
        guard let usage = repeatingKeyUsage else { return }
        guard let nextKeyRepeatAtUptimeNanoseconds else { return }
        guard physicalPressedKeys.contains(usage) else {
            stopKeyRepeat()
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= nextKeyRepeatAtUptimeNanoseconds else { return }

        sender.send(packetEncoder.key(usage: usage, isDown: true))
        self.nextKeyRepeatAtUptimeNanoseconds = now + keyRepeatConfiguration.intervalNanoseconds
    }

    private func sendSync() {
        sender.send(packetEncoder.sync(state: makeSyncState()))
    }

    private func makeSyncState() -> RemoteSyncState {
        let suppressedToggleUsages = toggleSuppressionActive ? ToggleChord.usages : []
        let effectivePressedKeys = physicalPressedKeys.subtracting(suppressedToggleUsages)
        let modifierState = ModifierState.from(usages: effectivePressedKeys)
        let pressedKeys = effectivePressedKeys
            .filter { ModifierState(usage: $0) == nil }
            .sorted()

        return RemoteSyncState(
            modifierMask: modifierState.rawValue,
            buttonMask: physicalPressedButtons.reduce(into: UInt8(0)) { mask, button in
                guard let bit = buttonMaskBit(for: button) else { return }
                mask |= bit
            },
            pressedKeys: pressedKeys
        )
    }

    private var currentModifiers: ModifierState {
        ModifierState.from(usages: physicalPressedKeys)
    }

    private func shouldSuppressForwarding(for usage: UInt16) -> Bool {
        toggleSuppressionActive && ToggleChord.isPartOfChord(usage)
    }

    private func isRepeatableKey(_ usage: UInt16) -> Bool {
        ModifierState(usage: usage) == nil && !ToggleChord.isPartOfChord(usage)
    }

    private func handlePressedRepeatableKey(_ usage: UInt16) {
        if let existingIndex = repeatablePressedKeysInOrder.firstIndex(of: usage) {
            repeatablePressedKeysInOrder.remove(at: existingIndex)
        }

        repeatablePressedKeysInOrder.append(usage)
        repeatingKeyUsage = usage
        nextKeyRepeatAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds + keyRepeatConfiguration.initialDelayNanoseconds
    }

    private func handleReleasedRepeatableKey(_ usage: UInt16) {
        if let existingIndex = repeatablePressedKeysInOrder.firstIndex(of: usage) {
            repeatablePressedKeysInOrder.remove(at: existingIndex)
        }

        guard repeatingKeyUsage == usage else { return }

        if let fallbackUsage = repeatablePressedKeysInOrder.last, physicalPressedKeys.contains(fallbackUsage) {
            repeatingKeyUsage = fallbackUsage
            nextKeyRepeatAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds + keyRepeatConfiguration.initialDelayNanoseconds
            return
        }

        stopKeyRepeat()
    }

    private func stopKeyRepeat() {
        repeatingKeyUsage = nil
        nextKeyRepeatAtUptimeNanoseconds = nil
    }

    private func updatePhysicalKeyState(usage: UInt16, isDown: Bool) {
        if isDown {
            physicalPressedKeys.insert(usage)
        } else {
            physicalPressedKeys.remove(usage)
        }
    }

    private func updatePhysicalButtonState(button: UInt8, isDown: Bool) {
        if isDown {
            physicalPressedButtons.insert(button)
        } else {
            physicalPressedButtons.remove(button)
        }
    }

    private func clearToggleSuppressionIfNeeded() {
        guard toggleSuppressionActive else { return }
        if physicalPressedKeys.isDisjoint(with: ToggleChord.usages) {
            toggleSuppressionActive = false
        }
    }

    private func buttonMaskBit(for button: UInt8) -> UInt8? {
        switch button {
        case 1:
            return 1 << 0
        case 2:
            return 1 << 1
        case 3:
            return 1 << 2
        default:
            return nil
        }
    }
}

private enum ToggleKeyCode {
    static let all: Set<CGKeyCode> = [
        36, // return
        54, // right command
        55, // left command
        58, // left option
        59, // left control
        61, // right option
        62 // right control
    ]
}

private extension CGEventType {
    var isRemoteSuppressed: Bool {
        switch self {
        case .keyDown,
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
             .scrollWheel:
            return true
        default:
            return false
        }
    }
}

private struct KeyRepeatConfiguration {
    let initialDelayNanoseconds: UInt64
    let intervalNanoseconds: UInt64

    static func load() -> KeyRepeatConfiguration {
        let globalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let initialUnits = (globalDefaults["InitialKeyRepeat"] as? NSNumber)?.intValue ?? 15
        let repeatUnits = (globalDefaults["KeyRepeat"] as? NSNumber)?.intValue ?? 2

        let initialDelayMilliseconds = max(initialUnits, 1) * 15
        let intervalMilliseconds = max(repeatUnits, 1) * 15

        return KeyRepeatConfiguration(
            initialDelayNanoseconds: UInt64(initialDelayMilliseconds) * 1_000_000,
            intervalNanoseconds: UInt64(intervalMilliseconds) * 1_000_000
        )
    }
}
