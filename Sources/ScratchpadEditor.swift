import AppKit
@preconcurrency import WebKit

@MainActor
final class ScratchpadEditor: NSObject, NSWindowDelegate, NSTextViewDelegate, DraftTextOwner, WKNavigationDelegate, WKUIDelegate {
    static let shared = ScratchpadEditor()
    private(set) var window: ScratchpadWindow!
    private(set) var session: CompositionSession?
    let textView = DraftTextView()
    private(set) var webView: WKWebView?
    private(set) var previewVisible = false
    private(set) var renderedPreview: ScratchpadPreview?
    private(set) var previewReady = false
    private(set) var format = ScratchpadFormat.automatic
    private(set) var filename: String?
    let history = UndoManager()
    private let store: ScratchpadStore
    private let renderer: ScratchpadRenderer
    private let candidates = CandidatePanel()
    private let formatPicker = NSPopUpButton()
    private let previewToggle = WorkspaceButton("预览",symbol:"sidebar.right",target:nil,action:nil,kind:.soft)
    private let language = WorkspaceButton("中 ⇧",target:nil,action:nil)
    private let status = NSTextField(labelWithString:"")
    private let fileLabel = WorkspaceStyle.label("未命名",size:12,color:WorkspaceStyle.ink)
    private let savedLabel = WorkspaceStyle.label("已自动保存",size:10)
    private var lineNumbers: WorkspaceLineNumbers?
    private var previewSurface: NSView?
    private var highlightedText: String?, highlightedFormat: ScratchpadFormat?
    private let previewLabel = NSTextField(labelWithString:"预览")
    private let previewBox = NSStackView()
    private let content = NSStackView()
    private var editorBox: NSView!
    private var rendering = false, restoring = false
    private var previousText = "", previousSelection = NSRange(location:0,length:0)
    private var shift = ShiftTap()
    private var previewTask: Task<Void,Never>?, saveTask: Task<Void,Never>?
    private var revision = UUID(), previewSignature: [String] = [], saveSignature: ScratchpadDraft?
    private var navigation: WKNavigation?
    private var scrollOffset = 0.0, resetScroll = true
    private var saveState = "已自动保存", message: String?
    private var layoutObserver: NSObjectProtocol?, terminationObserver: NSObjectProtocol?
    private static let accent = NSColor(calibratedRed:0.48,green:0.34,blue:0.77,alpha:1)
    init(store:ScratchpadStore = ScratchpadStore(),renderer:ScratchpadRenderer = ScratchpadRenderer()) {
        self.store = store; self.renderer = renderer; super.init()
    }
    func show() {
        do {
            if session == nil {
                let saved = store.load()
                let state = CompositionSession(engine:try PinyinEngine(layout:ConfigurationStore.shared.pinyinLayout),translateEnabled:false)
                state.beginEditor(); state.replaceEditorText(saved.text,selection:NSRange(location:saved.text.utf16.count,length:0))
                session = state; format = saved.format; filename = saved.filename; previewVisible = saved.preview
                previousText = saved.text; previousSelection = state.draftSelection; saveSignature = saved
                state.onUpdate = { [weak self] in self?.refresh() }
                build()
            }
            refresh(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(textView); refreshCandidates()
        } catch {
            let alert = NSAlert(); alert.messageText = "无法打开临时编辑器"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    func hide() { persist(immediately:true); candidates.orderOut(nil); shift.reset(); window?.orderOut(nil) }
    func windowShouldClose(_ sender:NSWindow) -> Bool { hide(); return false }
    func windowDidResignKey(_ notification:Notification) { shift.reset(); candidates.orderOut(nil) }
    func windowDidBecomeKey(_ notification:Notification) { refresh(); refreshCandidates() }
    func windowDidResize(_ notification:Notification) { refreshCandidates() }
    func editingSession(for view:DraftTextView) -> CompositionSession? { session }
    func informPending() { message = "请先完成选词，输入内容仍保留。"; updateStatus() }
    var draft: ScratchpadDraft {
        guard let state = session else { return ScratchpadDraft() }
        // Recover unconfirmed composition as the original raw input, never silently choose a candidate.
        let text = state.hasPendingInput ? (state.draft as NSString).replacingCharacters(in:state.draftSelection,with:state.snapshot.input) : state.draft
        return ScratchpadDraft(text:text,format:format,preview:previewVisible,filename:filename)
    }
    func refresh() {
        guard let state = session, window != nil else { return }
        rendering = true
        if previousText != state.draft {
            if !restoring {
                let text = previousText, selection = previousSelection
                history.registerUndo(withTarget:self) { target in MainActor.assumeIsolated { target.restoreText(text,selection:selection) } }
                history.setActionName("编辑文字")
            }
            previousText = state.draft
        }
        previousSelection = state.draftSelection
        if textView.string != state.markedText { textView.string = state.markedText }
        if highlightedText != textView.string || highlightedFormat != resolvedFormat {
            WorkspaceSyntax.apply(to:textView,format:resolvedFormat)
            highlightedText = textView.string; highlightedFormat = resolvedFormat
        }
        if state.hasPendingInput { textView.textStorage?.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:NSRange(location:state.pendingTextStart,length:state.snapshot.preedit.utf16.count)) }
        textView.setSelectedRange(state.hasPendingInput ? NSRange(location:state.markedCaret,length:0) : state.draftSelection)
        textView.scrollRangeToVisible(textView.selectedRange())
        language.title = (state.asciiMode ? "英文" : state.pinyinLayout.shortName) + " ⇧"
        if window.isKeyWindow { AppPresence.shared.updateInputLanguage(asciiMode:state.asciiMode) }
        previewBox.isHidden = !previewVisible
        previewSurface?.isHidden = !previewVisible
        previewToggle.title = "预览"
        previewToggle.toolTip = previewVisible ? "收起预览 · ⇧⌘P" : "展开预览 · ⇧⌘P"
        previewToggle.state = previewVisible ? .on : .off
        formatPicker.selectItem(at:ScratchpadFormat.allCases.firstIndex(of:format) ?? 0)
        window.title = "方寸 · 临时编辑器" + (filename.map { " · " + $0 } ?? "")
        fileLabel.stringValue = filename ?? "未命名"
        lineNumbers?.update(textView.string)
        rendering = false
        updateStatus(); schedulePreview(); persist(); refreshCandidates()
    }
    private func updateStatus() {
        guard let state = session else { return }
        let range = textView.selectedRange(), caret = min(range.location,(state.draft as NSString).length)
        let prefix = (state.draft as NSString).substring(to:caret)
        let line = prefix.reduce(1) { $1 == "\n" ? $0+1 : $0 }
        status.stringValue = message ?? (state.hasPendingInput ? "空格确认候选 · Esc 取消选词" : "\(state.draft.count) 字  /  第 \(line) 行" + (range.length > 0 ? " · 已选 \(range.length) 字" : ""))
        status.textColor = message == nil ? WorkspaceStyle.muted : .systemOrange
        savedLabel.stringValue = saveState
    }
    func textDidChange(_ notification:Notification) {
        guard !rendering, let state = session else { return }
        message = nil; state.replaceEditorText(textView.string,selection:textView.selectedRange())
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        guard !rendering, let state = session, !state.hasPendingInput else { return }
        state.setDraftSelection(textView.selectedRange()); previousSelection = state.draftSelection; updateStatus()
    }
    func textView(_ textView:NSTextView,shouldChangeTextIn range:NSRange,replacementString:String?) -> Bool {
        if session?.hasPendingInput == true { informPending(); return false }
        if let replacementString, NSMaxRange(range) <= textView.string.utf16.count,
           ((textView.string as NSString).replacingCharacters(in:range,with:replacementString)).utf8.count > 2_000_000 {
            message = "单份临时文字最多 2 MB，请分开编辑。"; updateStatus(); return false
        }
        return true
    }
    func textView(_ textView:NSTextView,willChangeSelectionFromCharacterRange old:NSRange,toCharacterRange new:NSRange) -> NSRange { session?.hasPendingInput == true && !rendering ? old : new }
    func flagsChanged(_ event:NSEvent) {
        if shift.flagsChanged(shift:event.modifierFlags.contains(.shift),otherModifier:!event.modifierFlags.intersection([.command,.control,.option,.capsLock]).isEmpty,keyCode:event.keyCode,timestamp:event.timestamp) { toggleLanguage() }
    }
    func handleKey(_ event:NSEvent,in view:DraftTextView) -> Bool {
        guard let state = session else { return false }; shift.keyDown(); message = nil
        let flags = event.modifierFlags.intersection([.control,.shift,.command,.option])
        if flags.isEmpty && event.keyCode == 53 { if state.hasPendingInput { state.discardPendingInput() } else { hide() }; return true }
        if !state.hasPendingInput { state.setDraftSelection(view.selectedRange()) }
        if !flags.intersection([.command,.control,.option]).isEmpty { return false }
        if !state.hasPendingInput && [51,117,123,124,125,126,115,119,116,121].contains(event.keyCode) { return false }
        if !state.hasPendingInput && event.keyCode == 48 { state.insertEditorText("\t"); return true }
        guard let key = InputKey.value(event) else { return false }
        if state.draft.utf8.count >= 2_000_000 && (32...126).contains(key) { message = "单份临时文字最多 2 MB。"; updateStatus(); return true }
        if state.handle(key:key,shift:flags.contains(.shift)) { return true }
        if !state.hasPendingInput, let chars = event.characters, !chars.isEmpty, chars.unicodeScalars.allSatisfy({$0.value >= 32 && $0.value < 0xf700}) { state.insertEditorText(chars); return true }
        return state.hasPendingInput
    }
    private func refreshCandidates() {
        guard window?.isVisible == true, window.isKeyWindow, window.firstResponder === textView, let state = session, state.hasPendingInput else { candidates.orderOut(nil); return }
        let rect = textView.firstRect(forCharacterRange:NSRange(location:state.markedCaret,length:0),actualRange:nil)
        candidates.show(session:state,anchor:rect,settings:{ SettingsWindow.shared.show() })
    }
    @objc private func toggleLanguage() { session?.setASCIIMode(!(session?.asciiMode ?? false)) }
    private func restoreText(_ text:String,selection:NSRange) {
        guard let state = session, !state.hasPendingInput else { informPending(); return }
        let inverse = state.draft, inverseSelection = state.draftSelection
        history.registerUndo(withTarget:self) { target in MainActor.assumeIsolated { target.restoreText(inverse,selection:inverseSelection) } }
        restoring = true; state.replaceEditorText(text,selection:selection); restoring = false
    }
    func replaceText(_ text:String,filename:String? = nil) {
        guard let state = session, !state.hasPendingInput else { informPending(); return }
        self.filename = filename; resetScroll = true; message = nil
        state.replaceEditorText(text,selection:NSRange(location:0,length:0))
    }
    @objc func clearText() { replaceText("") }
    @objc func copyText() {
        guard session?.hasPendingInput == false else { informPending(); return }
        let range = textView.selectedRange(), text = textView.string as NSString
        let value = range.length > 0 && NSMaxRange(range) <= text.length ? text.substring(with:range) : text as String
        guard !value.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
    }
    @objc func findText() { window.makeFirstResponder(textView); let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue); textView.performFindPanelAction(item) }
    @objc func openFile() {
        guard session?.hasPendingInput == false else { informPending(); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.prompt = "打开文本"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.loadFile(url) } catch { self.message = error.localizedDescription; self.updateStatus() }
        }
    }
    func loadFile(_ url:URL) throws {
        guard session?.hasPendingInput == false else { throw AgentFailure("请先完成选词。") }
        guard try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else { throw AgentFailure("请选择普通文本文件。") }
        let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
        let bytes = try file.read(upToCount:2_000_001) ?? Data()
        guard bytes.count <= 2_000_000, !bytes.contains(0), let text = String(data:bytes,encoding:.utf8) else { throw AgentFailure("请选择不超过 2 MB 的 UTF-8 文本文件。") }
        replaceText(text,filename:url.lastPathComponent)
    }
    @objc func saveFile() {
        guard session?.hasPendingInput == false else { informPending(); return }
        let panel = NSSavePanel(); panel.prompt = "保存文本"
        panel.nameFieldStringValue = filename ?? "临时文字." + (resolvedFormat == .markdown ? "md" : resolvedFormat == .html ? "html" : resolvedFormat == .json ? "json" : "txt")
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.export(to:url) } catch { self.message = error.localizedDescription; self.updateStatus() }
        }
    }
    func export(to url:URL) throws {
        guard let state = session, !state.hasPendingInput else { throw AgentFailure("请先完成选词。") }
        try state.draft.write(to:url,atomically:true,encoding:.utf8)
        filename = url.lastPathComponent; message = nil; refresh()
    }
    var resolvedFormat: ScratchpadFormat { format == .automatic ? ScratchpadFormat.detect(session?.draft ?? "",filename:filename) : format }
    @objc private func changeFormat() { setFormat(ScratchpadFormat.allCases[formatPicker.indexOfSelectedItem]) }
    func setFormat(_ value:ScratchpadFormat) { format = value; refresh() }
    @objc func togglePreview() { setPreviewVisible(!previewVisible) }
    func setPreviewVisible(_ visible:Bool) {
        guard window != nil, visible != previewVisible else { return }
        previewVisible = visible
        if visible {
            ensureWebView()
            if window.frame.width < 1050 {
                let screen = window.screen?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
                let width = min(1180,screen.width), x = min(window.frame.minX,screen.maxX-width)
                window.setFrame(NSRect(x:max(screen.minX,x),y:window.frame.minY,width:width,height:window.frame.height),display:true)
            }
        } else { previewTask?.cancel(); revision = UUID(); previewSignature = [] }
        refresh()
    }
    private func ensureWebView() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame:.zero,configuration:configuration); view.navigationDelegate = self; view.uiDelegate = self
        view.setAccessibilityLabel("临时编辑器右侧预览")
        webView = view; previewBox.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo:previewBox.widthAnchor).isActive = true
        view.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive = true
    }
    private func schedulePreview() {
        guard previewVisible, let state = session else { return }; ensureWebView()
        let dark = window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        let signature = [state.draft,format.rawValue,filename ?? "",String(dark)]
        guard signature != previewSignature else { return }; previewSignature = signature
        previewTask?.cancel(); revision = UUID(); let token = revision
        let text = state.draft, selected = format, name = filename
        previewReady = false; navigation = nil; previewLabel.stringValue = "预览 · " + resolvedFormat.title
        previewTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds:180_000_000)
                guard let self else { return }
                let snapshot = try await self.renderer.render(text,format:selected,filename:name,dark:dark)
                try Task.checkCancellation(); guard self.revision == token, self.previewVisible else { return }
                self.renderedPreview = snapshot
                self.previewLabel.stringValue = "预览 · " + snapshot.format.title + (snapshot.note.map { " · " + $0 } ?? "")
                let result = try? await self.webView?.evaluateJavaScript("window.scrollY")
                try Task.checkCancellation(); guard self.revision == token, self.previewVisible else { return }
                self.scrollOffset = self.resetScroll ? 0 : max(0,(result as? NSNumber)?.doubleValue ?? 0)
                self.resetScroll = false
                self.navigation = self.webView?.loadHTMLString(snapshot.html,baseURL:nil)
            } catch is CancellationError {} catch {
                guard let self, self.revision == token else { return }
                self.previewLabel.stringValue = error.localizedDescription
            }
        }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        guard navigation === self.navigation else { return }; previewReady = true
        webView.evaluateJavaScript("window.scrollTo(0,\(scrollOffset.isFinite ? scrollOffset : 0))",completionHandler:nil)
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
        if let url = action.request.url, url.absoluteString == "about:blank" || url.absoluteString.hasPrefix("about:blank#") { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, let url = action.request.url, ["http","https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures) -> WKWebView? { nil }
    private func persist(immediately:Bool = false) {
        guard session != nil else { return }
        let value = draft
        guard immediately || value != saveSignature else { return }; saveSignature = value
        saveTask?.cancel(); saveState = "正在自动保存…"; updateStatus()
        saveTask = Task { @MainActor [weak self] in
            if !immediately { do { try await Task.sleep(nanoseconds:350_000_000) } catch { return } }
            guard !Task.isCancelled, let self else { return }
            self.store.save(value) { [weak self] success in
                Task { @MainActor in
                    guard let self, self.saveSignature == value else { return }
                    self.saveState = success ? "已自动保存" : "自动保存失败，请另存文件"; self.updateStatus()
                }
            }
        }
    }
    @objc private func toggleAppearance() { WorkspaceStyle.toggleAppearance(for:window) }
    @objc private func appearanceChanged() {
        window.appearance = WorkspaceStyle.appearance
        highlightedText = nil; previewSignature = []
        refresh()
    }
    @objc private func zoomWindow() { window.zoom(nil) }
    private func build() {
        window = ScratchpadWindow(contentRect:NSRect(x:0,y:0,width:1040,height:680),styleMask:[.titled,.closable,.resizable,.nonactivatingPanel],backing:.buffered,defer:false)
        window.owner = self; window.delegate = self; window.isReleasedWhenClosed = false; window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.level = .floating; window.becomesKeyOnlyIfNeeded = false; window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window.minSize = NSSize(width:720,height:460); window.appearance = WorkspaceStyle.appearance
        window.titlebarAppearsTransparent = true; window.backgroundColor = WorkspaceStyle.soft
        window.setFrameAutosaveName("FangCunScratchpad"); window.center()
        let backdrop = WorkspaceSurface()
        window.contentView = backdrop
        let root = WorkspaceStyle.column(); backdrop.addSubview(root); WorkspaceStyle.pin(root,to:backdrop)
        backdrop.onAppearanceChange = { [weak self] in
            guard let self, self.session != nil else { return }
            self.highlightedText = nil; self.previewSignature = []
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        NotificationCenter.default.addObserver(self,selector:#selector(appearanceChanged),name:WorkspaceStyle.themeChanged,object:nil)
        func button(_ title:String,_ symbol:String,_ action:Selector) -> WorkspaceButton { WorkspaceButton(title,symbol:symbol,target:self,action:action) }
        let toolbar = WorkspaceStyle.row(spacing:8); toolbar.heightAnchor.constraint(equalToConstant:50).isActive = true; toolbar.edgeInsets = NSEdgeInsets(top:10,left:20,bottom:10,right:18)
        let fileIcon = NSImageView(image:WorkspaceStyle.symbol("doc.text")!); fileIcon.contentTintColor = WorkspaceStyle.accent
        toolbar.addArrangedSubview(fileIcon); toolbar.addArrangedSubview(fileLabel)
        toolbar.addArrangedSubview(WorkspaceStyle.label("临时草稿",size:10,color:WorkspaceStyle.subtle)); toolbar.addArrangedSubview(WorkspaceStyle.spacer())
        toolbar.addArrangedSubview(savedLabel)
        let clear = button("","square.and.pencil",#selector(clearText)); clear.toolTip = "新建空白草稿"; clear.setAccessibilityLabel("新建空白草稿"); toolbar.addArrangedSubview(clear)
        toolbar.addArrangedSubview(button("打开","folder",#selector(openFile)))
        toolbar.addArrangedSubview(button("另存为","square.and.arrow.down",#selector(saveFile)))
        previewToggle.target = self; previewToggle.action = #selector(togglePreview); toolbar.addArrangedSubview(previewToggle)
        let theme = button("","moon",#selector(toggleAppearance)); theme.setAccessibilityLabel("切换浅色或深色外观"); theme.toolTip = "切换浅色或深色外观"; toolbar.addArrangedSubview(theme)
        let zoom = button("","arrow.up.left.and.arrow.down.right",#selector(zoomWindow)); zoom.setAccessibilityLabel("放大窗口"); toolbar.addArrangedSubview(zoom)
        WorkspaceStyle.fillWidth(toolbar,in:root)
        let divider = NSBox(); divider.boxType = .separator; WorkspaceStyle.fillWidth(divider,in:root)
        content.orientation = .horizontal; content.spacing = 1; content.distribution = .fillEqually; content.alignment = .top
        let sourceSurface = WorkspaceSurface(WorkspaceStyle.soft)
        let left = WorkspaceStyle.column(); sourceSurface.addSubview(left); WorkspaceStyle.pin(left,to:sourceSurface); editorBox = left
        let heading = WorkspaceStyle.row(); heading.heightAnchor.constraint(equalToConstant:46).isActive = true; heading.edgeInsets = NSEdgeInsets(top:8,left:20,bottom:8,right:16)
        heading.addArrangedSubview(WorkspaceStyle.label("编辑",size:11)); heading.addArrangedSubview(WorkspaceStyle.spacer())
        let find = button("","magnifyingglass",#selector(findText)); find.setAccessibilityLabel("查找文字"); find.toolTip = "查找 · ⌘F"; heading.addArrangedSubview(find)
        let copy = button("","doc.on.doc",#selector(copyText)); copy.setAccessibilityLabel("复制编辑内容"); heading.addArrangedSubview(copy)
        WorkspaceStyle.fillWidth(heading,in:left)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.drawsBackground = true; scroll.backgroundColor = WorkspaceStyle.soft
        textView.owner = self; textView.delegate = self; textView.isRichText = false; textView.allowsUndo = false; textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize:14,weight:.regular); textView.textContainerInset = NSSize(width:12,height:8)
        textView.backgroundColor = WorkspaceStyle.soft; textView.textColor = WorkspaceStyle.ink; textView.insertionPointColor = WorkspaceStyle.accent
        textView.selectedTextAttributes = [.backgroundColor:WorkspaceStyle.tint,.foregroundColor:WorkspaceStyle.ink]
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false; textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false; textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude); textView.setAccessibilityLabel("临时编辑器文本")
        scroll.documentView = textView
        let ruler = WorkspaceLineNumbers(scrollView:scroll,textView:textView); lineNumbers = ruler
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        WorkspaceStyle.fillWidth(scroll,in:left); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        let previewBackground = WorkspaceSurface(); previewSurface = previewBackground
        previewBox.orientation = .vertical; previewBox.alignment = .leading; previewBox.spacing = 0
        previewBackground.addSubview(previewBox); WorkspaceStyle.pin(previewBox,to:previewBackground)
        let previewHeading = WorkspaceStyle.row(); previewHeading.heightAnchor.constraint(equalToConstant:46).isActive = true; previewHeading.edgeInsets = NSEdgeInsets(top:15,left:24,bottom:15,right:22)
        previewLabel.font = .systemFont(ofSize:11); previewLabel.textColor = WorkspaceStyle.muted
        previewHeading.addArrangedSubview(previewLabel); previewHeading.addArrangedSubview(WorkspaceStyle.label("实时更新",size:10,color:WorkspaceStyle.subtle)); previewHeading.addArrangedSubview(WorkspaceStyle.spacer())
        let book = NSImageView(image:WorkspaceStyle.symbol("book")!); book.contentTintColor = WorkspaceStyle.subtle; previewHeading.addArrangedSubview(book)
        WorkspaceStyle.fillWidth(previewHeading,in:previewBox)
        content.addArrangedSubview(sourceSurface); content.addArrangedSubview(previewBackground); WorkspaceStyle.fillWidth(content,in:root)
        sourceSurface.heightAnchor.constraint(equalTo:content.heightAnchor).isActive = true; previewBackground.heightAnchor.constraint(equalTo:content.heightAnchor).isActive = true
        let bottomLine = NSBox(); bottomLine.boxType = .separator; WorkspaceStyle.fillWidth(bottomLine,in:root)
        let bottom = WorkspaceStyle.row(spacing:8); bottom.heightAnchor.constraint(equalToConstant:38).isActive = true; bottom.edgeInsets = NSEdgeInsets(top:4,left:18,bottom:4,right:16)
        status.font = .systemFont(ofSize:10); status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        bottom.addArrangedSubview(status); bottom.addArrangedSubview(WorkspaceStyle.spacer())
        formatPicker.addItems(withTitles:ScratchpadFormat.allCases.map(\.title)); formatPicker.target = self; formatPicker.action = #selector(changeFormat)
        formatPicker.isBordered = false; formatPicker.font = .systemFont(ofSize:10); formatPicker.setAccessibilityLabel("文档格式"); bottom.addArrangedSubview(formatPicker)
        bottom.addArrangedSubview(WorkspaceStyle.label("/  UTF-8  /",size:10,color:WorkspaceStyle.subtle))
        language.target = self; language.action = #selector(toggleLanguage); language.toolTip = "Shift 切换中英文"; bottom.addArrangedSubview(language)
        WorkspaceStyle.fillWidth(bottom,in:root)
        history.levelsOfUndo = 100
        layoutObserver = NotificationCenter.default.addObserver(forName:.pinyinLayoutChanged,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { do { try self?.session?.requestPinyinLayout(ConfigurationStore.shared.pinyinLayout) } catch { self?.message = error.localizedDescription; self?.updateStatus() } }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.saveTask?.cancel(); self.store.save(self.draft) { _ in }; self.store.flush() }
        }
    }
}

@MainActor
final class ScratchpadWindow: NSPanel {
    weak var owner: ScratchpadEditor?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.control,.shift,.option]), key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command] {
            switch key {
            case "w": owner?.hide(); return true
            case "s": owner?.saveFile(); return true
            case "o": owner?.openFile(); return true
            case "f": owner?.findText(); return true
            default:break
            }
        }
        if key == "p", flags == [.command,.shift] { owner?.togglePreview(); return true }
        if key == "z", flags == [.command] || flags == [.command,.shift] {
            guard owner?.session?.hasPendingInput == false else { owner?.informPending(); return true }
            if flags.contains(.shift) { owner?.history.redo() } else { owner?.history.undo() }; return true
        }
        if flags == [.command], let key, let action = ["v":#selector(NSText.paste(_:)),"c":#selector(NSText.copy(_:)),"x":#selector(NSText.cut(_:)),"a":#selector(NSText.selectAll(_:))][key], NSApp.sendAction(action,to:firstResponder,from:self) { return true }
        return super.performKeyEquivalent(with:event)
    }
}
