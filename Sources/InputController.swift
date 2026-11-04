import AppKit
import InputMethodKit
import Carbon
@MainActor
@objc(TTInputController)
final class TTInputController: IMKInputController {
    private var session: CompositionSession?
    private let panel = CandidatePanel()
    private var activeClient: (any IMKTextInput)?
    private var isActive = false
    private var shiftTap = ShiftTap()
    private let inputSessionID = UUID()
    private var observingChanges = false
    private let inputContext = ContinuousInputContext()
    private var diagnosticEvents = 0
    private func diagnose(_ event:String,client:(any IMKTextInput)?,fields:[String:Any] = [:]) {
        guard UserDefaults(suiteName:"com.fangcun.inputmethod.FangCun")?.bool(forKey:"inputDiagnosticsEnabled") == true else { return }
        var details = fields
        details["session"] = inputSessionID.uuidString
        details["bundle"] = client?.bundleIdentifier() ?? ""
        details["active"] = isActive
        details["ascii"] = session?.asciiMode ?? false
        details["pending"] = session?.hasPendingInput ?? false
        details["source"] = InputSourceStatus.currentID
        EditorDiagnostics.record("ime-"+event,details)
    }
    var contextStatus: (active:Bool,dirty:Bool,reason:String) {
        (session?.contextActive ?? false,inputContext.dirty,inputContext.reason)
    }
    private func bind(_ state:CompositionSession) {
        state.onInsert = { [weak self] text in
            self?.inputContext.willInsert(text)
            self?.activeClient?.insertText(text,replacementRange:NSRange(location:NSNotFound,length:0))
        }
        state.onConfirmedDraft = { [weak self] text in self?.inputContext.confirmedDraft(text) }
        state.onContextInvalidated = { [weak self] reason in self?.inputContext.invalidate(reason) }
        state.onUpdate = { [weak self] in self?.refresh() }
    }
    private func newSession() throws -> CompositionSession {
        let internalField = activeClient.map { DraftEditor.isInternalClient($0) } ?? false
        let state = CompositionSession(engine:try PinyinEngine(layout:ConfigurationStore.shared.pinyinLayout),translateEnabled:internalField ? false : ConfigurationStore.shared.translateEnabled)
        bind(state)
        return state
    }
    private var editorResumeAction: DraftEditor.ResumeAction {
        { [weak self] state,client in
            guard let self else { return false }
            if Bundle.main.bundleIdentifier == InputSourceStatus.bundleID && !InputSourceStatus.isOurMode(InputSourceStatus.currentID) { return false }
            self.session = state; self.activeClient = client; self.isActive = true
            self.bind(state)
            state.endEditor(); state.refreshCandidateAction(); self.refresh(); return true
        }
    }
    private func observeHost(_ client:any IMKTextInput) {
        DraftEditor.shared.hostActivated(client,sessionID:inputSessionID,resume:editorResumeAction)
    }
    @objc func openEditor() {
        session?.invalidateContext("editor")
        guard let client = activeClient, !DraftEditor.isInternalClient(client) else { return }
        observeHost(client)
        if DraftEditor.shared.hasDraft { DraftEditor.shared.show(); return }
        detachEditor(present:true)
    }
    @objc func openAIQuestion() {
        guard let client = activeClient, !DraftEditor.isInternalClient(client) else { return }
        openEditor(); DraftEditor.shared.openQuestion()
    }
    func openAIQuestionFromStatus() -> Bool {
        guard let client = activeClient, !DraftEditor.isInternalClient(client) else { return false }
        openAIQuestion()
        return DraftEditor.shared.hasDraft
    }
    private func preserveEditorDraft() {
        if let session, session.retainsDraft, !session.isInEditor, !session.markedText.isEmpty, !DraftEditor.shared.hasDraft { detachEditor(present:false) }
    }
    private func detachEditor(present:Bool) {
        guard let session, let client = activeClient else { return }
        panel.orderOut(nil)
        DraftEditor.shared.open(session:session,client:client,sessionID:inputSessionID,present:present,resume:editorResumeAction)
        // The editor now owns this composition. Rebinding/collapsing into a
        // different controller must not leave the old controller sharing it.
        if self.session === session { self.session = nil }
    }
    nonisolated override func activateServer(_ sender: Any!) {
        MainActor.assumeIsolated { activate(sender) }
    }
    private func activate(_ sender: Any!) {
        diagnosticEvents = 0
        diagnose("activate",client:sender as? any IMKTextInput,fields:["clientAvailable":sender is any IMKTextInput])
        guard let client = sender as? any IMKTextInput else { NSLog("方寸输入法：系统未提供文本客户端"); return }
        inputContext.reset(); session?.setContext(nil)
        observeHost(client)
        activeClient = client; isActive = true; shiftTap.reset()
        if session == nil {
            do {
                session = try newSession()
            } catch { NSLog("方寸输入法：拼音初始化失败"); return }
        }
        if !observingChanges {
            observingChanges = true
#if CONTEXT_PROBE
            if ContextProbe.reportURL != nil {
                DistributedNotificationCenter.default().addObserver(self,selector:#selector(sampleContext(_:)),name:ContextProbe.notification,object:nil)
            }
#endif
            NotificationCenter.default.addObserver(self,selector:#selector(configurationChanged),name:.modelConfigurationChanged,object:nil)
            NotificationCenter.default.addObserver(self,selector:#selector(candidateActionChanged),name:.candidateActionChanged,object:ConfigurationStore.shared)
            NotificationCenter.default.addObserver(self,selector:#selector(candidateActionChanged),name:.aiActionsChanged,object:ConfigurationStore.shared)
            NotificationCenter.default.addObserver(self,selector:#selector(pinyinLayoutChanged),name:.pinyinLayoutChanged,object:nil)
            NotificationCenter.default.addObserver(self,selector:#selector(contextSettingChanged),name:.contextAwarenessChanged,object:nil)
            DistributedNotificationCenter.default().addObserver(self,selector:#selector(inputSourceChanged),name:Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),object:nil)
        }
        pinyinLayoutChanged(); candidateActionChanged()
        refresh()
        diagnose("activated",client:client)
    }
    nonisolated override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated { session?.invalidateContext("focus-lost",preserveHighlight:true); shiftTap.reset(); preserveEditorDraft(); session?.flushOriginal(); panel.orderOut(nil); isActive = false; activeClient = nil }
    }
    nonisolated override func commitComposition(_ sender: Any!) { MainActor.assumeIsolated { session?.invalidateContext("host-commit",preserveHighlight:true); preserveEditorDraft(); session?.flushOriginal() } }
    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown,.flagsChanged,.leftMouseDown,.rightMouseDown,.otherMouseDown]).rawValue)
    }
    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        MainActor.assumeIsolated { process(event, client: sender) }
    }
    private func process(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        if diagnosticEvents < 21 { diagnosticEvents += 1 }
        if diagnosticEvents <= 20 {
            var fields:[String:Any] = ["type":event.type.rawValue,"clientAvailable":sender is any IMKTextInput]
            if event.type == .keyDown {
                fields["charactersEmpty"] = event.characters?.isEmpty ?? true
                fields["unmodifiedEmpty"] = event.charactersIgnoringModifiers?.isEmpty ?? true
            }
            diagnose("event",client:sender as? any IMKTextInput,fields:fields)
        }
        if event.type == .keyDown, !ConfigurationStore.shared.editorShortcut.matches(event), let client = sender as? any IMKTextInput {
            DraftEditor.shared.hostWillProcessInput(client,sessionID:inputSessionID)
        }
        if let client = sender as? any IMKTextInput { observeHost(client) }
        if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type) {
            session?.invalidateContext("mouse",preserveHighlight:true)
            shiftTap.keyDown()
            preserveEditorDraft()
            session?.flushOriginal()
            return false
        }
        guard event.type == .keyDown || event.type == .flagsChanged else { return false }
        if !isActive || activeClient == nil { activateServer(sender) }
        if let client = sender as? any IMKTextInput { activeClient = client }
        // The editor owns its detached session. The host still needs a fresh
        // one for Shift, even before the first letter and while that draft lives.
        if session == nil { session = try? newSession() }
        let flags = event.modifierFlags
        if event.type == .flagsChanged {
            let other = !flags.intersection([.command,.control,.option,.capsLock]).isEmpty
            if shiftTap.flagsChanged(shift:flags.contains(.shift),otherModifier:other,keyCode:event.keyCode,timestamp:event.timestamp) {
                if let session, !session.isInEditor { session.setASCIIMode(!session.asciiMode); return true }
            }
            return false
        }
        shiftTap.keyDown()
        if ConfigurationStore.shared.editorShortcut.matches(event) { openEditor(); return true }
        // Returning to the host to type must not silently restore the editor
        // draft as marked text. Only the explicit shrink action transfers it.
        if session == nil { session = try? newSession() }
        guard let session else { return false }
        guard let key = InputKey.value(event) else {
            session.invalidateContext("unknown-key",preserveHighlight:true); showCandidates(); return false
        }
        if ConfigurationStore.shared.contextAwarenessEnabled, !session.asciiMode, !session.isInEditor,
           let client = sender as? any IMKTextInput {
            let prefix = inputContext.read(client,hasComposition:!session.markedText.isEmpty)
            session.setContext(prefix.map { $0 + session.draft })
        } else { session.invalidateContext("disabled-or-ineligible") }
        let handled = session.handle(key:key,control:flags.contains(.control),shift:flags.contains(.shift),command:flags.contains(.command),option:flags.contains(.option))
        if diagnosticEvents <= 20 { diagnose("handled",client:sender as? any IMKTextInput,fields:["handled":handled]) }
        // Host navigation/shortcuts also invalidate the badge. Repaint only
        // the panel here, without rewriting the host's selection/marked text.
        if !handled { showCandidates() }
        return handled
    }
    private func refresh() {
        guard isActive, let session, !session.isInEditor, let client = activeClient else { return }
        AppPresence.shared.updateInputLanguage(asciiMode:session.asciiMode,controller:self)
        guard !DraftEditor.shared.suspendsHostUpdates(in:client,sessionID:inputSessionID) else { return }
        // Shift changes only this session's language. Selecting a native mode
        // here would expose English as a second system input source.
        let text = session.markedText
        let marked = client.markedRange()
        // Some clients return a zero-length marked range when there is no
        // composition. An empty update would then replace the user's selection.
        if !text.isEmpty || (marked.location != NSNotFound && marked.length > 0) { client.setMarkedText(text,selectionRange:NSRange(location:session.markedCaret,length:0),replacementRange:NSRange(location:NSNotFound,length:0)) }
        inputContext.expectComposition(text,caret:session.markedCaret)
        showCandidates()
    }
    private func showCandidates() {
        guard isActive, let session, !session.isInEditor, let client = activeClient,
              !DraftEditor.shared.suspendsHostUpdates(in:client,sessionID:inputSessionID) else { return }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex:0,lineHeightRectangle:&rect)
        panel.show(session:session,anchor:rect,expand:{ [weak self] in self?.openEditor() },ask:{ [weak self] in self?.openAIQuestion() },configureAction:{ SettingsWindow.shared.showCandidateActions() }) { SettingsWindow.shared.show() }
    }
    deinit { NotificationCenter.default.removeObserver(self); DistributedNotificationCenter.default().removeObserver(self) }
