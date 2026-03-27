import Foundation

final class PacketEncoder: @unchecked Sendable {
    private var sequence: UInt32 = 0

    func session(active: Bool) -> Data {
        packet(kind: .session) { payload in
            payload.append(active ? 1 : 0)
        }
    }

    func key(usage: UInt16, isDown: Bool) -> Data {
        packet(kind: .key) { payload in
            payload.appendLittleEndian(usage)
            payload.append(isDown ? 1 : 0)
        }
    }

    func button(_ button: UInt8, isDown: Bool) -> Data {
        packet(kind: .button) { payload in
            payload.append(button)
            payload.append(isDown ? 1 : 0)
        }
    }

    func pointer(dx: Int16, dy: Int16) -> Data {
        packet(kind: .pointer) { payload in
            payload.appendLittleEndian(dx)
            payload.appendLittleEndian(dy)
        }
    }

    func wheel(deltaY: Int16) -> Data {
        packet(kind: .wheel) { payload in
            payload.appendLittleEndian(deltaY)
        }
    }

    func sync(state: RemoteSyncState) -> Data {
        packet(kind: .sync) { payload in
            payload.append(state.modifierMask)
            payload.append(state.buttonMask)
            payload.append(UInt8(clamping: state.pressedKeys.count))
            for usage in state.pressedKeys.prefix(Int(UInt8.max)) {
                payload.appendLittleEndian(usage)
            }
        }
    }

    private func packet(kind: PacketKind, payloadBuilder: (inout Data) -> Void) -> Data {
        var data = Data()
        data.append("UCM1".data(using: .utf8)!)
        data.append(1)
        data.appendLittleEndian(sequence)
        data.append(kind.rawValue)
        payloadBuilder(&data)
        sequence &+= 1
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
