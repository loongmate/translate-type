import AppKit

@MainActor
final class AIActionWindow: NSObject {
    private let window: ActionEditingPanel
    private let name = NSTextField()
    private let key = NSTextField()
    private let prompt = NSTextView()
    private let error = NSTextField(wrappingLabelWithString:"")
    private var action: AIAction
    private let completion: (AIAction?)->Void
    private weak var parent: NSWindow?
    init(action original:AIAction?,completion:@escaping (AIAction?)->Void) {
        action = original ?? AIAction(name:"",key:"",prompt:"")
        if action.isBuiltIn {
            action.id = UUID().uuidString; action.name += " · 我的"; action.key = ""
            // Include saved English preferences in the editable copy.
            if original?.id == "english" { action.prompt = ConfigurationStore.shared.model.effectiveInstruction }
        }
        self.completion = completion
        window = ActionEditingPanel(contentRect:NSRect(x:0,y:0,width:550,height:560),styleMask:[.titled],backing:.buffered,defer:false)
        super.init()
        window.title = original?.isBuiltIn == true ? "另存为我的动作" : original == nil ? "自定义动作" : "编辑动作"
        window.isReleasedWhenClosed = false
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:22),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-22),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:22),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-22)])
        func full(_ view:NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:18,weight:.semibold); full(title)
        name.stringValue = action.name; name.placeholderString = "动作名称，例如：提取订单信息"; name.setAccessibilityLabel("动作名称"); full(name)
        key.stringValue = action.key; key.placeholderString = "可选 key，例如 order（不含 /）"; key.setAccessibilityLabel("动作 key"); full(key)
        full(NSTextField(labelWithString:"特殊指令"))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        prompt.string = action.prompt; prompt.isRichText = false; prompt.font = .systemFont(ofSize:14); prompt.textContainerInset = NSSize(width:10,height:10)
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false; prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true; prompt.allowsUndo = true; prompt.setAccessibilityLabel("特殊指令")
        scroll.documentView = prompt; full(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        let help = NSTextField(wrappingLabelWithString:"原文会自动附在指令之后。留空则按原文中的明确要求处理，没有要求则保留原文。/key 用于动作菜单，不截获日常输入。保存不会调用模型。")
        help.font = .systemFont(ofSize:11); help.textColor = .secondaryLabelColor; full(help)
        error.font = .systemFont(ofSize:11); error.textColor = .systemOrange; full(error)
        let buttons = NSStackView(); buttons.spacing = 10
        func button(_ title:String,_ selector:Selector)->NSButton { let b = NSButton(title:title,target:self,action:selector); b.bezelStyle = .rounded; return b }
        if let original, !original.isBuiltIn { buttons.addArrangedSubview(button("删除动作",#selector(remove))) }
        let space = NSView(); space.setContentHuggingPriority(.defaultLow,for:.horizontal); buttons.addArrangedSubview(space)
        let cancel = button("取消",#selector(cancel)); cancel.keyEquivalent = "\u{1b}"; buttons.addArrangedSubview(cancel)
        let save = button("保存动作",#selector(save)); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; buttons.addArrangedSubview(save); full(buttons)
    }
    func show(parent:NSWindow) { self.parent = parent; parent.beginSheet(window); window.makeFirstResponder(name) }
    private func close() { parent?.endSheet(window); window.orderOut(nil) }
    @objc private func cancel() { close() }
    @objc private func save() {
        // Don't save a half-composed name or prompt.
        if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { error.stringValue = "请先完成选词，再保存。"; return }
        action.name = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        action.key = key.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        action.prompt = prompt.string
        do { try ConfigurationStore.shared.saveAction(action); close(); completion(action) }
        catch { self.error.stringValue = error.localizedDescription }
    }
    @objc private func remove() {
        ConfigurationStore.shared.customActions.removeAll { $0.id == action.id }
        close(); completion(nil)
    }
}

// A sheet of a nonactivating editor must itself be a panel; NSWindow cannot
// inherit the parent's nonactivating style. Keep standard field shortcuts.
private final class ActionEditingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.control,.shift,.option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "z", let undo = firstResponder?.undoManager {
            if flags == [.command] { undo.undo(); return true }
            if flags == [.command,.shift] { undo.redo(); return true }
        }
        if flags == [.command], let action = ["v":#selector(NSText.paste(_:)),"c":#selector(NSText.copy(_:)),"x":#selector(NSText.cut(_:)),"a":#selector(NSText.selectAll(_:))][key], NSApp.sendAction(action,to:firstResponder,from:self) { return true }
        return super.performKeyEquivalent(with:event)
    }
}
