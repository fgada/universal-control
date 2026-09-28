import Darwin
import Foundation
import Network

/// WebSocket server that streams mic frames to Chrome extension receivers.
///
/// A client authenticates with a shared token, and is bound to the receiver slot
/// whose `--target-host` matches the client's source address. Audio frames are only
/// sent to clients bound to the slot that currently owns the mic.
final class AudioWebSocketServer: @unchecked Sendable {
    // Only accessed on `queue`.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        let address: String
        var slot: Int?
        var pendingSends = 0

        init(connection: NWConnection, address: String) {
            self.connection = connection
            self.address = address
        }
    }

    private static let frameMagic = Data("UCA1".utf8)
    private static let frameVersion: UInt8 = 1
    private static let codecPCM16Mono48k: UInt8 = 1
    private static let helloTimeout = DispatchTimeInterval.seconds(5)
    // Keeps the extension's service worker alive while the mic is off.
    private static let pingInterval = DispatchTimeInterval.seconds(15)
    // About 0.5 s of audio; beyond this, frames are dropped instead of queued.
    private static let maximumPendingSends = 25

    private let queue = DispatchQueue(label: "audio.websocket.server.queue", qos: .userInitiated)
    private let port: UInt16
    private let token: Data
    private let targetHosts: [String]
    private let listener: NWListener
    private let pingTimer: DispatchSourceTimer

    private var clients: [ObjectIdentifier: Client] = [:]
    private var micSlot: Int?
    private var frameSequence: UInt32 = 0

    init(port: UInt16, token: String, targetHosts: [String]) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CommandLineOptionsError.invalidPort(String(port))
        }

        self.port = port
        self.token = Data(token.utf8)
        self.targetHosts = targetHosts

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.setClientRequestHandler(queue) { _, headers in
            // Browsers always send Origin; only accept Chrome extensions so that
            // ordinary web pages on the receiver cannot open the stream.
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value ?? ""
            let status: NWProtocolWebSocket.Response.Status =
                origin.hasPrefix("chrome-extension://") ? .accept : .reject
            return NWProtocolWebSocket.Response(status: status, subprotocol: nil)
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        listener = try NWListener(using: parameters, on: nwPort)

        pingTimer = DispatchSource.makeTimerSource(queue: queue)
        pingTimer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
    }

    func start() {
        listener.stateUpdateHandler = { [port] state in
            switch state {
            case .ready:
                print("Mic WebSocket server listening on port \(port)")
            case let .failed(error):
                fputs("Mic WebSocket server failed on port \(port): \(error)\n", stderr)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        pingTimer.setEventHandler { [weak self] in
            self?.broadcastJSON(["type": "ping"]) { _ in true }
        }
        pingTimer.resume()
    }

    /// Routes subsequent audio frames to `slot`, or stops routing when `nil`.
    func setMicSlot(_ slot: Int?) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousSlot = self.micSlot
            self.micSlot = slot

            self.broadcastJSON(["type": "mic", "active": false]) { client in
                client.slot == previousSlot && previousSlot != slot
            }
            self.broadcastJSON(["type": "mic", "active": true]) { client in
                client.slot == slot && slot != nil
            }
        }
    }

    func sendAudioFrame(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, let micSlot = self.micSlot else { return }

            var frame = Self.frameMagic
            frame.append(Self.frameVersion)
            frame.append(Self.codecPCM16Mono48k)
            frame.append(contentsOf: [0, 0])
            withUnsafeBytes(of: self.frameSequence.littleEndian) { frame.append(contentsOf: $0) }
            frame.append(pcm)
            self.frameSequence &+= 1

            for client in self.clients.values where client.slot == micSlot {
                guard client.pendingSends < Self.maximumPendingSends else { continue }
                self.send(frame, opcode: .binary, to: client)
            }
        }
    }

    func clientCount(forSlot slot: Int) -> Int {
        queue.sync {
            clients.values.filter { $0.slot == slot }.count
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection, address: Self.normalizedAddress(of: connection.endpoint))
        let id = ObjectIdentifier(client)
        clients[id] = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(from: client)

        queue.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self, weak client] in
            guard let self, let client, client.slot == nil, self.clients[id] != nil else { return }
            self.close(client)
        }
    }

    private func receive(from client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            if error != nil {
                self.remove(client)
                return
            }

            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            guard let metadata else {
                self.remove(client)
                return
            }

            switch metadata.opcode {
            case .text:
                if let data {
                    self.handleText(data, from: client)
                }
            case .close:
                self.remove(client)
                return
            default:
                break
            }

            if self.clients[ObjectIdentifier(client)] != nil {
                self.receive(from: client)
            }
        }
    }

    private func handleText(_ data: Data, from client: Client) {
        guard client.slot == nil else { return }
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              message["type"] as? String == "hello" else {
            return
        }

        guard let token = message["token"] as? String, constantTimeEquals(Data(token.utf8), self.token) else {
            print("Mic client \(client.address) rejected: invalid token")
            send(json: ["type": "error", "reason": "auth"], to: client)
            close(client)
            return
        }

        guard let slot = slot(forAddress: client.address) else {
            print("Mic client \(client.address) rejected: no --target-host matches this address")
            send(json: ["type": "error", "reason": "unknown-host", "address": client.address], to: client)
            close(client)
            return
        }

        client.slot = slot
        print("Mic client connected: F\(13 + slot) <- \(client.address)")
        send(json: [
            "type": "welcome",
            "slot": slot + 1,
            "mic": micSlot == slot,
            "sampleRate": Int(MicCapture.sampleRate),
            "channels": 1,
            "frameSamples": MicCapture.frameSamples
        ], to: client)
    }

    private func slot(forAddress address: String) -> Int? {
        targetHosts.firstIndex { host in
            Self.resolve(host).contains(address)
        }
    }

    private func remove(_ client: Client) {
        let id = ObjectIdentifier(client)
        guard clients.removeValue(forKey: id) != nil else { return }
        if let slot = client.slot {
            print("Mic client disconnected: F\(13 + slot) <- \(client.address)")
        }
        client.connection.cancel()
    }

    private func close(_ client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        client.connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.remove(client)
        })
    }

    // MARK: - Sending

    private func broadcastJSON(_ object: [String: Any], where predicate: (Client) -> Bool) {
        for client in clients.values where client.slot != nil && predicate(client) {
            send(json: object, to: client)
        }
    }

    private func send(json object: [String: Any], to client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(data, opcode: .text, to: client)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, to client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        client.pendingSends += 1
        client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak client] _ in
            client?.pendingSends -= 1
        })
    }

    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Address matching

    private static func normalizedAddress(of endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case let .ipv4(address):
            return normalize("\(address)")
        case let .ipv6(address):
            return normalize("\(address)")
        case let .name(name, _):
            return normalize(name)
        @unknown default:
            return "\(host)"
        }
    }

    /// Canonical form used to compare a client address with resolved target hosts.
    private static func normalize(_ rawAddress: String) -> String {
        let address = rawAddress.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawAddress
        if let ipv4 = IPv4Address(address) {
            return "\(ipv4)"
        }
        if let ipv6 = IPv6Address(address) {
            if let mapped = ipv6.asIPv4 {
                return "\(mapped)"
            }
            return ipv6.rawValue.map { String(format: "%02x", $0) }.joined()
        }
        return address.lowercased()
    }

    private static func resolve(_ host: String) -> Set<String> {
        if IPv4Address(host) != nil || IPv6Address(host) != nil {
            return [normalize(host)]
        }

        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addresses = Set<String>()
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 {
                let address = String(
                    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                addresses.insert(normalize(address))
            }
        }
        return addresses
    }
}
