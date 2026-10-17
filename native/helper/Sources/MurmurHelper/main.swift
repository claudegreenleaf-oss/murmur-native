import AppKit
import Foundation

signal(SIGPIPE, SIG_IGN)

let initialParent = getppid()
IPC.shared.handler = { name, value, reply in
    HelperApp.shared.handle(name, value, reply)
}
IPC.shared.startReading()
HelperApp.shared.boot()

// "Parent process died, terminating"
let parentWatch = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
parentWatch.schedule(deadline: .now() + 0.5, repeating: 0.5)
parentWatch.setEventHandler {
    if initialParent > 1 && getppid() != initialParent {
        hlog("Parent process died, terminating")
        exit(0)
    }
}
parentWatch.resume()

let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)
nsApp.run()
