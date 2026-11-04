import AppKit

@main struct InstallerApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = InstallerDelegate()
        app.delegate = delegate
        app.run()
    }
}
