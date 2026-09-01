import ApplicationServices
import Dispatch
import Foundation

do {
    let options = try CommandLineOptions(arguments: Array(CommandLine.arguments.dropFirst()))

    // Swift 6 treats the imported C global as mutable shared state. Its documented
    // dictionary key value is stable, so use the value directly.
    let accessibilityOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    guard AXIsProcessTrustedWithOptions(accessibilityOptions) else {
        fputs(
            "Accessibility permission is required. Grant it in System Settings > "
                + "Privacy & Security > Accessibility, then restart the receiver.\n",
            stderr
        )
        exit(EXIT_FAILURE)
    }

    let receiverState = ReceiverState(injector: InputInjector())
    let receiver = try UDPReceiver(listenPort: options.listenPort, state: receiverState)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signalSources = [SIGINT, SIGTERM].map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            receiver.stop()
            exit(EXIT_SUCCESS)
        }
        source.resume()
        return source
    }

    receiver.start(listenPort: options.listenPort)
    withExtendedLifetime(signalSources) {
        dispatchMain()
    }
} catch let error as CommandLineOptionsError {
    if case .helpRequested = error {
        print(CommandLineOptions.usage)
        exit(EXIT_SUCCESS)
    }
    fputs("\(error.description)\n", stderr)
    fputs("\(CommandLineOptions.usage)\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("Failed to start macOS receiver: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
