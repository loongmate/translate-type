import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = appDelegate
app.run()
