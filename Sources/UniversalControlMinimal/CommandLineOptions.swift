import Foundation

enum CommandLineOptionsError: Error, CustomStringConvertible {
    case missingTargetHost
    case missingValue(flag: String)
    case invalidPort(String)
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
        case let .unexpectedArgument(argument):
            return "Unexpected argument: \(argument)"
        case .helpRequested:
            return CommandLineOptions.usage
        }
    }
}

struct CommandLineOptions {
    static let usage = "Usage: universal-control-minimal --target-host <host> [--target-port <port>]"

    let targetHost: String
    let targetPort: UInt16

    init(arguments: [String]) throws {
        var targetHost: String?
        var targetPort: UInt16 = 50001

        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--target-host":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw CommandLineOptionsError.missingValue(flag: "--target-host")
                }
                targetHost = value

            case "--target-port":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw CommandLineOptionsError.missingValue(flag: "--target-port")
                }
                guard let port = UInt16(value) else {
                    throw CommandLineOptionsError.invalidPort(value)
                }
                targetPort = port

            case "--help", "-h":
                throw CommandLineOptionsError.helpRequested

            default:
                throw CommandLineOptionsError.unexpectedArgument(argument)
            }
        }

        guard let targetHost else {
            throw CommandLineOptionsError.missingTargetHost
        }

        self.targetHost = targetHost
        self.targetPort = targetPort
    }
}