#if CONTEXT_PROBE
    @objc private func sampleContext(_ notice:Notification) {
        guard isActive, let client = activeClient else { return }
        // Exercise a real Rime composition only in the owned test host, never
        // in a user application. These are not global/synthetic keyboard events.
        if let action = notice.userInfo?["fixtureAction"] as? String,
           notice.userInfo?["bundle"] as? String == "com.fangcun.ContextHostProbe",
           client.bundleIdentifier() == "com.fangcun.ContextHostProbe",
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.fangcun.ContextHostProbe" {
            if action == "begin-pinyin" { _ = session?.handle(key:104) }
            if action == "cancel-pinyin" { _ = session?.handle(key:0xff1b) }
            if action == "continuous-key", let key = notice.userInfo?["key"] as? Int,
               [32,97,103,104,105,110,115].contains(key), let scalar = UnicodeScalar(key) {
                let codes:[Int:UInt16] = [32:49,97:0,103:5,104:4,105:34,110:45,115:1]
                let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,characters:String(scalar),charactersIgnoringModifiers:String(scalar),isARepeat:false,keyCode:codes[key]!)!
                _ = process(event,client:client)
            }
            return
        }
        ContextProbe.sample(notice,client:client,hasComposition:session?.markedText.isEmpty == false,session:inputSessionID,contextStatus:contextStatus)
    }
