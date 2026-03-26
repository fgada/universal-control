import Dispatch
import Foundation

let receiver = HIDInputReceiver { event in
    print(event.logDescription)
}

print("Starting universal-control-minimal")
print("Grant System Settings > Privacy & Security > Input Monitoring if no events appear.")

receiver.run()
dispatchMain()
