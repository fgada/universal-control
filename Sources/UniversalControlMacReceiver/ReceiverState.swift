import Foundation

final class ReceiverState {
    private static let syncTimeout: TimeInterval = 0.300
    private static let sessionIdleTimeout: TimeInterval = 5 * 60

    private let injector: InputInjector
    private let keyboardRepeatConfiguration = KeyboardRepeatConfiguration.load()
    private var pressedKeys: Set<UInt16> = []
    private var loggedUnknownUsages: Set<UInt16> = []
    private var loggedUnknownButtons: Set<UInt8> = []
    private var repeatablePressedKeysInOrder: [UInt16] = []

    private var sessionActive = false
    private var awaitingResync = false
    private var modifierMask: UInt8 = 0
    private var buttonMask: UInt8 = 0
    private var lastSync: ContinuousClock.Instant?
    private var nextKeyRepeat: ContinuousClock.Instant?
    private var repeatingKeyUsage: UInt16?
    private let clock = ContinuousClock()

    init(injector: InputInjector) {
        self.injector = injector
        print(
            "Keyboard repeat configured: delay=\(keyboardRepeatConfiguration.initialDelayMilliseconds)ms "
                + "interval=\(keyboardRepeatConfiguration.intervalMilliseconds)ms"
        )
    }

    func handle(_ body: PacketBody) {
        switch body {
        case let .session(active):
            handleSession(active: active)
        case let .key(packet):
            handleKey(packet)
        case let .button(packet):
            handleButton(packet)
        case let .pointer(packet):
            guard sessionActive, !awaitingResync else { return }
            injector.sendRelativePointer(
                dx: packet.dx,
                dy: packet.dy,
                buttonMask: buttonMask,
                modifierMask: modifierMask
            )
        case let .wheel(packet):
            guard sessionActive, !awaitingResync else { return }
            injector.sendWheel(deltaY: packet.deltaY, modifierMask: modifierMask)
        case let .sync(packet):
            handleSync(packet)
        case let .text(text):
            injector.sendText(text)
        }
    }

    func checkTimers() {
        checkForSyncTimeout()
        checkForKeyRepeat()
    }

    func stop() {
        handleSession(active: false)
    }

    private func handleSession(active: Bool) {
        releaseAll()
        sessionActive = active
        lastSync = active ? clock.now : nil
        awaitingResync = false
        print("Remote session \(active ? "active" : "inactive")")
    }

    private func handleKey(_ packet: KeyPacket) {
        guard sessionActive, !awaitingResync else { return }

        if packet.usage == SyntheticUsage.kanaABCToggle {
            if packet.isDown {
                if pressedKeys.insert(packet.usage).inserted {
                    injector.sendKanaABCToggle(modifierMask: modifierMask)
                }
            } else {
                pressedKeys.remove(packet.usage)
            }
            return
        }

        if let modifierBit = HIDUsageMapper.modifierBit(for: packet.usage) {
            setModifier(bit: modifierBit, isDown: packet.isDown)
            return
        }

        guard let mapping = HIDUsageMapper.mapping(for: packet.usage) else {
            logUnknownUsage(packet.usage)
            return
        }

        if packet.isDown {
            if pressedKeys.insert(packet.usage).inserted {
                injector.sendKey(mapping, isDown: true, modifierMask: modifierMask)
                handlePressedRepeatableKey(packet.usage)
            }
        } else if pressedKeys.remove(packet.usage) != nil {
            injector.sendKey(mapping, isDown: false, modifierMask: modifierMask)
            handleReleasedRepeatableKey(packet.usage)
        }
    }

    private func handleButton(_ packet: ButtonPacket) {
        guard sessionActive, !awaitingResync else { return }
        guard let bit = Self.buttonMaskBit(for: packet.button) else {
            if loggedUnknownButtons.insert(packet.button).inserted {
                fputs("Ignoring unsupported mouse button: \(packet.button)\n", stderr)
            }
            return
        }

        let isAlreadyDown = buttonMask & bit != 0
        guard isAlreadyDown != packet.isDown else { return }

        injector.sendButton(packet.button, isDown: packet.isDown, modifierMask: modifierMask)
        if packet.isDown {
            buttonMask |= bit
        } else {
            buttonMask &= ~bit
        }
    }

    private func handleSync(_ packet: SyncPacket) {
        guard sessionActive else { return }
        if awaitingResync {
            print("Sync restored; resuming remote session.")
        }

        lastSync = clock.now
        awaitingResync = false
        syncModifiers(to: packet.modifierMask)
        syncButtons(to: packet.buttonMask)
        syncKeys(to: Set(packet.pressedKeys))
    }

    private func syncModifiers(to desiredMask: UInt8) {
        for bit in 0..<8 {
            setModifier(bit: bit, isDown: desiredMask & (1 << bit) != 0)
        }
    }

