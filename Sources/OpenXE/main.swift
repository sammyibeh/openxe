import AppKit
import OpenXECore

// OpenXE — faceless .exe handler. Spec §4.4:
// LSUIElement accessory app; activates only to show a window or alert;
// terminates once the Runner's launch watch completes without a crash.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
