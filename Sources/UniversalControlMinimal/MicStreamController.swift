import AVFoundation
import Foundation

/// Owns mic capture and routes it to one receiver slot at a time.
///
/// The mic stays bound to the slot that was selected when it was turned on, so
/// switching keyboard / mouse control to another receiver does not move the mic.
final class MicStreamController: @unchecked Sendable {
    private enum State {
        case off
        case starting
        case on(targetIndex: Int)
    }

    private let queue = DispatchQueue(label: "mic.stream.controller.queue", qos: .userInitiated)
    private let server: AudioWebSocketServer
    private var capture: MicCapture!
    private var state: State = .off

    init(server: AudioWebSocketServer, voiceProcessing: Bool) {
        self.server = server
        capture = MicCapture(queue: queue, voiceProcessing: voiceProcessing) { [server] frame in
            server.sendAudioFrame(frame)
        }
    }

    func toggle(targetIndex: Int, host: String) {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .starting:
                return
            case let .on(activeIndex):
                self.stop(targetIndex: activeIndex)
            case .off:
                self.state = .starting
                self.requestPermission { granted in
                    self.queue.async {
                        self.start(targetIndex: targetIndex, host: host, permissionGranted: granted)
                    }
                }
            }
        }
    }

    private func start(targetIndex: Int, host: String, permissionGranted: Bool) {
        guard permissionGranted else {
            state = .off
            fputs("F17: microphone access denied. Allow it in System Settings > Privacy & Security > Microphone.\n", stderr)
            return
        }

        do {
            try capture.start()
        } catch {
            state = .off
            fputs("F17: failed to start mic capture: \(error)\n", stderr)
            return
        }

        state = .on(targetIndex: targetIndex)
        server.setMicSlot(targetIndex)

        let clientCount = server.clientCount(forSlot: targetIndex)
        print("Mic streaming enabled: F\(13 + targetIndex) -> \(host) (\(clientCount) extension client(s) connected)")
        if clientCount == 0 {
            print("  Audio starts once the Chrome extension on \(host) connects.")
        }
    }

    private func stop(targetIndex: Int) {
        capture.stop()
        server.setMicSlot(nil)
        state = .off
        print("Mic streaming disabled for F\(13 + targetIndex)")
    }

    private func requestPermission(completion: @escaping @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default:
            completion(false)
        }
    }
}
