import Foundation
import Network

final class UDPReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mac.receiver.queue", qos: .userInteractive)
    private let state: ReceiverState
    private let listener: NWListener
    private let timer: DispatchSourceTimer
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var isStopped = false

    init(listenPort: UInt16, state: ReceiverState) throws {
        guard let port = NWEndpoint.Port(rawValue: listenPort) else {
            throw CommandLineOptionsError.invalidPort(String(listenPort))
        }

        self.state = state
        listener = try NWListener(using: .udp, on: port)
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start(listenPort: UInt16) {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] listenerState in
            switch listenerState {
            case .ready:
                LocalNetworkAddresses.printIPv4Addresses(listenPort: listenPort)
                print("Listening for remote input on UDP \(listenPort)")
            case let .failed(error):
                fputs("UDP listener failed: \(error)\n", stderr)
                self?.stopOnQueue()
                DispatchQueue.main.async {
                    exit(EXIT_FAILURE)
                }
            default:
                break
            }
        }

        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.state.checkTimers()
        }
        timer.resume()
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard !isStopped else { return }
        isStopped = true
        state.stop()
        timer.cancel()
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let self, let connection else { return }
            switch connectionState {
            case .failed, .cancelled:
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        receiveMessage(on: connection)
        connection.start(queue: queue)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                do {
                    let packet = try ProtocolDecoder.decode(data)
                    self.state.handle(packet.body)
                } catch let error as PacketDecodingError {
                    fputs("\(error.description)\n", stderr)
                } catch {
                    fputs("Ignoring packet: \(error)\n", stderr)
                }
            }

            if let error {
                fputs("UDP receive failed: \(error)\n", stderr)
                connection.cancel()
                return
            }

            if !self.isStopped {
                self.receiveMessage(on: connection)
            }
        }
    }
}