    private func syncButtons(to desiredMask: UInt8) {
        for button in UInt8(1)...UInt8(3) {
            guard let bit = Self.buttonMaskBit(for: button) else { continue }
            handleButton(ButtonPacket(button: button, isDown: desiredMask & bit != 0))
        }
    }

    private func syncKeys(to desiredKeys: Set<UInt16>) {
        for usage in pressedKeys.subtracting(desiredKeys) {
            handleKey(KeyPacket(usage: usage, isDown: false))
        }
        for usage in desiredKeys.subtracting(pressedKeys) {
            handleKey(KeyPacket(usage: usage, isDown: true))
        }
    }

    private func setModifier(bit: Int, isDown: Bool) {
        let bitMask = UInt8(1 << bit)
        guard (modifierMask & bitMask != 0) != isDown else { return }

        let usage = HIDUsageMapper.modifierUsage(forBit: bit)
        guard let mapping = HIDUsageMapper.mapping(for: usage) else {
            logUnknownUsage(usage)
            return
        }

        let resultingMask = isDown ? (modifierMask | bitMask) : (modifierMask & ~bitMask)
        injector.sendKey(mapping, isDown: isDown, modifierMask: resultingMask)
        modifierMask = resultingMask
    }

    private func releaseAll() {
        stopKeyRepeat()
        repeatablePressedKeysInOrder.removeAll()

        for usage in pressedKeys {
            guard let mapping = HIDUsageMapper.mapping(for: usage) else { continue }
            injector.sendKey(mapping, isDown: false, modifierMask: modifierMask)
        }
        pressedKeys.removeAll()

        for bit in 0..<8 where modifierMask & (1 << bit) != 0 {
            setModifier(bit: bit, isDown: false)
        }

        for button in UInt8(1)...UInt8(3) {
            guard let bit = Self.buttonMaskBit(for: button), buttonMask & bit != 0 else { continue }
            injector.sendButton(button, isDown: false, modifierMask: modifierMask)
        }
        buttonMask = 0
    }

    private func checkForSyncTimeout() {
        guard sessionActive, let lastSync else { return }
        let elapsed = lastSync.duration(to: clock.now)

        if elapsed > .milliseconds(Int64(Self.syncTimeout * 1_000)), !awaitingResync {
            fputs("Sync timeout; releasing remote input state and waiting for resync.\n", stderr)
            releaseAll()
            awaitingResync = true
        }

        if elapsed > .seconds(Int64(Self.sessionIdleTimeout)) {
            fputs("Session idle timeout; abandoning remote session.\n", stderr)
            sessionActive = false
            self.lastSync = nil
            awaitingResync = false
        }
    }

    private func handlePressedRepeatableKey(_ usage: UInt16) {
        repeatablePressedKeysInOrder.removeAll { $0 == usage }
        repeatablePressedKeysInOrder.append(usage)
        repeatingKeyUsage = usage
        nextKeyRepeat = clock.now.advanced(by: keyboardRepeatConfiguration.initialDelay)
    }

    private func handleReleasedRepeatableKey(_ usage: UInt16) {
        repeatablePressedKeysInOrder.removeAll { $0 == usage }
        guard repeatingKeyUsage == usage else { return }

        if let fallback = repeatablePressedKeysInOrder.last(where: { pressedKeys.contains($0) }) {
            repeatingKeyUsage = fallback
            nextKeyRepeat = clock.now.advanced(by: keyboardRepeatConfiguration.initialDelay)
        } else {
            stopKeyRepeat()
        }
    }

    private func checkForKeyRepeat() {
        guard sessionActive,
              !awaitingResync,
              let usage = repeatingKeyUsage,
              let nextKeyRepeat else { return }
        guard pressedKeys.contains(usage) else {
            stopKeyRepeat()
            return
        }
        guard clock.now >= nextKeyRepeat else { return }
        guard let mapping = HIDUsageMapper.mapping(for: usage) else {
            logUnknownUsage(usage)
            stopKeyRepeat()
            return
        }

        injector.sendKeyRepeat(mapping, modifierMask: modifierMask)
        self.nextKeyRepeat = clock.now.advanced(by: keyboardRepeatConfiguration.interval)
    }

    private func stopKeyRepeat() {
        repeatingKeyUsage = nil
        nextKeyRepeat = nil
    }

    private func logUnknownUsage(_ usage: UInt16) {
        if loggedUnknownUsages.insert(usage).inserted {
            fputs(String(format: "Ignoring unsupported HID usage: 0x%04X\n", usage), stderr)
        }
    }

    private static func buttonMaskBit(for button: UInt8) -> UInt8? {
        guard button >= 1, button <= 3 else { return nil }
        return 1 << (button - 1)
    }
}
