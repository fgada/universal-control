import Foundation
import Network

final class UDPEventSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "udp.event.sender.queue", qos: .userInteractive)
    private let connection: NWConnection

    init(host: String, port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CommandLineOptionsError.invalidPort(String(port))
        }

        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("UDP sender ready")
            case let .failed(error):
                fputs("UDP sender failed: \(error)\n", stderr)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ payload: Data) {
        queue.async { [connection] in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    fputs("UDP send failed: \(error)\n", stderr)
                }
            })
        }
    }
}
