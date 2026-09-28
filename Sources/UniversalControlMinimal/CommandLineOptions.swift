import Foundation

enum CommandLineOptionsError: Error, CustomStringConvertible {
    case missingTargetHost
    case missingValue(flag: String)
    case invalidPort(String)
    case tooManyTargetHosts
    case emptyAudioToken
    case unexpectedArgument(String)
    case helpRequested

    var description: String {
        switch self {
        case .missingTargetHost:
            return "--target-host is required."
        case let .missingValue(flag):
            return "Missing value for \(flag)."
        case let .invalidPort(rawValue):
            return "Invalid port: \(rawValue)."
        case .tooManyTargetHosts:
            return "At most three --target-host values can be specified."
        case .emptyAudioToken:
            return "--audio-token must not be empty."
        case let .unexpectedArgument(argument):
            return "Unexpected argument: \(argument)"
        case .helpRequested:
            return CommandLineOptions.usage
        }
    }
}

struct CommandLineOptions {
    static let usage = """
        Usage: universal-control-minimal --target-host <host> [--target-host <host> ...] [--target-port <port>]
                                         [--audio-token <token> [--audio-port <port>] [--audio-voice-processing]]
        """

    let targetHosts: [String]
    let targetPort: UInt16
    let audioToken: String?
    let audioPort: UInt16
    let audioVoiceProcessing: Bool

    init(arguments: [String]) throws {
        var targetHosts: [String] = []
        var targetPort: UInt16 = 50001
        var audioToken: String?
        var audioPort: UInt16 = 50002
        var audioVoiceProcessing = false

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--target-host":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw CommandLineOptionsError.missingValue(flag: "--target-host")
                }
                if !targetHosts.contains(value) {
                    targetHosts.append(value)
                    if targetHosts.count > 3 {
                        throw CommandLineOptionsError.tooManyTargetHosts
                    }
                }

            case "--target-port":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw CommandLineOptionsError.missingValue(flag: "--target-port")
                }
                guard let port = UInt16(value) else {
                    throw CommandLineOptionsError.invalidPort(value)
                }
                targetPort = port

            case "--audio-token":
                guard let value = iterator.next() else {
                    throw CommandLineOptionsError.missingValue(flag: "--audio-token")
                }
                guard !value.isEmpty else {
                    throw CommandLineOptionsError.emptyAudioToken
                }
                audioToken = value

            case "--audio-port":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw CommandLineOptionsError.missingValue(flag: "--audio-port")
                }
                guard let port = UInt16(value) else {
                    throw CommandLineOptionsError.invalidPort(value)
                }
                audioPort = port

            case "--audio-voice-processing":
                audioVoiceProcessing = true

            case "--help", "-h":
                throw CommandLineOptionsError.helpRequested

            default:
                throw CommandLineOptionsError.unexpectedArgument(argument)
            }
        }

        guard !targetHosts.isEmpty else {
            throw CommandLineOptionsError.missingTargetHost
        }

        self.targetHosts = targetHosts
        self.targetPort = targetPort
        self.audioToken = audioToken
        self.audioPort = audioPort
        self.audioVoiceProcessing = audioVoiceProcessing
    }
}
