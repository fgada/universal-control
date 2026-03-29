import Dispatch
import Foundation

do {
    let options = try CommandLineOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    let keymap = try Keymap.loadDefault()
    let sender = try UDPEventSender(host: options.targetHost, port: options.targetPort)
    let remoteModeController = RemoteModeController(sender: sender, keymap: keymap)
    let eventTapController = EventTapController(remoteModeController: remoteModeController)

    guard eventTapController.start() else {
        fputs("Failed to create event tap. Grant Accessibility permission in System Settings > Privacy & Security > Accessibility.\n", stderr)
        exit(EXIT_FAILURE)
    }

    let receiver = HIDInputReceiver { event in
        remoteModeController.handle(event)
    }

    print("Starting universal-control-minimal")
    print("Sending input to \(options.targetHost):\(options.targetPort)")
    if let sourcePath = keymap.sourcePath {
        print("Loaded keymap from \(sourcePath)")
        for line in keymap.logLines() {
            print(line)
        }
    }
    print("Toggle remote mode with F19.")
    print("Toggle jitter mode with F18.")
    print("Grant Input Monitoring and Accessibility permissions if events are missing or suppression does not work.")

    receiver.run()
    dispatchMain()
} catch let error as CommandLineOptionsError {
    if case .helpRequested = error {
        print(CommandLineOptions.usage)
        exit(EXIT_SUCCESS)
    }

    fputs("\(error.description)\n", stderr)
    fputs("\(CommandLineOptions.usage)\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("Failed to start sender: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