#endif
    @objc private func inputSourceChanged() {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else { return }
        let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        selectedInputSourceChanged(to:id)
    }
    func selectedInputSourceChanged(to id:String) {
        if !id.hasPrefix(InputSourceStatus.bundleID + ".") && id != InputSourceStatus.bundleID {
            if isActive { deactivateServer(activeClient) }
            // Selecting this Chinese input method again starts in Chinese,
            // even if a previous text client was left in temporary English mode.
            if session?.isInEditor != true { session?.setASCIIMode(false) }
            shiftTap.reset()
        }
    }
    @objc private func configurationChanged() { session?.configurationChanged() }
    @objc private func candidateActionChanged() { session?.refreshCandidateAction() }
    @objc private func contextSettingChanged() { session?.invalidateContext("setting-changed"); refresh() }
    @objc private func pinyinLayoutChanged() {
        do { try session?.requestPinyinLayout(ConfigurationStore.shared.pinyinLayout) }
        catch { NSLog("拼音方案切换失败：%@",error.localizedDescription) }
    }
    nonisolated override func showPreferences(_ sender: Any!) { MainActor.assumeIsolated { SettingsWindow.shared.show() } }
    private struct MenuOnMainThread: @unchecked Sendable { let value: NSMenu }
    nonisolated override func menu() -> NSMenu! { MainActor.assumeIsolated { MenuOnMainThread(value:makeMenu()) }.value }
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let chinese = NSMenuItem(title:"中文输入",action:#selector(useChinese),keyEquivalent:""); chinese.target = self; chinese.state = session?.asciiMode == true ? .off : .on; menu.addItem(chinese)
        let english = NSMenuItem(title:"英文直输（轻按 Shift 切换）",action:#selector(useEnglish),keyEquivalent:""); english.target = self; english.state = session?.asciiMode == true ? .on : .off; menu.addItem(english)
        let layouts = NSMenuItem(title:"拼音方案",action:nil,keyEquivalent:"")
        let choices = NSMenu()
        for (index,layout) in PinyinLayout.allCases.enumerated() {
            let item = NSMenuItem(title:layout.name,action:#selector(selectPinyinLayout(_:)),keyEquivalent:"")
            item.target = self; item.tag = index
            item.state = ConfigurationStore.shared.pinyinLayout == layout ? .on : .off
            choices.addItem(item)
        }
        layouts.submenu = choices; menu.addItem(layouts)
        menu.addItem(.separator())
        let editor = NSMenuItem(title:DraftEditor.shared.hasDraft ? "继续临时编辑…" : "临时编辑区…",action:#selector(openEditor),keyEquivalent:ConfigurationStore.shared.editorShortcut.key)
        editor.keyEquivalentModifierMask = ConfigurationStore.shared.editorShortcut.flags; editor.target = self; menu.addItem(editor)
        let ask = NSMenuItem(title:"问 AI…",action:#selector(openAIQuestion),keyEquivalent:""); ask.target = self; menu.addItem(ask)
        let currentAction = session?.candidateAction ?? ConfigurationStore.shared.candidateAction
        let toggle = NSMenuItem(title:currentAction.candidateLabel,action:#selector(toggleTranslation),keyEquivalent:""); toggle.target = self; toggle.state = session?.translateEnabled == true ? .on : .off; menu.addItem(toggle)
        let candidateActions = NSMenuItem(title:"候选框 AI 动作",action:nil,keyEquivalent:"")
        let actionMenu = NSMenu()
        for action in ConfigurationStore.shared.actions {
            let item = NSMenuItem(title:action.name,action:#selector(selectCandidateAction(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = action.id; item.state = action.id == currentAction.id ? .on : .off
            actionMenu.addItem(item)
        }
        candidateActions.submenu = actionMenu; menu.addItem(candidateActions)
        let settings = NSMenuItem(title:"设置…",action:#selector(showPreferences(_:)),keyEquivalent:""); settings.target = self; menu.addItem(settings)
        return menu
    }
    @objc private func selectCandidateAction(_ sender:NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = ConfigurationStore.shared.actions.first(where:{$0.id == id}) else { return }
        if let session { session.setCandidateAction(action) }
        else { ConfigurationStore.shared.candidateActionID = id }
    }
    @objc private func selectPinyinLayout(_ sender: NSMenuItem) {
        guard PinyinLayout.allCases.indices.contains(sender.tag) else { return }
        ConfigurationStore.shared.pinyinLayout = PinyinLayout.allCases[sender.tag]
        NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
    }
    @objc private func toggleTranslation() { session?.setTranslateEnabled(!(session?.translateEnabled ?? false)) }
    @objc private func useChinese() { shiftTap.reset(); session?.setASCIIMode(false) }
    @objc private func useEnglish() { shiftTap.reset(); session?.setASCIIMode(true) }
}
