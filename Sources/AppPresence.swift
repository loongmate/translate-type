import AppKit
import Carbon

@MainActor
final class AppPresence: NSObject, NSMenuItemValidation {
    func validateMenuItem(_ item:NSMenuItem) -> Bool { item.action != #selector(resumeEditor) || DraftEditor.shared.hasDraft }
    static let shared = AppPresence()
    private var started = false
    func start() {
        guard !started else { return }
        started = true
        // macOS owns the input-source icon. A second NSStatusItem looks like
        // another enabled input method and survives even when none is enabled.
        installApplicationMenu()
    }
    @objc private func resumeEditor() { DraftEditor.shared.show() }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc func openKeyboardSettings() {
        if let url = URL(string:"x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title:"方寸输入法")
        let settings = NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:",")
        settings.target = self; appMenu.addItem(settings)
        let editor = NSMenuItem(title:"继续临时编辑…",action:#selector(resumeEditor),keyEquivalent:""); editor.target = self; appMenu.addItem(editor)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title:"隐藏方寸输入法",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        hide.target = NSApp; appMenu.addItem(hide)
        appItem.submenu = appMenu; main.addItem(appItem)
        let windowItem = NSMenuItem(); let windows = NSMenu(title:"窗口")
        windows.addItem(NSMenuItem(title:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"))
        windows.addItem(NSMenuItem(title:"关闭窗口",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"))
        windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
}
