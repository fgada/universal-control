import Foundation

enum PacketKind: UInt8 {
    case session = 1
    case key = 2
    case button = 3
    case pointer = 4
    case wheel = 5
    case sync = 6
    case text = 7
}

enum SyntheticUsage {
    static let kanaABCToggle = UInt16(0xFF04)
}

struct KeyPacket: Equatable {
    let usage: UInt16
    let isDown: Bool
}

struct ButtonPacket: Equatable {
    let button: UInt8
    let isDown: Bool
}

struct PointerPacket: Equatable {
    let dx: Int16
    let dy: Int16
}

struct WheelPacket: Equatable {
    let deltaY: Int16
}

struct SyncPacket: Equatable {
    let modifierMask: UInt8
    let buttonMask: UInt8
    let pressedKeys: [UInt16]
}

enum PacketBody: Equatable {
    case session(active: Bool)
    case key(KeyPacket)
    case button(ButtonPacket)
    case pointer(PointerPacket)
    case wheel(WheelPacket)
    case sync(SyncPacket)
    case text(String)
}

struct DecodedPacket: Equatable {
    let sequence: UInt32
    let body: PacketBody
}

enum PacketDecodingError: Error, Equatable, CustomStringConvertible {
    case malformedHeader
    case malformedPayload(PacketKind)

    var description: String {
        switch self {
        case .malformedHeader:
            return "Ignoring malformed packet header."
        case let .malformedPayload(kind):
            return "Ignoring malformed \(kind.logName) packet."
        }
    }
}

enum ProtocolDecoder {
    private static let headerLength = 10
    private static let maximumTextBytes = 60 * 1024

    static func decode(_ data: Data) throws -> DecodedPacket {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength,
              Array(bytes[0..<4]) == Array("UCM1".utf8),
              bytes[4] == 1,
              let kind = PacketKind(rawValue: bytes[9]) else {
            throw PacketDecodingError.malformedHeader
        }

        let sequence = readUInt32(bytes, at: 5)
        let payload = Array(bytes.dropFirst(headerLength))
        let body: PacketBody

        switch kind {
        case .session:
            guard payload.count == 1 else { throw PacketDecodingError.malformedPayload(kind) }
            body = .session(active: payload[0] != 0)

        case .key:
            guard payload.count == 3 else { throw PacketDecodingError.malformedPayload(kind) }
            body = .key(KeyPacket(usage: readUInt16(payload, at: 0), isDown: payload[2] != 0))

        case .button:
            guard payload.count == 2 else { throw PacketDecodingError.malformedPayload(kind) }
            body = .button(ButtonPacket(button: payload[0], isDown: payload[1] != 0))

        case .pointer:
            guard payload.count == 4 else { throw PacketDecodingError.malformedPayload(kind) }
            body = .pointer(PointerPacket(
                dx: Int16(bitPattern: readUInt16(payload, at: 0)),
                dy: Int16(bitPattern: readUInt16(payload, at: 2))
            ))

        case .wheel:
            guard payload.count == 2 else { throw PacketDecodingError.malformedPayload(kind) }
            body = .wheel(WheelPacket(deltaY: Int16(bitPattern: readUInt16(payload, at: 0))))

        case .sync:
            guard payload.count >= 3 else { throw PacketDecodingError.malformedPayload(kind) }
            let keyCount = Int(payload[2])
            guard payload.count == 3 + keyCount * 2 else {
                throw PacketDecodingError.malformedPayload(kind)
            }
            let keys = (0..<keyCount).map { readUInt16(payload, at: 3 + $0 * 2) }
            body = .sync(SyncPacket(
                modifierMask: payload[0],
                buttonMask: payload[1],
                pressedKeys: keys
            ))

        case .text:
            guard payload.count <= maximumTextBytes,
                  let text = String(bytes: payload, encoding: .utf8) else {
                throw PacketDecodingError.malformedPayload(kind)
            }
            body = .text(text)
        }

        return DecodedPacket(sequence: sequence, body: body)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

private extension PacketKind {
    var logName: String {
        switch self {
        case .session: "session"
        case .key: "key"
        case .button: "button"
        case .pointer: "pointer"
        case .wheel: "wheel"
        case .sync: "sync"
        case .text: "text"
        }
    }
}
