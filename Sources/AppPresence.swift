import AppKit
import Carbon

@MainActor
final class AppPresence: NSObject, NSMenuItemValidation {
    func validateMenuItem(_ item:NSMenuItem) -> Bool { item.action != #selector(resumeEditor) || DraftEditor.shared.hasDraft }
    static let shared = AppPresence()
    private var started = false
    private var languageIndicator: InputLanguageIndicator?
    private var asciiMode = false
    private weak var inputController: TTInputController?
    func start() {
        guard !started else { return }
        started = true
        languageIndicator = InputLanguageIndicator(onAskAI:{ [weak self] in self?.askAI() },onScratchpad:{ ScratchpadEditor.shared.show() })
        if let menu = languageIndicator?.item.menu {
            menu.addItem(.separator())
            let settings = NSMenuItem(title:"设置…",action:#selector(openSettings),keyEquivalent:"")
            settings.target = self; menu.addItem(settings)
            let editor = NSMenuItem(title:"继续临时编辑…",action:#selector(resumeEditor),keyEquivalent:"")
            editor.target = self; menu.addItem(editor)
        }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(inputSourceChanged),name:Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),object:nil)
        inputSourceChanged()
        installApplicationMenu()
    }
    func updateInputLanguage(asciiMode:Bool,controller:TTInputController? = nil) {
        if let controller { inputController = controller }
        self.asciiMode = asciiMode
        languageIndicator?.update(asciiMode:asciiMode,isSelected:InputSourceStatus.isOurMode(InputSourceStatus.currentID))
    }
    @objc private func inputSourceChanged() {
        let selected = InputSourceStatus.isOurMode(InputSourceStatus.currentID)
        if !selected { asciiMode = false; inputController = nil }
        languageIndicator?.update(asciiMode:asciiMode,isSelected:selected)
    }
    private func askAI() {
        if !DraftEditor.shared.hasDraft, inputController?.openAIQuestionFromStatus() == true { return }
        DraftEditor.shared.openQuestionFromMenu()
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
        let scratchpad = NSMenuItem(title:"临时编辑器…",action:#selector(openScratchpad),keyEquivalent:"")
        scratchpad.target = self; appMenu.addItem(scratchpad)
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
    @objc private func openScratchpad() { ScratchpadEditor.shared.show() }
}
