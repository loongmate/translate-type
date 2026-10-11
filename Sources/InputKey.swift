import AppKit

enum InputKey {
    static func value(_ event:NSEvent) -> Int? {
        switch event.keyCode {
        case 36,76:return 0xff0d
        case 51:return 0xff08
        case 53:return 0xff1b
        case 123:return 0xff51
        case 124:return 0xff53
        case 125:return 0xff54
        case 126:return 0xff52
        case 116:return 0xff55
        case 121:return 0xff56
        case 117:return 0xffff
        case 48:return 0xff09
        default:
            let chars = event.modifierFlags.intersection([.command,.control,.option]).isEmpty ? event.characters : event.charactersIgnoringModifiers
            return chars?.unicodeScalars.first.map { Int($0.value) }
        }
    }
}
extension EditorShortcut {
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue:modifiers) }
    var displayName: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + ([36,76].contains(keyCode) ? "↵" : key.uppercased())
    }
    func matches(_ event:NSEvent) -> Bool {
        let codeMatches = keyCode == event.keyCode || ([36,76].contains(keyCode) && [36,76].contains(event.keyCode))
        return codeMatches && flags == event.modifierFlags.intersection([.command,.control,.option,.shift])
    }
    static func recording(_ event:NSEvent) -> EditorShortcut? {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        let modifiers = [NSEvent.ModifierFlags.control,.option,.shift,.command].filter { flags.contains($0) }.count
        let value = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard modifiers >= 2, !flags.intersection([.control,.command,.option]).isEmpty,
              [36,76].contains(event.keyCode) || (value.count == 1 && value.rangeOfCharacter(from:.alphanumerics) != nil),
              !(flags == [.control,.shift] && value == "e"),
              ![NSEvent.ModifierFlags([.command,.shift]),NSEvent.ModifierFlags([.control,.command])].contains(flags) else { return nil }
        return EditorShortcut(keyCode:event.keyCode,modifiers:flags.rawValue,key:value)
    }
}
@MainActor
final class ShortcutRecorder: NSButton {
    private var recording = false
    override var acceptsFirstResponder: Bool { true }
    func configure() { target = self; action = #selector(beginRecording); bezelStyle = .rounded; refresh() }
    func refresh() { title = "临时编辑区：\(ConfigurationStore.shared.editorShortcut.displayName)  ·  点击修改" }
    @objc private func beginRecording() { recording = true; title = "按组合键（至少两个修饰键），Esc 取消"; window?.makeFirstResponder(self) }
    override func keyDown(with event:NSEvent) {
        guard recording else { super.keyDown(with:event); return }
        if event.keyCode == 53 { recording = false; refresh(); return }
        if let shortcut = EditorShortcut.recording(event) {
            ConfigurationStore.shared.editorShortcut = shortcut; recording = false; refresh()
        } else { title = "此组合不可用；请用 Ctrl/Option 等组合，Esc 取消" }
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with:event) }
        keyDown(with:event); return true
    }
    override func resignFirstResponder() -> Bool { recording = false; refresh(); return super.resignFirstResponder() }
}
