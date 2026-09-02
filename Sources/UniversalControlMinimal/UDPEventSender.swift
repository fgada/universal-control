import Foundation
import Network

final class UDPEventSender: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connections: [(host: String, connection: NWConnection)]
    private var activeTargetIndex = 0

    init(hosts: [String], port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CommandLineOptionsError.invalidPort(String(port))
        }

        let senderQueue = DispatchQueue(label: "udp.event.sender.queue", qos: .userInteractive)
        queue = senderQueue
        connections = hosts.map { host in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("UDP sender ready: \(host):\(port)")
                case let .failed(error):
                    fputs("UDP sender failed for \(host):\(port): \(error)\n", stderr)
                default:
                    break
                }
            }
            connection.start(queue: senderQueue)
            return (host, connection)
        }
    }

    func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sendNow(payload, toTargetAt: self.activeTargetIndex)
        }
    }

    func send(_ payload: Data, toTargetAt index: Int) {
        guard connections.indices.contains(index) else { return }
        queue.async { [weak self] in
            self?.sendNow(payload, toTargetAt: index)
        }
    }

    func send(_ payload: Data, toTargetIndices indices: Set<Int>) {
        let validIndices = indices.filter { connections.indices.contains($0) }.sorted()
        guard !validIndices.isEmpty else { return }

        queue.async { [weak self] in
            guard let self else { return }
            for index in validIndices {
                self.sendNow(payload, toTargetAt: index)
            }
        }
    }

    func selectTarget(at index: Int) -> Bool {
        guard connections.indices.contains(index) else { return false }
        queue.async { [weak self] in
            self?.activeTargetIndex = index
        }
        return true
    }

    func targetHost(at index: Int) -> String? {
        guard connections.indices.contains(index) else { return nil }
        return connections[index].host
    }

    private func sendNow(_ payload: Data, toTargetAt index: Int) {
        let target = connections[index]
        target.connection.send(content: payload, completion: .contentProcessed { error in
            if let error {
                fputs("UDP send failed for \(target.host): \(error)\n", stderr)
            }
        })
    }
}
