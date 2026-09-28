@preconcurrency import AVFoundation
import Foundation

enum MicCaptureError: Error, CustomStringConvertible {
    case noInputDevice
    case unsupportedInputFormat(String)

    var description: String {
        switch self {
        case .noInputDevice:
            return "No audio input device is available."
        case let .unsupportedInputFormat(format):
            return "Unsupported audio input format: \(format)"
        }
    }
}

/// Captures the default input device and emits fixed-size PCM frames
/// (48 kHz, mono, signed 16-bit little-endian).
final class MicCapture: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let frameSamples = 960
    static let frameBytes = frameSamples * MemoryLayout<Int16>.size

    private let queue: DispatchQueue
    private let voiceProcessing: Bool
    private let frameSink: @Sendable (Data) -> Void
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: MicCapture.sampleRate,
        channels: 1,
        interleaved: true
    )!

    private var engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var running = false

    // Only touched from the tap callback while the tap is installed.
    private var converter: AVAudioConverter?
    private var pendingSamples = Data()

    /// `queue` must be the serial queue that calls `start()` and `stop()`.
    init(queue: DispatchQueue, voiceProcessing: Bool, frameSink: @escaping @Sendable (Data) -> Void) {
        self.queue = queue
        self.voiceProcessing = voiceProcessing
        self.frameSink = frameSink
    }

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicCaptureError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicCaptureError.unsupportedInputFormat("\(inputFormat)")
        }
        converter.downmix = true
        self.converter = converter
        pendingSamples.removeAll(keepingCapacity: true)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        running = true
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.restartAfterConfigurationChange()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    private func restartAfterConfigurationChange() {
        guard running else { return }
        print("Audio input configuration changed; restarting mic capture")

        stop()
        // A fresh engine picks up the new default input device and format.
        engine = AVAudioEngine()
        do {
            try start()
        } catch {
            fputs("Failed to restart mic capture: \(error)\n", stderr)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        // The input block runs synchronously inside convert(to:error:withInputFrom:).
        nonisolated(unsafe) var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error else {
            fputs("Mic conversion failed: \(conversionError.map { "\($0)" } ?? "unknown error")\n", stderr)
            return
        }
        guard converted.frameLength > 0, let samples = converted.int16ChannelData else { return }

        pendingSamples.append(UnsafeBufferPointer(start: samples[0], count: Int(converted.frameLength)))
        while pendingSamples.count >= Self.frameBytes {
            let frame = Data(pendingSamples.prefix(Self.frameBytes))
            pendingSamples.removeFirst(Self.frameBytes)
            frameSink(frame)
        }
    }
}
