import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation
import IOKit.hid

final class RemoteModeController: @unchecked Sendable {
    private enum Mode {
        case local
        case remote
    }

    private let sender: UDPEventSender
    private var inputConfiguration: InputConfiguration
    private let queue = DispatchQueue(label: "remote.mode.controller.queue", qos: .userInteractive)
    private let packetEncoder = PacketEncoder()
    private let pointerFlushTimer: DispatchSourceTimer
    private let syncTimer: DispatchSourceTimer
    private var jitterController: JitterModeController!

    private var mode: Mode = .local
    private var physicalPressedKeys: Set<UInt16> = []
    private var physicalPressedButtons: Set<UInt8> = []
    private var pendingPointerDX: Int32 = 0
    private var pendingPointerDY: Int32 = 0
    private var pointerDXRemainder: Double = 0
    private var pointerDYRemainder: Double = 0
    private var jitterDXRemainders: [Int: Double] = [:]
    private var jitterDYRemainders: [Int: Double] = [:]
    private var pendingWheelLinesY: Double = 0
    private var toggleSuppressionActive = false
    private var selectedTargetIndex = 0
    private var jitterTargetIndices: Set<Int> = []

    init(sender: UDPEventSender, inputConfiguration: InputConfiguration) {
        self.sender = sender
        self.inputConfiguration = inputConfiguration

        pointerFlushTimer = DispatchSource.makeTimerSource(queue: queue)
        pointerFlushTimer.schedule(deadline: .now() + .milliseconds(1), repeating: .milliseconds(1))

        syncTimer = DispatchSource.makeTimerSource(queue: queue)
        syncTimer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))

        jitterController = JitterModeController(queue: queue) { [weak self] dx, dy in
            self?.sendJitterPointer(dx: dx, dy: dy)
        }

        pointerFlushTimer.setEventHandler { [weak self] in
            self?.flushPointerIfNeeded()
        }

        syncTimer.setEventHandler { [weak self] in
            self?.sendSyncIfNeeded()
        }

        pointerFlushTimer.resume()
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
                enqueuePointerDelta(dx: dx, dy: dy)

            case let .wheel(_, deltaY, _):
                guard mode == .remote else { return }
                sendScaledWheel(deltaY: Double(deltaY))
            }
        }
    }

    func handleCapturedEvent(type: CGEventType, event: CGEvent) {
        queue.sync {
            if MacGestureEventType.contains(type) {
                handleCapturedGesture(event)
                return
            }

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

        if isDown, let targetIndex = ToggleKey.targetIndex(for: usage) {
            toggleSuppressionActive = true
            selectRemoteTarget(at: targetIndex)
        } else if isDown, usage == ToggleKey.sendTextUsage {
            toggleSuppressionActive = true
            sendClipboardText()
        } else if isDown, usage == ToggleKey.remoteModeUsage {
            toggleSuppressionActive = true
            toggleRemoteMode()
        } else if isDown, usage == ToggleKey.jitterModeUsage {
            toggleSuppressionActive = true
            toggleJitterMode()
        }

        defer { clearToggleSuppressionIfNeeded() }

        guard mode == .remote else {
            return
        }

        guard !shouldSuppressForwarding(for: usage) else {
            return
        }

        let inputProfile = activeInputProfile
        if !inputProfile.hasKeyMappings {
            sender.send(packetEncoder.key(usage: usage, isDown: isDown))
            return
        }

        sendSync()
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

        enqueuePointerDelta(dx: dx, dy: dy)
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

        let deltaY = rawScrollLines(from: event)
        guard deltaY != 0 else { return }

        sendScaledWheel(deltaY: deltaY)
    }

    private func handleCapturedGesture(_ event: CGEvent) {
        guard mode == .remote else { return }
        guard let serialized = event.data else {
            fputs("Failed to serialize gesture event.\n", stderr)
            return
        }

        let eventData = serialized as Data
        guard let packet = packetEncoder.gesture(eventData) else {
            fputs("Gesture event exceeds \(PacketEncoder.maximumGestureBytes) bytes; not sent.\n", stderr)
            return
        }
        sender.send(packet)
    }

    private func rawScrollLines(from event: CGEvent) -> Double {
        let discreteLines = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        if discreteLines != 0 {
            return Double(discreteLines)
        }

        let fixedPointLines = Double(event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)) / 65536.0
        return fixedPointLines
    }

    private func toggleRemoteMode() {
        let wasTransportActive = isTransportActive(for: selectedTargetIndex)

        switch mode {
        case .local:
            reloadInputConfiguration()
            mode = .remote
            pendingWheelLinesY = 0
            clearPointerState()
            print("Remote mode enabled")

        case .remote:
            mode = .local
            clearPointerState()
            pendingWheelLinesY = 0
            print("Remote mode disabled")
        }

        updateTransportSession(
            for: selectedTargetIndex,
            previouslyActive: wasTransportActive
        )
    }

    private func sendClipboardText() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            print("F16: sender clipboard does not contain text.")
            return
        }
        guard let packet = packetEncoder.text(text) else {
            fputs(
                "F16: clipboard text exceeds \(PacketEncoder.maximumTextBytes) UTF-8 bytes; not sent.\n",
                stderr
            )
            return
        }

        sender.send(packet)
        print("F16: sent \(text.utf8.count) UTF-8 bytes to the selected receiver.")
    }

    private func selectRemoteTarget(at targetIndex: Int) {
        guard let targetHost = sender.targetHost(at: targetIndex) else {
            print("No remote target configured for F\(13 + targetIndex).")
            return
        }

        let targetChanged = selectedTargetIndex != targetIndex
        let previousTargetIndex = selectedTargetIndex
        let wasPreviousTargetActive = isTransportActive(for: previousTargetIndex)
        let wasNewTargetActive = isTransportActive(for: targetIndex)

        if targetChanged {
            clearPointerState()
            pendingWheelLinesY = 0
            guard sender.selectTarget(at: targetIndex) else { return }
            selectedTargetIndex = targetIndex

            updateTransportSession(
                for: previousTargetIndex,
                previouslyActive: wasPreviousTargetActive
            )
        }

        if mode == .local {
            reloadInputConfiguration()
            mode = .remote
            pendingWheelLinesY = 0
            clearPointerState()
            print("Remote mode enabled")
        }

        print("Remote target selected: F\(13 + targetIndex) -> \(targetHost)")

        updateTransportSession(
            for: targetIndex,
            previouslyActive: wasNewTargetActive
        )
    }

    private func reloadInputConfiguration() {
        do {
            inputConfiguration = try InputConfiguration.loadDefault()
            if let sourcePath = inputConfiguration.sourcePath {
                print("Reloaded input configuration from \(sourcePath)")
            } else {
                print("Reloaded default input configuration")
            }

            for line in inputConfiguration.logLines() {
                print(line)
            }
        } catch {
            print("Failed to reload input configuration: \(error)")
            print("Keeping existing input configuration")
        }
    }

    private func toggleJitterMode() {
        let targetIndex = selectedTargetIndex
        let wasTransportActive = isTransportActive(for: targetIndex)
        let isEnabled: Bool

        if jitterTargetIndices.remove(targetIndex) != nil {
            isEnabled = false
        } else {
            jitterTargetIndices.insert(targetIndex)
            isEnabled = true
        }

        clearJitterPointerState(for: targetIndex)
        jitterController.setEnabled(!jitterTargetIndices.isEmpty)

        print("Jitter mode for F\(13 + targetIndex) \(isEnabled ? "enabled" : "disabled")")
        updateTransportSession(
            for: targetIndex,
            previouslyActive: wasTransportActive
        )
    }

    private func flushPointerIfNeeded() {
        guard mode == .remote else {
            clearPointerState()
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
        guard hasActiveTransport else { return }
        sendAllSyncs()
    }

    private func sendAllSyncs() {
        if isTransportActive(for: selectedTargetIndex) {
            sendSync()
        }
        let jitterOnlyTargets = jitterTargetIndices.subtracting([selectedTargetIndex])
        guard !jitterOnlyTargets.isEmpty else { return }
        sender.send(
            packetEncoder.sync(state: .empty),
            toTargetIndices: jitterOnlyTargets
        )
    }

    private func sendSync() {
        sender.send(packetEncoder.sync(state: makeSyncState()))
    }

    private func makeSyncState() -> RemoteSyncState {
        guard mode == .remote else { return .empty }

        let suppressedToggleUsages = toggleSuppressionActive ? ToggleKey.usages : []
        let inputProfile = activeInputProfile
        let effectivePressedKeys = Set(
            physicalPressedKeys
                .subtracting(suppressedToggleUsages)
                .map { inputProfile.map($0) }
        )
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

    private func shouldSuppressForwarding(for usage: UInt16) -> Bool {
        toggleSuppressionActive && ToggleKey.isToggleUsage(usage)
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
        if physicalPressedKeys.isDisjoint(with: ToggleKey.usages) {
            toggleSuppressionActive = false
        }
    }

    private var hasActiveTransport: Bool {
        mode == .remote || !jitterTargetIndices.isEmpty
    }

    private func isTransportActive(for targetIndex: Int) -> Bool {
        (mode == .remote && targetIndex == selectedTargetIndex)
            || jitterTargetIndices.contains(targetIndex)
    }

    private var activeInputProfile: InputProfile {
        inputConfiguration.profile(forTargetIndex: selectedTargetIndex)
    }

    private func updateTransportSession(for targetIndex: Int, previouslyActive: Bool) {
        let isActive = isTransportActive(for: targetIndex)

        switch (previouslyActive, isActive) {
        case (false, true):
            sender.send(
                packetEncoder.session(active: true),
                toTargetAt: targetIndex
            )
            sendSync(toTargetAt: targetIndex)

        case (true, true):
            sendSync(toTargetAt: targetIndex)

        case (true, false):
            if targetIndex == selectedTargetIndex {
                clearPointerState()
                pendingWheelLinesY = 0
            }
            sender.send(
                packetEncoder.session(active: false),
                toTargetAt: targetIndex
            )

        case (false, false):
            break
        }
    }

    private func sendSync(toTargetAt targetIndex: Int) {
        let state = mode == .remote && targetIndex == selectedTargetIndex
            ? makeSyncState()
            : .empty
        sender.send(
            packetEncoder.sync(state: state),
            toTargetAt: targetIndex
        )
    }

    private func enqueuePointerDelta(dx: Int16, dy: Int16) {
        let scaledDelta = scalePointerDelta(dx: dx, dy: dy)
        pendingPointerDX += scaledDelta.dx
        pendingPointerDY += scaledDelta.dy
    }

    private func sendJitterPointer(dx: Int16, dy: Int16) {
        guard jitterController.isEnabled, !jitterTargetIndices.isEmpty else { return }
        for targetIndex in jitterTargetIndices.sorted() {
            let scaledDelta = scaleJitterPointerDelta(dx: dx, dy: dy, targetIndex: targetIndex)
            let scaledDX = Int16(clamping: scaledDelta.dx)
            let scaledDY = Int16(clamping: scaledDelta.dy)
            guard scaledDX != 0 || scaledDY != 0 else { continue }

            sender.send(
                packetEncoder.pointer(dx: scaledDX, dy: scaledDY),
                toTargetAt: targetIndex
            )
        }
    }

    private func sendScaledWheel(deltaY: Double) {
        let scaledDeltaY = deltaY * activeInputProfile.scrollSensitivity + pendingWheelLinesY
        let linesToSend = Int16(clamping: Int(scaledDeltaY.rounded(.towardZero)))
        pendingWheelLinesY = scaledDeltaY - Double(linesToSend)

        guard linesToSend != 0 else { return }
        sender.send(packetEncoder.wheel(deltaY: linesToSend))
    }

    private func scalePointerDelta(dx: Int16, dy: Int16) -> (dx: Int32, dy: Int32) {
        let scaledDX = Double(dx) * activeInputProfile.cursorSensitivity + pointerDXRemainder
        let scaledDY = Double(dy) * activeInputProfile.cursorSensitivity + pointerDYRemainder
        let wholeDX = Int32(scaledDX.rounded(.towardZero))
        let wholeDY = Int32(scaledDY.rounded(.towardZero))

        pointerDXRemainder = scaledDX - Double(wholeDX)
        pointerDYRemainder = scaledDY - Double(wholeDY)

        return (wholeDX, wholeDY)
    }

    private func scaleJitterPointerDelta(
        dx: Int16,
        dy: Int16,
        targetIndex: Int
    ) -> (dx: Int32, dy: Int32) {
        let profile = inputConfiguration.profile(forTargetIndex: targetIndex)
        let scaledDX = Double(dx) * profile.cursorSensitivity + (jitterDXRemainders[targetIndex] ?? 0)
        let scaledDY = Double(dy) * profile.cursorSensitivity + (jitterDYRemainders[targetIndex] ?? 0)
        let wholeDX = Int32(scaledDX.rounded(.towardZero))
        let wholeDY = Int32(scaledDY.rounded(.towardZero))

        jitterDXRemainders[targetIndex] = scaledDX - Double(wholeDX)
        jitterDYRemainders[targetIndex] = scaledDY - Double(wholeDY)

        return (wholeDX, wholeDY)
    }

    private func clearPointerState() {
        pendingPointerDX = 0
        pendingPointerDY = 0
        pointerDXRemainder = 0
        pointerDYRemainder = 0
    }

    private func clearJitterPointerState(for targetIndex: Int) {
        jitterDXRemainders.removeValue(forKey: targetIndex)
        jitterDYRemainders.removeValue(forKey: targetIndex)
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
        CGKeyCode(kVK_F13),
        CGKeyCode(kVK_F14),
        CGKeyCode(kVK_F15),
        CGKeyCode(kVK_F16),
        CGKeyCode(kVK_F18),
        CGKeyCode(kVK_F19)
    ]
}

private extension CGEventType {
    var isRemoteSuppressed: Bool {
        if MacGestureEventType.contains(self) {
            return true
        }

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
