import Foundation

enum CommandLineOptionsError: Error, CustomStringConvertible {
    case missingValue(flag: String)
    case invalidPort(String)
    case unexpectedArgument(String)
    case helpRequested

    var description: String {
        switch self {
        case let .missingValue(flag):
            return "Missing value for \(flag)."
        case let .invalidPort(value):
            return "Invalid port: \(value)."
        case let .unexpectedArgument(argument):
            return "Unexpected argument: \(argument)"
        case .helpRequested:
            return CommandLineOptions.usage
        }
    }
}

struct CommandLineOptions {
    static let defaultListenPort: UInt16 = 50001
    static let usage = "Usage: universal-control-mac-receiver [--listen-port <port>]"

    let listenPort: UInt16

    init(arguments: [String]) throws {
        var listenPort = Self.defaultListenPort
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--listen-port":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw CommandLineOptionsError.missingValue(flag: "--listen-port")
                }
                guard let port = UInt16(value), port != 0 else {
                    throw CommandLineOptionsError.invalidPort(value)
                }
                listenPort = port

            case "--help", "-h":
                throw CommandLineOptionsError.helpRequested

            default:
                throw CommandLineOptionsError.unexpectedArgument(argument)
            }
        }

        self.listenPort = listenPort
    }
}
