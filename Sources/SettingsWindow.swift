import AppKit
@MainActor
final class SettingsWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow!
    private let endpoint = NSTextField()
    private let model = NSTextField()
    private let key = NSSecureTextField()
    private let instruction = NSTextView()
    private let status = NSTextField(wrappingLabelWithString:"")
    private let inputStatus = NSTextField(wrappingLabelWithString:"")
    private let addButton = NSButton()
    private let pinyinMode = NSPopUpButton()
    private let doublePinyin = NSPopUpButton()
    private let editorShortcut = ShortcutRecorder()
    private let pinyinExample = NSTextField(wrappingLabelWithString:"")
    private var isEnablingInput = false
    private var loadedEndpoint = ""
    private var testTask: Task<Void,Never>?
    private var testButton: NSButton!
    func show() {
        if window == nil {
            build()
            let config = ConfigurationStore.shared.model
            endpoint.stringValue = config.endpoint; model.stringValue = config.model; instruction.string = config.instruction
            loadedEndpoint = config.endpoint
            key.stringValue = (try? SecureKeyStore.read(endpoint:config.endpoint)) ?? ""
            status.stringValue = "留空使用默认指令。预设或修改指令不会调用模型。"
        }
        updatePinyinControls()
        updateInputStatus()
        editorShortcut.refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func windowWillClose(_ notification:Notification) { NSApp.setActivationPolicy(.accessory) }
    func windowDidBecomeKey(_ notification:Notification) { updateInputStatus(); updatePinyinControls() }
    @objc private func updatePinyinControls() {
        let store = ConfigurationStore.shared
        pinyinMode.selectItem(at:store.pinyinLayout == .fullPinyin ? 0 : 1)
        doublePinyin.isEnabled = store.pinyinLayout != .fullPinyin
        doublePinyin.selectItem(at:PinyinLayout.doublePinyin.firstIndex(of:store.lastDoublePinyinLayout) ?? 0)
        pinyinExample.stringValue = store.pinyinLayout == .fullPinyin
            ? "全拼输入：nihao → 你好"
            : "当前使用\(store.pinyinLayout.name)。每个音节按声母、韵母两个键输入，空格确认候选。"
    }
    @objc private func changePinyinMode() {
        ConfigurationStore.shared.pinyinLayout = pinyinMode.indexOfSelectedItem == 0 ? .fullPinyin : ConfigurationStore.shared.lastDoublePinyinLayout
        NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
    }
    @objc private func changeDoublePinyin() {
        guard PinyinLayout.doublePinyin.indices.contains(doublePinyin.indexOfSelectedItem) else { return }
        ConfigurationStore.shared.pinyinLayout = PinyinLayout.doublePinyin[doublePinyin.indexOfSelectedItem]
        NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
    }
    private func updateInputStatus() {
        guard !isEnablingInput else { return }
        let available = InputSourceStatus.isAvailable
        inputStatus.stringValue = available ? (InputSourceStatus.currentID == InputSourceStatus.modeID ? "正在使用方寸输入法。" : "方寸输入法已添加。在系统输入菜单中选择「方寸输入法」即可使用。") : "方寸输入法尚未添加。点击下方按钮添加到系统输入法。"
        addButton.title = available ? "已添加到系统输入法" : "添加到系统输入法"
        addButton.isEnabled = !available
    }
    @objc func enableInputSource() {
        guard !isEnablingInput else { return }
        isEnablingInput = true; addButton.isEnabled = false; inputStatus.stringValue = "正在添加方寸输入法…"
        do { try InputSourceStatus.enable() }
        catch { isEnablingInput = false; inputStatus.stringValue = error.localizedDescription; addButton.isEnabled = true; return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [weak self] in
            guard let self else { return }
            self.isEnablingInput = false
            self.updateInputStatus()
            if !InputSourceStatus.isAvailable { self.inputStatus.stringValue = "系统没有自动启用方寸输入法。请点「打开系统键盘设置」，在「编辑 → ＋」中选择方寸输入法并添加。" }
        }
    }
    @objc private func openKeyboardSettings() { AppPresence.shared.openKeyboardSettings() }
    func capture(to url:URL) throws {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let image = NSImage(data:view.dataWithPDF(inside:view.bounds)),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width*2),pixelsHigh:Int(view.bounds.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw AppError.message("无法生成设置预览。") }
        bitmap.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x:2,y:2)
        NSColor(calibratedWhite:0.96,alpha:1).setFill()
        view.bounds.fill()
        image.draw(in:view.bounds,from:.zero,operation:.sourceOver,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using:.png,properties:[:]) else { return }
        try data.write(to:url)
    }
    private func build() {
        window = EditingWindow(contentRect:NSRect(x:0,y:0,width:430,height:690),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "方寸输入法 · 设置"; window.isReleasedWhenClosed = false; window.center()
        window.delegate = self; window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.appearance = NSAppearance(named:.aqua)
        for field in [endpoint,model,key] {
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        let tabs = NSTabView(); tabs.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(tabs)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),tabs.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),tabs.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),tabs.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16)])
        func page(_ title:String) -> NSStackView {
            let item = NSTabViewItem(identifier:title); item.label = title
            let view = NSView(); item.view = view; tabs.addTabViewItem(item)
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-14),stack.topAnchor.constraint(equalTo:view.topAnchor,constant:18)])
            return stack
        }
        var root = page("输入")
        func label(_ text:String) -> NSTextField { let field = NSTextField(labelWithString:text); field.font = .systemFont(ofSize:12); field.textColor = .secondaryLabelColor; return field }
        func full(_ view:NSView) { root.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        func divider() -> NSBox { let view = NSBox(); view.boxType = .separator; return view }
        inputStatus.font = .systemFont(ofSize:11); inputStatus.textColor = .secondaryLabelColor; full(inputStatus)
        let sourceActions = NSStackView(); sourceActions.orientation = .horizontal; sourceActions.spacing = 8
        addButton.title = "添加到系统输入法"; addButton.target = self; addButton.action = #selector(enableInputSource); addButton.bezelStyle = .rounded; addButton.controlSize = .small
        let keyboard = NSButton(title:"打开系统键盘设置…",target:self,action:#selector(openKeyboardSettings)); keyboard.bezelStyle = .rounded; keyboard.controlSize = .small
        sourceActions.addArrangedSubview(addButton); sourceActions.addArrangedSubview(keyboard); root.addArrangedSubview(sourceActions)
        full(divider())
        full(label("拼音输入方式"))
        pinyinMode.addItems(withTitles:["全拼","双拼"]); pinyinMode.target = self; pinyinMode.action = #selector(changePinyinMode)
        pinyinMode.identifier = NSUserInterfaceItemIdentifier("pinyin-mode"); full(pinyinMode)
        full(label("双拼方案"))
        doublePinyin.addItems(withTitles:PinyinLayout.doublePinyin.map(\.name)); doublePinyin.target = self; doublePinyin.action = #selector(changeDoublePinyin)
        doublePinyin.identifier = NSUserInterfaceItemIdentifier("double-pinyin-layout"); full(doublePinyin)
        pinyinExample.font = .systemFont(ofSize:13); full(pinyinExample)
        full(label("选择后自动保存；正在输入的拼音选完后切换。"))
        full(divider())
        editorShortcut.configure(); full(editorShortcut)
        full(label("在方寸输入法中生效；编辑区 Enter 换行，Ctrl＋Enter 执行 AI 动作。"))
        let guide = NSTextField(wrappingLabelWithString:"空格确认候选，左右键移动候选高亮。\n- 上一页，= 或 + 下一页。\n回到首项后再按左键，可以编辑拼音。\n轻按 Shift 临时输入英文。\n\n开启「译英」后，先完成选词，再按 Ctrl＋Enter 翻译整段。打字和选词不调用模型。")
        guide.font = .systemFont(ofSize:12); guide.textColor = .secondaryLabelColor; full(guide)
        NotificationCenter.default.addObserver(self,selector:#selector(updatePinyinControls),name:.pinyinLayoutChanged,object:nil)
        root = page("AI")
        full(label("模型连接用于翻译、改文字和问 AI。"))
        full(label("服务地址")); endpoint.placeholderString = "https://api.example.com/v1"; endpoint.delegate = self; endpoint.bezelStyle = .roundedBezel; full(endpoint)
        full(label("模型名称")); model.placeholderString = "填写服务中的模型 ID"; model.bezelStyle = .roundedBezel; full(model)
        full(label("API Key（本地服务可留空）")); key.placeholderString = "密钥仅保存到 macOS 钥匙串"; key.bezelStyle = .roundedBezel; full(key)
        full(label("英语翻译偏好（选填）"))
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        instruction.frame = NSRect(x:0,y:0,width:346,height:100)
        instruction.isRichText = false; instruction.font = .systemFont(ofSize:12); instruction.textContainerInset = NSSize(width:7,height:7)
        instruction.isVerticallyResizable = true; instruction.isHorizontallyResizable = false; instruction.autoresizingMask = [.width]; instruction.textContainer?.widthTracksTextView = true
        scroll.documentView = instruction; scroll.heightAnchor.constraint(equalToConstant:100).isActive = true; full(scroll)
        let presets = NSStackView(); presets.orientation = .horizontal; presets.spacing = 6
        for (index,preset) in ModelConfiguration.presets.enumerated() { let button = NSButton(title:preset.0,target:self,action:#selector(applyPreset(_:))); button.tag = index; button.bezelStyle = .rounded; button.controlSize = .small; presets.addArrangedSubview(button) }
        full(presets)
        full(label("留空：按原意译成自然英文，只返回一条译文。"))
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; full(status)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 9
        testButton = NSButton(title:"测试翻译（调用 1 次）",target:self,action:#selector(testModel)); testButton.bezelStyle = .rounded
        let save = NSButton(title:"保存",target:self,action:#selector(save)); save.bezelStyle = .rounded
        actions.addArrangedSubview(testButton); actions.addArrangedSubview(save); full(actions)
        full(label("仅在主动执行动作或提问时发送文字到以上服务。"))
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === endpoint, endpoint.stringValue != loadedEndpoint { key.stringValue = "" }
    }
    @objc private func applyPreset(_ sender:NSButton) { instruction.string = ModelConfiguration.presets[sender.tag].1 }
    private func collect() throws -> ModelConfiguration {
        var config = ModelConfiguration(); config.endpoint = endpoint.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); config.model = model.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); config.instruction = instruction.string
        guard config.requestURL != nil else { throw AppError.message("地址无效。远程服务用 HTTPS，本机可用 http://localhost:11434/v1。") }
        guard !config.model.isEmpty else { throw AppError.message("请填写模型名称。") }
        return config
    }
    @objc private func save() {
        do { let config = try collect(); try SecureKeyStore.save(key.stringValue,endpoint:config.endpoint); ConfigurationStore.shared.model = config; loadedEndpoint = config.endpoint; NotificationCenter.default.post(name:.modelConfigurationChanged,object:nil); status.stringValue = "已保存。将在下一次主动执行时使用。" }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func testModel() {
        guard testTask == nil else { return }
        do {
            let config = try collect(), apiKey = key.stringValue
            testButton.isEnabled = false; status.stringValue = "正在测试翻译…"
            testTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.testTask = nil; self.testButton.isEnabled = true }
                do {
                    let started = Date()
                    let result = try await TranslationClient().translate("周末去海边走走吧",configuration:config,apiKey:apiKey)
                    self.status.stringValue = String(format:"耗时 %.1f 秒：",Date().timeIntervalSince(started)) + String(result.prefix(160))
                }
                catch { self.status.stringValue = error.localizedDescription }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}
extension Notification.Name {
    static let modelConfigurationChanged = Notification.Name("TranslateType.modelConfigurationChanged")
    static let pinyinLayoutChanged = Notification.Name("FangCun.pinyinLayoutChanged")
}
