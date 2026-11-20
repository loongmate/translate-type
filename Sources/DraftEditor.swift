import AppKit
import InputMethodKit

// A retained IMK client identifies the original text field, not whichever app
// happens to be active when a translation finishes. No AX or clipboard injection.
@MainActor
final class DraftDestination {
    private(set) var client: any IMKTextInput
    let application: NSRunningApplication?
    let sessionID: UUID?
    private let identity: String?
    private let bundleID: String
    private var selection: NSRange?
    private var length: Int?
    private var contextRange = NSRange(location:0,length:0)
    private var context: String?
    private var commitFailure: String?
    func matches(_ other:any IMKTextInput,sessionID otherSessionID:UUID? = nil) -> Bool {
        guard bundleID == (other.bundleIdentifier() ?? "") else { return false }
        if let sessionID, let otherSessionID, sessionID != otherSessionID { return false }
        if let identity, let otherIdentity = Self.stableIdentity(other) { return identity == otherIdentity }
        // IMK creates a controller for each input session. Its sender may be a
        // renewed proxy with no unique identifier; pointer equality is not a
        // reliable session identity. Range/context validation still applies.
        if let sessionID, sessionID == otherSessionID { return true }
        return (client as AnyObject) === (other as AnyObject)
    }
    func refreshClient(_ other:any IMKTextInput,sessionID:UUID?) {
        if matches(other,sessionID:sessionID) { client = other }
    }
    // IMKInputSession.h describes this as a globallyUniqueString wrapper, not
    // a guaranteed stable field ID. Only use it if consecutive reads agree.
    private static func stableIdentity(_ client:any IMKTextInput) -> String? {
        guard let first = client.uniqueClientIdentifierString(), !first.isEmpty,
              first == client.uniqueClientIdentifierString() else { return nil }
        return first
    }
    private static func availableRange(_ range:NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.length != NSNotFound,
              range.location >= 0, range.length >= 0, range.length <= Int.max-range.location else { return nil }
        return range
    }
    private static func availableLength(_ length:Int) -> Int? { length >= 0 && length != NSNotFound ? length : nil }
    var name: String { application?.localizedName ?? "原输入框" }
    init(client:any IMKTextInput,sessionID:UUID? = nil) {
        self.client = client
        self.sessionID = sessionID
        identity = Self.stableIdentity(client)
        bundleID = client.bundleIdentifier() ?? ""
        application = NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).first
        reanchor()
    }
    var problem: String? {
        if let commitFailure { return commitFailure }
        if let app = application {
            if app.isTerminated { return "原应用已退出，草稿仍保留，可复制文字。" }
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != app.processIdentifier && front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                return "已切换应用，请先返回\(name)。"
            }
        }
        if let identity, let currentIdentity = Self.stableIdentity(client), identity != currentIdentity {
            return "原输入位置已变化，请重新确认光标。"
        }
        if let selection, let current = Self.availableRange(client.selectedRange()), current != selection {
            return "原输入位置已变化，请重新确认光标。"
        }
        if let marked = Self.availableRange(client.markedRange()), marked.length > 0 {
            return "原输入框仍有未完成的选词，请先完成选词。"
        }
        // These document-access APIs are optional capabilities. NSNotFound or
        // nil means unavailable, not evidence that the user changed fields.
        if let context, let current = client.attributedSubstring(from:contextRange)?.string, current != context {
            return "原输入框内容已变化，请重新确认光标。"
        }
        return nil
    }
    func reanchor() {
        commitFailure = nil
        selection = Self.availableRange(client.selectedRange()); length = Self.availableLength(client.length())
        context = nil
        guard let selection else { return }
        if let length, NSMaxRange(selection) > length { self.length = nil }
        // Bounded text queries; never manufacture document size from NSNotFound.
        guard let length = self.length else { return }
        let start = max(0,selection.location-24), end = NSMaxRange(selection)+min(24,length-NSMaxRange(selection))
        contextRange = NSRange(location:start,length:max(0,end-start))
        context = client.attributedSubstring(from:contextRange)?.string
    }
    func diagnosticState() -> [String:Any] {
        let current = client.selectedRange(), marked = client.markedRange()
        let first = client.uniqueClientIdentifierString() ?? "", second = client.uniqueClientIdentifierString() ?? ""
        return ["bundle":bundleID,"session":sessionID?.uuidString ?? "", "identityStable":first == second,
                "identityMatches":identity == first,"identityAvailable":identity != nil,
                "anchorSelection":selection.map { [$0.location,$0.length] } ?? [],"selection":[current.location,current.length],
                "anchorLength":length ?? NSNotFound,"length":client.length(),"marked":[marked.location,marked.length],
                "contextAvailable":context != nil,"knownSelection":selection != nil,"problem":problem ?? ""]
    }
    func insert(_ text:String) -> Bool {
        guard problem == nil else { return false }
        // Avoid polling document length every 500 ms: Apple warns it can be
        // expensive. Check it once at commit when both values are available.
        if let length, let current = Self.availableLength(client.length()), length != current {
            commitFailure = "原输入框内容已变化，请重新确认光标。"
            return false
        }
        client.insertText(text,replacementRange:NSRange(location:NSNotFound,length:NSNotFound))
        return true
    }
}

@MainActor
final class DraftEditor: NSObject, NSWindowDelegate, NSTextViewDelegate, DraftTextOwner {
    typealias ResumeAction = (CompositionSession,any IMKTextInput)->Bool
    private struct Host {
        let client: any IMKTextInput
        let sessionID: UUID?
        let resume: ResumeAction?
    }
    static let shared = DraftEditor()
    private(set) var session: CompositionSession?
    private(set) var destination: DraftDestination?
    private var resumeAction: ResumeAction?
    private var previousUpdate: (()->Void)?
    private(set) var window: DraftEditorPanel!
    let source = DraftTextView()
    let result = DraftTextView()
    let reference = DraftTextView()
    let followUp = DraftTextView()
    private var auxiliary: [ObjectIdentifier:CompositionSession] = [:]
    private var auxiliaryHistory: [ObjectIdentifier:UndoManager] = [:]
    private var auxiliaryPrevious: [ObjectIdentifier:(String,NSRange)] = [:]
    private var restoringAuxiliary = false
    private var syncingAuxiliary = false
    private let modes = NSSegmentedControl(labels:["改文字","问问 AI"],trackingMode:.selectOne,target:nil,action:nil)
    private let actionPicker = NSPopUpButton()
    private let actionSearch = NSSearchField()
    private let versions = NSPopUpButton()
    private let sourceTitle = NSTextField(labelWithString:"原文")
    private let resultTitle = NSTextField(labelWithString:"结果 · 可修改")
    private let copyAnswer = NSButton()
    private let referenceToggle = WorkspaceButton("参考文字",symbol:"paperclip",target:nil,action:nil)
    private var actionTools: NSStackView!
    private var referencePane: NSView!
    private var followUpPane: NSView!
    private let sendFollowUp = NSButton()
    private var actionEditor: AIActionWindow?
    private var modeHistory: [EditorAIMode:UndoManager] = [:]
    private var lastArchive: EditorArchive?
    private let restoreLast = WorkspaceButton("上次内容",target:nil,action:nil)
    private(set) var history = UndoManager()
    private let candidatePanel = CandidatePanel()
    private let count = NSTextField(labelWithString:"")
    private let status = NSTextField(wrappingLabelWithString:"")
    private let destinationLabel = NSTextField(wrappingLabelWithString:"")
    let transcript = ChatTranscriptView(frame:.zero)
    private let chatTools = NSStackView()
    private let newChat = WorkspaceButton("新对话",symbol:"square.and.pencil",target:nil,action:nil,kind:.soft)
    private let continueChat = WorkspaceButton("继续",target:nil,action:nil)
    private let copyChat = WorkspaceButton("复制回答",symbol:"doc.on.doc",target:nil,action:nil)
    private let directoryButton = WorkspaceButton("工作目录",symbol:"folder",target:nil,action:nil)
    private var chatSidebar: NSView!
    private let conversationList = WorkspaceStyle.column(spacing:5)
    private let conversationScroll = NSScrollView()
    private let chatTitle = WorkspaceStyle.label("新对话",size:12,weight:.medium,color:WorkspaceStyle.ink)
    private var transformTools: NSView!
    private var sourceHeading: NSView!
    private var chatHeader: NSView!
    private var mainWidth: NSLayoutConstraint!
    private var sourceCardHeight: NSLayoutConstraint!
    private let workspaceTitle = WorkspaceStyle.label("改文字",size:13,weight:.semibold,color:WorkspaceStyle.ink)
    private var switchingConversation = false
    private var currentConversationID = UUID()
    private struct Conversation {
        var id: UUID
        var messages: [AgentMessage]
        var directory: String
        var provider: ModelConfiguration?
        var draft: String
        var reference: String
        var title: String { String((messages.first(where:{$0.role == "user"})?.content ?? draft).split(separator:"\n").first.map(String.init)?.prefix(20) ?? "新对话") }
    }
    private var conversations: [Conversation] = []
    private var sourceHeight: NSLayoutConstraint!
    private var panes: NSStackView!
    private var resultPane: NSView!
    private let language = WorkspaceButton("中 ⇧",target:nil,action:nil)
    private let style = NSPopUpButton()
    private let translate = WorkspaceButton("发送 ⌃↵",symbol:"arrow.up",target:nil,action:nil,kind:.primary)
    private let insertSource = WorkspaceButton("原文上屏",target:nil,action:nil)
    private let insertResult = WorkspaceButton("插入回答",symbol:"arrow.turn.down.left",target:nil,action:nil,kind:.soft)
    private let cancel = WorkspaceButton("停止",symbol:"stop",target:nil,action:nil,kind:.soft)
    private let recover = WorkspaceButton("重新绑定光标",target:nil,action:nil)
    private var previousDraft = ""
    private var previousSelection = NSRange(location:0,length:0)
    private var rendering = false
    private var restoring = false
    private var shiftTap = ShiftTap()
    private var timer: Timer?
    private var savedScroll = NSPoint.zero
    private var lastMarked = ""
    private var lastCaret = -1
    private var message: String?
    private var hostHasMoved = false
    private var currentHost: Host?
    private var lastDiagnosticProblem: String?
    private var lastObservedMismatch: String?
    private enum Handoff { case opening, recovering, committing }
    private var handoff: Handoff?
    private var handoffTask: Task<Void,Never>?
    private var showAfterHandoff = true
    private var removalCaret: Int?
    private var awaitingRemoval = false
    static func isInternalClient(_ client:any IMKTextInput) -> Bool {
        let bundle = client.bundleIdentifier() ?? ""
        return !bundle.isEmpty && ([Bundle.main.bundleIdentifier ?? "",InputSourceStatus.bundleID]+InputSourceStatus.legacyBundleIDs).contains(bundle)
    }
    func hostActivated(_ client:any IMKTextInput,sessionID:UUID? = nil,resume:ResumeAction? = nil) {
        guard let destination else {
            guard session != nil, !Self.isInternalClient(client) else { return }
            currentHost = Host(client:client,sessionID:sessionID,resume:resume)
            hostHasMoved = true
            refreshDestination()
            return
        }
        // Settings and transient clients belonging to this IME never replace
        // the external insertion destination.
        guard !Self.isInternalClient(client) else { return }
        let bundle = client.bundleIdentifier() ?? ""
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != app.processIdentifier {
            guard front.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  destination.matches(client,sessionID:sessionID) else { return }
        }
        currentHost = Host(client:client,sessionID:sessionID,resume:resume)
        hostHasMoved = !destination.matches(client,sessionID:sessionID)
        let mismatch = hostHasMoved ? (sessionID?.uuidString ?? "")+bundle : nil
        if hostHasMoved && mismatch != lastObservedMismatch {
            EditorDiagnostics.record("host-mismatch",["target":destination.diagnosticState(),"observedSession":sessionID?.uuidString ?? "","observedBundle":bundle,"panelKey":window?.isKeyWindow == true])
        }
        lastObservedMismatch = mismatch
        if !hostHasMoved {
            destination.refreshClient(client,sessionID:sessionID)
            if let resume { resumeAction = resume }
        }
        refreshDestination()
    }
    private var targetProblem: String? {
        if handoff == .opening { return "正在整理原输入位置…" }
        if handoff == .recovering { return "正在重新绑定光标…" }
        if handoff == .committing { return "正在返回原输入框…" }
        if destination == nil { return "未绑定输入框，可以直接提问并复制回答。" }
        return hostHasMoved ? "输入位置已变化，请重新绑定光标后上屏。" : destination?.problem
    }
    var canCommitSource: Bool { insertSource.isEnabled }
    var isHandingOff: Bool { handoff != nil }
    var destinationMessage: String { destinationLabel.stringValue }
    func suspendsHostUpdates(in client:any IMKTextInput,sessionID:UUID) -> Bool {
        session != nil && destination?.matches(client,sessionID:sessionID) == true && (handoff != nil || window?.isKeyWindow == true)
    }
    func hostWillProcessInput(_ client:any IMKTextInput,sessionID:UUID) {
        guard handoff == .committing, destination?.matches(client,sessionID:sessionID) == true else { return }
        // A real host keystroke during focus handoff wins over the delayed
        // insertion. Keep the draft, cancel the write, and process that key.
        handoffTask?.cancel(); handoffTask = nil; handoff = nil
        message = "原输入框已继续输入，本次上屏已取消，编辑草稿仍保留。"
        EditorDiagnostics.record("commit-cancelled-by-host-input")
    }
    var hasDraft: Bool { session != nil }
    var isVisible: Bool { window?.isVisible == true }
    var shortcutLabel: String { ConfigurationStore.shared.editorShortcut.displayName }

    func open(session state:CompositionSession,client:any IMKTextInput,sessionID:UUID? = nil,present:Bool = true,resume:@escaping ResumeAction) {
        if session != nil { show(); return }
        // Set the detached flag before touching the client: clearing marked text
        // can synchronously call commitComposition/deactivateServer in some apps.
        state.beginEditor()
        let marked = client.markedRange()
        let ownsMarkedText = !state.markedText.isEmpty
        removalCaret = ownsMarkedText && marked.location != NSNotFound && marked.length > 0 && marked.length != NSNotFound ? marked.location : nil
        awaitingRemoval = ownsMarkedText
        destination = DraftDestination(client:client,sessionID:sessionID); hostHasMoved = false
        lastDiagnosticProblem = nil; lastObservedMismatch = nil
        EditorDiagnostics.record("open",destination!.diagnosticState())
        currentHost = Host(client:client,sessionID:sessionID,resume:resume)
        resumeAction = resume
        prepareSession(state)
        // Return the triggering IMK key event before moving keyboard focus.
        // Browser clients may apply composition changes only after that return.
        handoff = .opening; showAfterHandoff = present
        if ownsMarkedText {
            client.setMarkedText("",selectionRange:NSRange(location:0,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            EditorDiagnostics.record("clear-request",destination!.diagnosticState())
        }
        settleOpening()
    }
    private func prepareSession(_ state:CompositionSession) {
        currentConversationID = UUID()
        session = state; previousUpdate = state.onUpdate
        state.onUpdate = { [weak self] in self?.refresh() }
        state.agent.onUpdate = { [weak self] in self?.refresh() }
        previousDraft = state.draft; previousSelection = state.draftSelection
        history.removeAllActions(); savedScroll = .zero; lastMarked = ""; lastCaret = -1; message = nil
        if window == nil { build() }
        style.selectItem(at:0)
        setupAuxiliary()
        modeHistory = [.transform:history]; reloadActions()
    }
    private func settleOpening() {
        handoffTask?.cancel()
        handoffTask = Task { @MainActor [weak self] in
            // At least one event-loop turn for the IMK callback to unwind.
            try? await Task.sleep(nanoseconds:30_000_000)
            guard let self else { return }
            for _ in 0..<30 {
                guard !Task.isCancelled, self.handoff == .opening, let destination = self.destination else { return }
                let marked = destination.client.markedRange(), selected = destination.client.selectedRange()
                let markedCleared = marked.location == NSNotFound || marked.length == 0
                let atExpectedCaret = self.removalCaret == nil || selected.location == NSNotFound || (selected.location == self.removalCaret && selected.length == 0)
                if self.hostHasMoved { break }
                if !self.awaitingRemoval || (markedCleared && atExpectedCaret) {
                    // Capture only the post-clear state, never our own old
                    // marked range returned from inside the originating key.
                    if self.awaitingRemoval { destination.reanchor() }
                    self.awaitingRemoval = false; self.removalCaret = nil; self.handoff = nil; self.message = nil
                    EditorDiagnostics.record("open-ready",destination.diagnosticState())
                    if self.showAfterHandoff { self.show() } else { self.refresh() }
                    return
                }
                try? await Task.sleep(nanoseconds:25_000_000)
            }
            guard !Task.isCancelled else { return }
            self.handoff = nil
            self.message = "原输入框尚未完成状态更新。请点「重新绑定光标」恢复；草稿已保留。"
            EditorDiagnostics.record("open-timeout",self.destination?.diagnosticState() ?? [:])
            if self.showAfterHandoff { self.show() } else { self.refresh() }
        }
    }
    func show() {
        guard session != nil else { return }
        guard handoff == nil else { showAfterHandoff = true; return }
        if window == nil { build() }
        shiftTap.reset(); refresh()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(source)
        source.enclosingScrollView?.contentView.scroll(to:savedScroll)
        startTimer(); refreshCandidates()
    }
    func hide() {
        if handoff == .opening { showAfterHandoff = false }
        savedScroll = source.enclosingScrollView?.contentView.bounds.origin ?? .zero
        session?.cancelTranslationIfWorking()
        candidatePanel.orderOut(nil); window?.orderOut(nil); timer?.invalidate(); timer = nil; shiftTap.reset()
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { hide(); return false }
    func windowDidResignKey(_ notification:Notification) { shiftTap.reset(); candidatePanel.orderOut(nil) }
    func windowDidBecomeKey(_ notification:Notification) { refresh(); refreshCandidates() }
    func windowDidResize(_ notification:Notification) { refreshCandidates() }
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDestination() }
        }
    }
    @objc func collapse() {
        guard let session else { return }
        if session.editorMode == .ask || session.editorAction.id != "english" { hide(); return }
        guard let destination else { hide(); return }
        guard handoff == nil else { return }
        if let problem = targetProblem { message = problem; refresh(); return }
        savedScroll = source.enclosingScrollView?.contentView.bounds.origin ?? .zero
        candidatePanel.orderOut(nil); window.orderOut(nil)
        session.onUpdate = previousUpdate
        if resumeAction?(session,destination.client) == true {
            self.session = nil; self.destination = nil; currentHost = nil; previousUpdate = nil; resumeAction = nil
            timer?.invalidate(); timer = nil; history.removeAllActions()
        } else {
            session.onUpdate = { [weak self] in self?.refresh() }
            message = "请回到原输入框，或复制草稿。"; show()
        }
    }
    @objc func commitSource() {
        guard session?.editorMode == .transform else { return }
        commit(session?.draft)
    }
    var selectedResult: String? {
        if session?.editorMode == .ask { return transcript.answerSelection(or:session?.agent.latestAnswer) }
        guard let text = session?.translation else { return nil }
        let selection = result.selectedRange(), value = text as NSString
        if selection.length > 0, selection.location != NSNotFound, NSMaxRange(selection) <= value.length {
            return value.substring(with:selection)
        }
        return text
    }
    @objc func commitResult() {
        guard session?.isTranslating == false, session?.agent.isRunning == false else { return }
        commit(selectedResult)
    }
    @objc func commitPreferred() {
        guard let session else { return }
        // While a result is pending, Cmd+Enter must never unexpectedly submit
        // the source. Cmd+Shift+Enter is the explicit original-text action.
        guard !session.isTranslating, !session.agent.isRunning else { refresh(); return }
        if session.editorMode == .ask { commit(selectedResult) }
        else if session.translation != nil { commit(selectedResult) }
        else if session.editorMode == .transform && session.displayedAnswer == nil { commit(session.draft) }
        else { message = "请先生成有效结果，或在改文字中明确选择原文上屏。"; refresh() }
    }
    @discardableResult
    func handleCommitShortcut(_ event:NSEvent) -> Bool {
        guard event.type == .keyDown, [36,76].contains(event.keyCode) else { return false }
        let flags = event.modifierFlags.intersection([.command,.control,.shift,.option])
        guard flags == [.command] || flags == [.command,.shift] else { return false }
        if !event.isARepeat {
            if flags.contains(.shift) { commitSource() } else { commitPreferred() }
        }
        return true
    }
    private func commit(_ value:String?) {
        guard let session, handoff == nil else { return }
        EditorDiagnostics.record("commit-request",destination?.diagnosticState() ?? [:])
        guard !hasPendingInput else { informPending(); return }
        guard let text = value, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            message = session.translation == nil ? "请先输入要上屏的文字。" : "译文为空；可补充译文，或按 ⇧⌘Enter 上屏原文。"
            refresh(); return
        }
        guard targetProblem == nil, let destination else { message = targetProblem; refresh(); return }
        handoff = .committing
        hide()
        returnFocusToHost(destination.application)
        // Release the nonactivating panel's keyboard focus before inserting.
        // Never post a synthetic key or wait for the user's next keystroke.
        handoffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:50_000_000)
            guard let self, !Task.isCancelled, self.handoff == .committing, self.session === session else { return }
            guard !self.hostHasMoved, destination.problem == nil, destination.insert(text) else {
                self.handoff = nil
                self.message = destination.problem ?? "目标已变化，草稿已保留，请重新绑定光标。"
                EditorDiagnostics.record("commit-blocked",destination.diagnosticState())
                self.show(); return
            }
            EditorDiagnostics.record("commit-dispatched",destination.diagnosticState().merging(["panelVisible":self.isVisible,"panelKey":self.window.isKeyWindow]) { _,new in new })
            if session.editorMode == .ask { self.rememberConversation() }
            self.lastArchive = session.editorArchive
            session.onUpdate = nil; session.finishEditor(); session.onUpdate = self.previousUpdate
            self.session = nil; self.destination = nil; self.currentHost = nil; self.resumeAction = nil; self.previousUpdate = nil; self.history.removeAllActions()
            self.handoff = nil; self.handoffTask = nil
        }
    }
    @objc func recoverDestination() {
        guard handoff == nil, let currentHost, !Self.isInternalClient(currentHost.client) else { return }
        if awaitingRemoval && !hostHasMoved {
            handoff = .opening; showAfterHandoff = true
            window.orderOut(nil); candidatePanel.orderOut(nil)
            settleOpening(); return
        }
        handoff = .recovering
        window.orderOut(nil); candidatePanel.orderOut(nil)
        returnFocusToHost(NSRunningApplication.runningApplications(withBundleIdentifier:currentHost.client.bundleIdentifier() ?? "").first)
        handoffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:50_000_000)
            guard let self, !Task.isCancelled, self.handoff == .recovering,
                  let latest = self.currentHost, latest.sessionID == currentHost.sessionID else {
                self?.handoff = nil; self?.show(); return
            }
            self.handoff = nil
            self.bindCurrentDestination(latest)
            self.show()
        }
    }
    private func bindCurrentDestination(_ currentHost:Host) {
        let candidate = DraftDestination(client:currentHost.client,sessionID:currentHost.sessionID)
        EditorDiagnostics.record("recover",candidate.diagnosticState())
        if let app = candidate.application, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != app.processIdentifier && front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate(options:[]); message = "请在该应用中点击要上屏的输入框，再按 \(shortcutLabel) 返回编辑区。"
        } else if let problem = candidate.problem {
            message = problem
        } else if currentHost.resume == nil && hostHasMoved {
            message = "请在要上屏的输入框按 \(shortcutLabel)，再确认输入位置。"
        } else {
            // This button is explicit consent to use the observed field's
            // current selection. Never silently rebind on activation alone.
            destination = candidate; hostHasMoved = false
            if let resume = currentHost.resume { resumeAction = resume }
            awaitingRemoval = false; removalCaret = nil
            message = "光标已绑定。按 ⌘Enter 上屏，或点击下方上屏按钮。"
        }
        refresh()
    }
    private func returnFocusToHost(_ application:NSRunningApplication?) {
        if let application, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            application.activate(options:[])
        }
    }
    func refreshDestination() {
        guard let s = session else { return }
        let problem = targetProblem
        if problem != lastDiagnosticProblem {
            lastDiagnosticProblem = problem
            EditorDiagnostics.record("target-status",["problem":problem ?? "","hostHasMoved":hostHasMoved,"target":destination?.diagnosticState() ?? [:]])
        }
        destinationLabel.stringValue = problem ?? "目标：\(destination?.name ?? "原输入框") · ⌘Enter 上屏"
        destinationLabel.textColor = problem == nil || destination == nil ? WorkspaceStyle.muted : .systemOrange
        recover.isHidden = problem == nil || currentHost == nil
        let observedApp = currentHost.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier:$0.client.bundleIdentifier() ?? "").first }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        recover.title = observedApp != nil && frontPID != observedApp?.processIdentifier && frontPID != ProcessInfo.processInfo.processIdentifier ? "返回目标应用" : "重新绑定光标"
        recover.isEnabled = handoff == nil && currentHost != nil
        recover.toolTip = "只重新绑定输入位置；绑定后按 ⌘Enter 或点击上屏按钮写入文字"
        let valid = destination != nil && problem == nil && !hasPendingInput
        insertSource.isEnabled = valid && !s.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        insertResult.isEnabled = valid && !s.isTranslating && !s.agent.isRunning && !(selectedResult ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        insertSource.isHidden = s.editorMode == .ask
        insertSource.title = s.displayedAnswer != nil || s.isTranslating ? "原文上屏 ⇧⌘↵" : "原文上屏 ⌘↵"
        insertSource.toolTip = "将原文写回原输入框（⇧⌘Enter）；不会发送消息"
        insertResult.title = s.editorMode == .ask ? (transcript.textView.selectedRange().length > 0 ? "插入所选回答 ⌘↵" : "插入回答 ⌘↵") : result.selectedRange().length > 0 ? "插入选中 ⌘↵" : "结果上屏 ⌘↵"
        insertResult.toolTip = "把结果或选中的部分写回原输入框（⌘Enter）；不会发送消息"
        copyAnswer.title = result.selectedRange().length > 0 ? "复制选中" : "复制"
        copyAnswer.isEnabled = !hasPendingInput && !(s.displayedAnswer ?? "").isEmpty && !s.isTranslating
        if s.editorMode == .transform && result.selectedRange().length > 0 { count.stringValue = "已选 \((selectedResult ?? "").count) 字 · ⌘Enter 只插入选中部分" }
    }
    func refresh() {
        guard let s = session, window != nil, !switchingConversation else { return }
        rendering = true
        if previousDraft != s.draft {
            if !restoring {
                let text = previousDraft, selection = previousSelection
                history.registerUndo(withTarget:self) { target in MainActor.assumeIsolated { target.restoreDraft(text,selection:selection) } }
                history.setActionName("编辑草稿")
            }
            previousDraft = s.draft
        }
        previousSelection = s.draftSelection
        let changed = source.string != s.markedText
        if changed {
            source.string = s.markedText
            source.textStorage?.setAttributes([.font:NSFont.systemFont(ofSize:15),.foregroundColor:WorkspaceStyle.ink,.paragraphStyle:Self.paragraphStyle],range:NSRange(location:0,length:source.string.utf16.count))
        }
        if s.hasPendingInput {
            let range = NSRange(location:s.pendingTextStart,length:s.snapshot.preedit.utf16.count)
            source.textStorage?.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:range)
            source.setSelectedRange(NSRange(location:s.markedCaret,length:0))
        } else { source.setSelectedRange(s.draftSelection) }
        if changed || lastCaret != s.markedCaret { source.scrollRangeToVisible(source.selectedRange()) }
        lastMarked = s.markedText; lastCaret = s.markedCaret
        syncAuxiliary(reference,with:s.editorReference)
        syncAuxiliary(followUp,with:s.editorFollowUp)
        syncAuxiliary(result,with:s.displayedAnswer ?? "")
        result.isEditable = s.translation != nil && !s.isTranslating
        resultPane.isHidden = s.editorMode == .ask || (s.displayedAnswer == nil && !s.isTranslating)
        modes.selectedSegment = s.editorMode.rawValue
        sourceTitle.stringValue = s.editorMode == .ask ? "想让 AI 做什么？" : "原文"
        source.setAccessibilityLabel(sourceTitle.stringValue)
        resultTitle.stringValue = s.editorMode == .ask ? "回答 · 可修改" : "结果 · 可修改"
        actionTools.isHidden = s.editorMode == .ask
        if let item = actionPicker.itemArray.first(where: { $0.representedObject as? String == s.editorAction.id }) { actionPicker.select(item) }
        restoreLast.isHidden = lastArchive == nil
        style.isHidden = s.editorMode != .transform || s.editorAction.id != "english"
        referenceToggle.isHidden = s.editorMode != .ask
        referenceToggle.title = "参考文字" + (s.editorReference.isEmpty ? "" : " · \(s.editorReference.count) 字") + (referenceToggle.state == .on ? " ▾" : " ▸")
        referencePane.isHidden = s.editorMode != .ask || referenceToggle.state != .on
        followUpPane.isHidden = true
        followUp.isEditable = !s.isTranslating
        sendFollowUp.isEnabled = s.translation != nil && !s.isTranslating && !hasPendingInput && !s.editorFollowUp.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        if versions.numberOfItems != s.answers.count {
            versions.removeAllItems()
            versions.addItems(withTitles:s.answers.enumerated().map { "\($0.offset+1). \($0.element.label)" })
        }
        versions.selectItem(at:s.answerIndex); versions.isHidden = s.answers.count < 2
        versions.isEnabled = !s.isTranslating && !hasPendingInput && s.translation != nil
        let selection = result.selectedRange().length
        count.stringValue = selection > 0 ? "已选 \(selection) 字 · ⌘Enter 只插入选中部分" : "\(s.draft.count) 字  ·  Enter 换行  ·  ⌘V 粘贴  ·  ⌘Enter 上屏"
        let editing = editingSession(for:window.firstResponder as? DraftTextView ?? source) ?? s
        language.title = "\(editing.asciiMode ? "EN" : editing.pinyinLayout.shortName) ⇧"
        if window.isKeyWindow { AppPresence.shared.updateInputLanguage(asciiMode:editing.asciiMode) }
        translate.isHidden = s.isTranslating
        translate.isEnabled = s.canRequestTranslation && !hasPendingInput
        translate.title = hasPendingInput ? "先完成选词" : s.draft.count > TranslationClient.maximumCharacters ? "请分段处理" : s.editorMode == .ask ? (s.translation == nil ? "问 AI ⌃↵" : "重新回答 ⌃↵") : (s.translation == nil ? "执行动作 ⌃↵" : "重新生成 ⌃↵")
        cancel.isHidden = !s.isTranslating; insertResult.isHidden = s.displayedAnswer == nil
        status.stringValue = s.draft.count > TranslationClient.maximumCharacters ? "单次输入最多 20,000 字，草稿完整保留。" : hasPendingInput ? "空格确认候选；完成选词后才能执行或上屏。" : s.isTranslating ? "正在处理… 可随时停止，输入内容仍保留。" : s.errorMessage ?? message ?? (s.translation == nil && s.displayedAnswer != nil ? "输入或动作已变化，右侧为旧结果；重新执行后才能上屏。" : s.editorMode == .ask ? "⌃Enter 提问；在追问框中继续问。可修改回答、选择一部分再 ⌘Enter 上屏。" : "⌃Enter 执行动作；⌘Enter 上屏结果，⇧⌘Enter 上屏原文。不会发送消息。")
        status.textColor = s.errorMessage != nil ? .systemOrange : .secondaryLabelColor
        let asking = s.editorMode == .ask
        source.placeholder = asking ? "说说你想做什么，剩下的交给方寸…" : "在这里写下或粘贴想处理的文字…"
        window.title = asking ? "方寸 · 问问 AI" : "方寸 · 改文字"
        workspaceTitle.stringValue = asking ? "问问 AI" : "改文字"
        chatSidebar.isHidden = !asking; chatHeader.isHidden = !asking
        mainWidth.constant = asking ? -185 : 0
        sourceCardHeight.isActive = !asking
        transformTools.isHidden = asking; sourceHeading.isHidden = asking
        count.isHidden = asking
        transcript.isHidden = !asking; chatTools.isHidden = !asking
        sourceHeight.constant = asking ? 75 : 130
        if asking {
            transcript.update(s.agent.messages)
            sourceTitle.stringValue = "消息 · Enter 换行，⌃Enter 发送"
            source.setAccessibilityLabel("发送给问问 AI 的消息")
            translate.title = "发送 ⌃↵"; translate.isHidden = s.agent.isRunning
            translate.isEnabled = s.canRequestTranslation && !s.agent.isRunning && !hasPendingInput
            cancel.isHidden = !s.agent.isRunning
            insertResult.isHidden = s.agent.latestAnswer == nil
            newChat.isEnabled = !hasPendingInput
            continueChat.isHidden = s.agent.error == nil; continueChat.isEnabled = !s.agent.isRunning && !hasPendingInput
            copyChat.isEnabled = !s.agent.isRunning && s.agent.latestAnswer != nil
            directoryButton.title = (s.agent.directory as NSString).lastPathComponent
            directoryButton.toolTip = s.agent.directory; directoryButton.isEnabled = !s.agent.isRunning
            status.stringValue = hasPendingInput ? "请先完成选词，再发送消息。" : message ?? s.agent.status
            status.textColor = s.agent.error == nil ? .secondaryLabelColor : .systemOrange
            count.stringValue = "\(s.draft.count) 字 · \(s.agent.messages.filter { $0.role == "user" }.count) 轮对话 · ⌘Enter 插入所选回答或最新回答"
            updateConversationList()
        }
        rendering = false
        refreshDestination(); refreshCandidates()
    }
    private func restoreDraft(_ text:String,selection:NSRange) {
        guard let s = session, !s.hasPendingInput else { return }
        let inverse = s.draft, inverseSelection = s.draftSelection
        history.registerUndo(withTarget:self) { target in MainActor.assumeIsolated { target.restoreDraft(inverse,selection:inverseSelection) } }
        restoring = true; s.replaceEditorText(text,selection:selection); restoring = false
    }
    var hasPendingInput: Bool { session?.hasPendingInput == true || auxiliary.values.contains { $0.hasPendingInput } }
    func editingSession(for view:DraftTextView) -> CompositionSession? { view === source ? session : auxiliary[ObjectIdentifier(view)] }
    func editingUndoManager(for view:DraftTextView) -> UndoManager? { view === source ? history : auxiliaryHistory[ObjectIdentifier(view)] }
    private func setupAuxiliary() {
        auxiliary = [:]; auxiliaryHistory = [:]; auxiliaryPrevious = [:]
        do {
            for view in [reference,followUp,result] {
                let state = CompositionSession(engine:try PinyinEngine(layout:session?.pinyinLayout ?? .fullPinyin),translateEnabled:false)
                state.beginEditor(); state.setASCIIMode(view === result)
                auxiliary[ObjectIdentifier(view)] = state
                auxiliaryHistory[ObjectIdentifier(view)] = UndoManager()
                auxiliaryPrevious[ObjectIdentifier(view)] = ("",NSRange(location:0,length:0))
                state.onUpdate = { [weak self,weak view,weak state] in
                    guard let self,let view,let state,!self.syncingAuxiliary else { return }
                    let id = ObjectIdentifier(view)
                    if let prior = self.auxiliaryPrevious[id], prior.0 != state.draft, !self.restoringAuxiliary {
                        self.auxiliaryHistory[id]?.registerUndo(withTarget:self) { target in MainActor.assumeIsolated { target.restoreAuxiliary(view,text:prior.0,selection:prior.1) } }
                    }
                    self.auxiliaryPrevious[id] = (state.draft,state.draftSelection)
                    self.renderAuxiliary(view,state:state)
                    if view === self.reference { self.session?.setEditorReference(state.draft) }
                    else if view === self.followUp { self.session?.setEditorFollowUp(state.draft) }
                    else { self.session?.editTranslation(state.draft) }
                    self.refresh()
                }
            }
        } catch { message = "编辑区拼音初始化失败：" + error.localizedDescription }
    }
    private func restoreAuxiliary(_ view:DraftTextView,text:String,selection:NSRange) {
        guard let state = editingSession(for:view), !hasPendingInput else { return }
        let inverse = state.draft, inverseSelection = state.draftSelection
        auxiliaryHistory[ObjectIdentifier(view)]?.registerUndo(withTarget:self) { target in MainActor.assumeIsolated { target.restoreAuxiliary(view,text:inverse,selection:inverseSelection) } }
        restoringAuxiliary = true; state.replaceEditorText(text,selection:selection); restoringAuxiliary = false
    }
    private func syncAuxiliary(_ view:DraftTextView,with text:String) {
        guard let state = editingSession(for:view), !state.hasPendingInput else { return }
        syncingAuxiliary = true
        if state.draft != text {
            let selection = view.selectedRange()
            state.replaceEditorText(text,selection:NSRange(location:min(selection.location,text.utf16.count),length:0))
            editingUndoManager(for:view)?.removeAllActions()
            auxiliaryPrevious[ObjectIdentifier(view)] = (text,state.draftSelection)
        }
        syncingAuxiliary = false
        renderAuxiliary(view,state:state)
    }
    private func renderAuxiliary(_ view:DraftTextView,state:CompositionSession) {
        let wasRendering = rendering; rendering = true
        if view.string != state.markedText {
            view.string = state.markedText
            view.textStorage?.setAttributes([.font:NSFont.systemFont(ofSize:15),.foregroundColor:WorkspaceStyle.ink,.paragraphStyle:Self.paragraphStyle],range:NSRange(location:0,length:view.string.utf16.count))
        }
        if state.hasPendingInput {
            view.textStorage?.addAttribute(.underlineStyle,value:NSUnderlineStyle.single.rawValue,range:NSRange(location:state.pendingTextStart,length:state.snapshot.preedit.utf16.count))
            view.setSelectedRange(NSRange(location:state.markedCaret,length:0))
            view.scrollRangeToVisible(view.selectedRange())
        } else { view.setSelectedRange(state.draftSelection) }
        rendering = wasRendering
    }
    func refreshCandidates() {
        guard window?.isVisible == true, window.isKeyWindow, let view = window.firstResponder as? DraftTextView,
              let s = editingSession(for:view), s.hasPendingInput else { candidatePanel.orderOut(nil); return }
        let rect = view.firstRect(forCharacterRange:NSRange(location:s.markedCaret,length:0),actualRange:nil)
        candidatePanel.show(session:s,anchor:rect,settings:{ SettingsWindow.shared.show() })
    }
    @objc func requestTranslation() {
        guard !hasPendingInput else { informPending(); return }
        message = nil
        if window.firstResponder === followUp && session?.editorMode == .ask { requestFollowUp() }
        else { session?.requestTranslation() }
    }
    @objc func requestFollowUp() {
        guard !hasPendingInput else { informPending(); return }
        message = nil; session?.requestEditorAction(followUp:true)
    }
    @objc private func stopTranslation() { session?.stopEditorRequest() }
    @objc func startNewConversation() {
        guard !hasPendingInput, let s = session else { informPending(); return }
        switchingConversation = true; s.agent.stop(); rememberConversation()
        currentConversationID = UUID(); s.agent.reset(); s.setEditorReference("")
        s.replaceEditorText("",selection:NSRange(location:0,length:0))
        referenceToggle.state = .off; history.removeAllActions(); auxiliaryHistory.values.forEach { $0.removeAllActions() }
        previousDraft = ""; previousSelection = NSRange(location:0,length:0)
        switchingConversation = false; message = nil; transcript.resetConversation(); refresh(); window.makeFirstResponder(source)
    }
    private func conversationSnapshot() -> Conversation? {
        guard let s = session else { return nil }
        return Conversation(id:currentConversationID,messages:s.agent.messages,directory:s.agent.directory,provider:s.agent.provider,draft:s.draft,reference:s.editorReference)
    }
    private func rememberConversation() {
        guard let snapshot = conversationSnapshot(), !snapshot.messages.isEmpty || !snapshot.draft.isEmpty || !snapshot.reference.isEmpty else { return }
        conversations.removeAll { $0.id == snapshot.id }; conversations.insert(snapshot,at:0)
        if conversations.count > 7 { conversations.removeLast(conversations.count-7) }
    }
    private var conversationListSignature = ""
    private func updateConversationList() {
        guard let current = conversationSnapshot() else { return }
        let values = [current]+conversations.filter { $0.id != current.id }
        chatTitle.stringValue = current.title.isEmpty ? "新对话" : current.title
        let signature = values.map { $0.id.uuidString+$0.title }.joined(separator:"|")+String(hasPendingInput)
        guard signature != conversationListSignature else { return }; conversationListSignature = signature
        for view in conversationList.arrangedSubviews { conversationList.removeArrangedSubview(view); view.removeFromSuperview() }
        for item in values {
            let button = WorkspaceButton(item.title.isEmpty ? "新对话" : item.title,symbol:"bubble.left",target:self,action:#selector(selectConversation(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString); button.state = item.id == current.id ? .on : .off
            button.isEnabled = !hasPendingInput; button.alignment = .left; button.toolTip = item.title
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            WorkspaceStyle.fillWidth(button,in:conversationList)
        }
        conversationScroll.documentView?.setFrameSize(NSSize(width:max(1,conversationScroll.contentSize.width),height:CGFloat(values.count*35-5)))
    }
    @objc private func selectConversation(_ sender:NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString:raw) else { return }
        switchConversation(id)
    }
    func switchConversation(_ id:UUID) {
        guard !hasPendingInput, let s = session, id != currentConversationID, let target = conversations.first(where:{$0.id == id}) else { return }
        switchingConversation = true; s.agent.stop(); rememberConversation(); conversations.removeAll { $0.id == id }
        currentConversationID = target.id; s.agent.restore(target.messages,directory:target.directory,provider:target.provider)
        s.setEditorReference(target.reference); s.replaceEditorText(target.draft,selection:NSRange(location:target.draft.utf16.count,length:0))
        referenceToggle.state = target.reference.isEmpty ? .off : .on
        history.removeAllActions(); auxiliaryHistory.values.forEach { $0.removeAllActions() }
        previousDraft = target.draft; previousSelection = s.draftSelection
        switchingConversation = false; message = nil; transcript.resetConversation(); refresh(); window.makeFirstResponder(source)
    }
    @objc func continueConversation() {
        guard !hasPendingInput, let s = session else { return }
        message = nil; s.agent.resume(configuration:s.configuration(),readKey:s.readKey)
    }
    @objc private func chooseDirectory() {
        guard session?.agent.isRunning == false else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "使用此目录"; panel.message = "问问 AI 的文件操作与命令将从此目录开始。"
        panel.directoryURL = URL(fileURLWithPath:session?.agent.directory ?? NSHomeDirectory())
        panel.beginSheetModal(for:window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.session?.agent.setDirectory(url.path) }
        }
    }
    @objc private func changeLanguage() {
        let state = editingSession(for:window.firstResponder as? DraftTextView ?? source)
        state?.setASCIIMode(!(state?.asciiMode ?? false))
    }
    @objc private func changeStyle() {
        guard !hasPendingInput else { informPending(); return }
        let index = style.indexOfSelectedItem
        session?.setEditorInstruction(index == 0 ? nil : ModelConfiguration.presets[index-1].1)
    }
    func selectMode(_ mode:EditorAIMode) {
        guard !hasPendingInput, let s = session else { informPending(); return }
        modeHistory[s.editorMode] = history
        restoring = true; s.setEditorMode(mode); restoring = false
        history = modeHistory[mode] ?? UndoManager(); history.levelsOfUndo = 100
        previousDraft = s.draft; previousSelection = s.draftSelection
        referenceToggle.state = s.editorReference.isEmpty ? .off : .on
        versions.removeAllItems(); message = nil; shiftTap.reset()
        window.makeFirstResponder(source); refresh()
    }
    @objc private func changeMode() { selectMode(EditorAIMode(rawValue:modes.selectedSegment) ?? .transform) }
    func openQuestion() {
        guard let s = session, !hasPendingInput else { informPending(); return }
        let text = s.draft
        selectMode(.ask)
        if s.draft.isEmpty && !text.isEmpty { s.replaceEditorText(text,selection:NSRange(location:text.utf16.count,length:0)) }
    }
    func openQuestionFromMenu() {
        if session == nil {
            do {
                let state = CompositionSession(engine:try PinyinEngine(layout:ConfigurationStore.shared.pinyinLayout),translateEnabled:false)
                state.beginEditor()
                prepareSession(state)
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法打开问问 AI"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
        openQuestion()
        show()
    }
    @objc func restoreLastContent() {
        guard let s = session, let archive = lastArchive, !hasPendingInput, !s.isTranslating, !s.agent.isRunning else { return }
        guard s.agent.messages.isEmpty, s.editorArchive.drafts.values.allSatisfy({ $0.text.isEmpty && $0.reference.isEmpty && $0.followUp.isEmpty }) else {
            message = "当前还有草稿，请先保留或清空，再取用上次内容。"; refresh(); return
        }
        restoring = true; s.restoreArchive(archive); restoring = false
        history.removeAllActions(); modeHistory = [:]; reloadActions(); versions.removeAllItems()
        referenceToggle.state = s.editorReference.isEmpty ? .off : .on
        message = "已恢复上次内容；可继续追问或再选择一部分上屏。"; refresh()
    }
    private func reloadActions() {
        actionPicker.removeAllItems()
        let query = actionSearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"/",with:"").lowercased()
        for action in ConfigurationStore.shared.actions where query.isEmpty || action.name.lowercased().contains(query) || action.key.lowercased().contains(query) {
            actionPicker.addItem(withTitle:action.name + (action.key.isEmpty ? "" : "  /" + action.key))
            actionPicker.lastItem?.representedObject = action.id
        }
        if let id = session?.editorAction.id, let item = actionPicker.itemArray.first(where: { $0.representedObject as? String == id }) { actionPicker.select(item) }
    }
    @objc private func searchActions() { reloadActions() }
    @objc private func changeAction() {
        guard !hasPendingInput else { reloadActions(); informPending(); return }
        if let id = actionPicker.selectedItem?.representedObject as? String, let action = ConfigurationStore.shared.actions.first(where:{$0.id == id}) {
            message = nil; session?.setEditorAction(action)
            actionSearch.stringValue = ""; reloadActions()
        }
    }
    @objc private func newAction() { showActionEditor(nil) }
    @objc private func editAction() { showActionEditor(session?.editorAction) }
    private func showActionEditor(_ action:AIAction?) {
        guard !hasPendingInput else { informPending(); return }
        actionEditor = AIActionWindow(action:action) { [weak self] value in
            guard let self else { return }
            if let value { self.session?.setEditorAction(value) }
            else if let current = self.session?.editorAction, !ConfigurationStore.shared.actions.contains(where:{$0.id == current.id}) { self.session?.setEditorAction(AIAction.presets[0]) }
            self.reloadActions(); self.refresh()
        }
        actionEditor?.show(parent:window)
    }
    @objc private func toggleReference() {
        if editingSession(for:reference)?.hasPendingInput == true { referenceToggle.state = .on; informPending(); return }
        refresh(); if referenceToggle.state == .on { window.makeFirstResponder(reference) }
    }
    @objc private func changeVersion() {
        guard !hasPendingInput else { informPending(); return }
        session?.selectAnswer(versions.indexOfSelectedItem)
    }
    @objc private func configurationChanged() { session?.configurationChanged() }
    @objc private func actionsChanged() {
        session?.refreshEditorAction(); reloadActions(); refresh()
    }
    @objc private func layoutChanged() {
        do {
            try session?.requestPinyinLayout(ConfigurationStore.shared.pinyinLayout)
            for state in auxiliary.values { try state.requestPinyinLayout(ConfigurationStore.shared.pinyinLayout) }
        } catch { message = error.localizedDescription; refresh() }
    }
    @objc private func settings() { SettingsWindow.shared.show() }
    @objc private func clearDraft() {
        guard let s = session, !s.hasPendingInput else { informPending(); return }
        s.replaceEditorText("",selection:NSRange(location:0,length:0)); window.makeFirstResponder(source)
    }
    @objc private func undoDraft() {
        guard !hasPendingInput else { informPending(); return }
        editingUndoManager(for:window.firstResponder as? DraftTextView ?? source)?.undo()
    }
    @objc private func pasteDraft() { window.makeFirstResponder(source); source.paste(nil) }
    @objc private func copySource() { copy(session?.draft ?? "") }
    @objc func copyResult() {
        guard !hasPendingInput, session?.isTranslating == false, session?.agent.isRunning == false else { return }
        if session?.editorMode == .ask { copy(selectedResult ?? ""); return }
        let text = result.string as NSString, range = result.selectedRange()
        copy(range.length > 0 && NSMaxRange(range) <= text.length ? text.substring(with:range) : text as String)
    }
    private func copy(_ value:String) { guard !value.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string) }
    func informPending() { message = "请先完成选词，输入内容仍保留。"; refresh() }
    func textDidChange(_ notification:Notification) {
        guard !rendering, let view = notification.object as? DraftTextView, let state = editingSession(for:view) else { return }
        message = nil; state.replaceEditorText(view.string,selection:view.selectedRange())
    }
    func textViewDidChangeSelection(_ notification:Notification) {
        guard !rendering, let view = notification.object as? DraftTextView, let state = editingSession(for:view), !state.hasPendingInput else { return }
        state.setDraftSelection(view.selectedRange())
        if view === source { previousSelection = state.draftSelection }
        else { auxiliaryPrevious[ObjectIdentifier(view)] = (state.draft,state.draftSelection) }
        refreshDestination()
        if view === result && view.selectedRange().length == 0 { count.stringValue = "\(session?.draft.count ?? 0) 字  ·  Enter 换行  ·  ⌘V 粘贴  ·  ⌘Enter 上屏" }
    }
    func textView(_ textView:NSTextView,shouldChangeTextIn affectedCharRange:NSRange,replacementString:String?) -> Bool {
        if let view = textView as? DraftTextView, editingSession(for:view)?.hasPendingInput == true { informPending(); return false }
        return true
    }
    func textView(_ textView:NSTextView,willChangeSelectionFromCharacterRange oldSelectedCharRange:NSRange,toCharacterRange newSelectedCharRange:NSRange) -> NSRange {
        if !rendering, let view = textView as? DraftTextView, editingSession(for:view)?.hasPendingInput == true { return oldSelectedCharRange }
        return newSelectedCharRange
    }
    func flagsChanged(_ event:NSEvent) {
        let flags = event.modifierFlags
        let other = !flags.intersection([.command,.control,.option,.capsLock]).isEmpty
        if shiftTap.flagsChanged(shift:flags.contains(.shift),otherModifier:other,keyCode:event.keyCode,timestamp:event.timestamp) { changeLanguage() }
    }
    func handleKey(_ event:NSEvent,in view:DraftTextView) -> Bool {
        guard let s = editingSession(for:view) else { return false }
        shiftTap.keyDown()
        message = nil
        let flags = event.modifierFlags.intersection([.control,.shift,.command,.option])
        if handleCommitShortcut(event) { return true }
        if ConfigurationStore.shared.editorShortcut.matches(event) { return true }
        if flags == [.control] && [36,76].contains(event.keyCode) { requestTranslation(); return true }
        if flags.isEmpty && event.keyCode == 53 {
            if s.hasPendingInput { s.discardPendingInput() } else { hide() }
            return true
        }
        guard view.isEditable else { return false }
        if !s.hasPendingInput { s.setDraftSelection(view.selectedRange()) }
        if !flags.intersection([.command,.control,.option]).isEmpty { return false }
        if !s.hasPendingInput && [51,117,123,124,125,126,115,119,116,121].contains(event.keyCode) { return false }
        if !s.hasPendingInput && event.keyCode == 48 { s.insertEditorText("\t"); return true }
        let key = InputKey.value(event)
        guard let key else { return false }
        if s.translation != nil { s.cancelTranslation() }
        if s.handle(key:key,shift:flags.contains(.shift)) { return true }
        if !s.hasPendingInput, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({$0.value >= 32 && $0.value < 0xf700}) {
            s.insertEditorText(chars); return true
        }
        return s.hasPendingInput
    }
    private static var paragraphStyle: NSParagraphStyle { let style = NSMutableParagraphStyle(); style.lineSpacing = 6; return style }
    @objc private func toggleWorkspaceAppearance() { WorkspaceStyle.toggleAppearance(for:window) }
    @objc private func workspaceAppearanceChanged() { window.appearance = WorkspaceStyle.appearance; refresh() }
    @objc private func zoomWorkspace() { window.zoom(nil) }
    @objc private func useSuggestion(_ sender:NSButton) {
        guard !hasPendingInput, let s = session else { informPending(); return }
        let prompts = ["整理成待办":"帮我把下面的想法整理成一份行动清单：\n", "帮我写回复":"帮我写一封自然、简洁的回复：\n", "解释代码":"请解释下面代码的思路、输入输出和注意事项：\n"]
        let text = prompts[sender.title] ?? sender.title
        s.replaceEditorText(text,selection:NSRange(location:text.utf16.count,length:0)); window.makeFirstResponder(source)
    }
    private func build() {
        window = DraftEditorPanel(contentRect:NSRect(x:0,y:0,width:1060,height:720),styleMask:[.titled,.closable,.resizable,.nonactivatingPanel],backing:.buffered,defer:false)
        window.owner = self; window.delegate = self; window.title = "方寸 · 问问 AI"
        window.isReleasedWhenClosed = false; window.isFloatingPanel = true; window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false; window.level = .floating; window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window.minSize = NSSize(width:820,height:600); window.appearance = WorkspaceStyle.appearance
        window.backgroundColor = WorkspaceStyle.soft; window.setFrameAutosaveName("FangCunDraftEditor"); window.center()
        NotificationCenter.default.addObserver(self,selector:#selector(configurationChanged),name:.modelConfigurationChanged,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(actionsChanged),name:.aiActionsChanged,object:ConfigurationStore.shared)
        NotificationCenter.default.addObserver(self,selector:#selector(layoutChanged),name:.pinyinLayoutChanged,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(workspaceAppearanceChanged),name:WorkspaceStyle.themeChanged,object:nil)
        history.levelsOfUndo = 100
        let backdrop = WorkspaceSurface(); window.contentView = backdrop
        let root = WorkspaceStyle.column(); backdrop.addSubview(root); WorkspaceStyle.pin(root,to:backdrop)
        func full(_ view:NSView,in parent:NSStackView) { WorkspaceStyle.fillWidth(view,in:parent,inset:parent.edgeInsets.left+parent.edgeInsets.right) }
        func row() -> NSStackView { WorkspaceStyle.row() }
        func button(_ b:NSButton,_ title:String,_ action:Selector) { b.title = title; b.target = self; b.action = action; b.font = .systemFont(ofSize:12) }
        func makeButton(_ title:String,_ action:Selector,_ symbol:String? = nil) -> WorkspaceButton { WorkspaceButton(title,symbol:symbol,target:self,action:action) }
        func separator(in stack:NSStackView) { let line = NSBox(); line.boxType = .separator; full(line,in:stack) }
        let header = row(); header.edgeInsets = NSEdgeInsets(top:9,left:22,bottom:9,right:18)
        let mark = NSImageView(image:WorkspaceStyle.symbol("command")!); mark.contentTintColor = WorkspaceStyle.accent
        header.addArrangedSubview(mark); header.addArrangedSubview(workspaceTitle); header.addArrangedSubview(WorkspaceStyle.label("方寸",size:11,color:WorkspaceStyle.subtle)); header.addArrangedSubview(WorkspaceStyle.spacer())
        modes.target = self; modes.action = #selector(changeMode); modes.selectedSegment = 0; modes.segmentStyle = .rounded; modes.font = .systemFont(ofSize:11)
        modes.selectedSegmentBezelColor = WorkspaceStyle.accent
        header.addArrangedSubview(modes)
        button(restoreLast,"上次内容",#selector(restoreLastContent)); header.addArrangedSubview(restoreLast)
        let theme = makeButton("",#selector(toggleWorkspaceAppearance),"moon"); theme.toolTip = "切换浅色或深色外观"; theme.setAccessibilityLabel("切换浅色或深色外观"); header.addArrangedSubview(theme)
        let settingsButton = makeButton("",#selector(settings),"slider.horizontal.3"); settingsButton.setAccessibilityLabel("模型设置"); settingsButton.toolTip = "模型设置"; header.addArrangedSubview(settingsButton)
        let zoom = makeButton("",#selector(zoomWorkspace),"arrow.up.left.and.arrow.down.right"); zoom.setAccessibilityLabel("放大窗口"); header.addArrangedSubview(zoom)
        header.heightAnchor.constraint(equalToConstant:48).isActive = true
        full(header,in:root); separator(in:root)
        let body = row(); body.spacing = 1; body.alignment = .top
        let sidebar = WorkspaceSurface(WorkspaceStyle.sidebar); chatSidebar = sidebar; sidebar.widthAnchor.constraint(equalToConstant:184).isActive = true
        let side = WorkspaceStyle.column(spacing:8); side.edgeInsets = NSEdgeInsets(top:18,left:12,bottom:16,right:12)
        sidebar.addSubview(side); WorkspaceStyle.pin(side,to:sidebar)
        button(newChat,"新对话",#selector(startNewConversation)); full(newChat,in:side)
        let recent = WorkspaceStyle.label("本次使用",size:10,color:WorkspaceStyle.subtle); full(recent,in:side)
        side.setCustomSpacing(18,after:newChat)
        conversationScroll.hasVerticalScroller = true; conversationScroll.autohidesScrollers = true; conversationScroll.borderType = .noBorder; conversationScroll.drawsBackground = false
        conversationScroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        conversationScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:90).isActive = true
        let historyDocument = WorkspaceFlippedView(frame:NSRect(x:0,y:0,width:160,height:30)); historyDocument.autoresizingMask = [.width]
        conversationScroll.documentView = historyDocument; historyDocument.addSubview(conversationList); WorkspaceStyle.pin(conversationList,to:historyDocument)
        full(conversationScroll,in:side)
        separator(in:side); full(WorkspaceStyle.label("工作目录",size:10,color:WorkspaceStyle.subtle),in:side)
        button(directoryButton,"工作目录",#selector(chooseDirectory)); directoryButton.alignment = .left
        (directoryButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        full(directoryButton,in:side); full(WorkspaceStyle.label("文件与命令从这里开始",size:10,color:WorkspaceStyle.subtle),in:side)
        body.addArrangedSubview(sidebar)
        let main = WorkspaceStyle.column(); body.addArrangedSubview(main)
        mainWidth = main.widthAnchor.constraint(equalTo:body.widthAnchor); mainWidth.isActive = true
        sidebar.heightAnchor.constraint(equalTo:body.heightAnchor).isActive = true; main.heightAnchor.constraint(equalTo:body.heightAnchor).isActive = true
        let chatTop = row(); chatTop.heightAnchor.constraint(equalToConstant:54).isActive = true; chatTop.edgeInsets = NSEdgeInsets(top:12,left:24,bottom:12,right:20); chatHeader = chatTop
        chatTop.addArrangedSubview(chatTitle); chatTop.addArrangedSubview(WorkspaceStyle.label("问问 AI",size:10,color:WorkspaceStyle.subtle)); chatTop.addArrangedSubview(WorkspaceStyle.spacer())
        button(continueChat,"继续",#selector(continueConversation)); chatTop.addArrangedSubview(continueChat)
        button(copyChat,"复制回答",#selector(copyResult)); chatTop.addArrangedSubview(copyChat); full(chatTop,in:main)
        actionTools = row(); actionTools.heightAnchor.constraint(equalToConstant:48).isActive = true; actionTools.edgeInsets = NSEdgeInsets(top:10,left:20,bottom:6,right:20)
        actionPicker.target = self; actionPicker.action = #selector(changeAction); actionPicker.widthAnchor.constraint(lessThanOrEqualToConstant:260).isActive = true
        actionPicker.toolTip = "选择动作；保存和切换不会调用 AI"
        actionSearch.placeholderString = "搜索动作或 /key"; actionSearch.target = self; actionSearch.action = #selector(searchActions); actionSearch.sendsSearchStringImmediately = true
        actionSearch.widthAnchor.constraint(equalToConstant:150).isActive = true; actionTools.addArrangedSubview(actionSearch); actionTools.addArrangedSubview(actionPicker)
        actionTools.addArrangedSubview(makeButton("编辑指令",#selector(editAction))); actionTools.addArrangedSubview(makeButton("自定义",#selector(newAction),"plus")); actionTools.addArrangedSubview(WorkspaceStyle.spacer()); full(actionTools,in:main)
        let tools = row(); tools.heightAnchor.constraint(equalToConstant:38).isActive = true; tools.edgeInsets = NSEdgeInsets(top:0,left:20,bottom:6,right:20); transformTools = tools
        tools.addArrangedSubview(makeButton("粘贴",#selector(pasteDraft),"doc.on.clipboard")); tools.addArrangedSubview(makeButton("清空",#selector(clearDraft))); tools.addArrangedSubview(makeButton("撤销",#selector(undoDraft),"arrow.uturn.backward")); tools.addArrangedSubview(WorkspaceStyle.spacer())
        style.addItems(withTitles:["使用已配置的指令"]+ModelConfiguration.presets.map(\.0)); style.target = self; style.action = #selector(changeStyle); style.toolTip = "本段翻译风格；不会自动请求模型"; tools.addArrangedSubview(style)
        tools.addArrangedSubview(makeButton("缩小",#selector(collapse),"arrow.down.right.and.arrow.up.left")); full(tools,in:main)
        panes = row(); panes.alignment = .top; panes.distribution = .fillEqually; panes.spacing = 18; panes.edgeInsets = NSEdgeInsets(top:0,left:22,bottom:8,right:22)
        func scroll(_ text:DraftTextView) -> NSScrollView {
            let view = NSScrollView(); view.hasVerticalScroller = true; view.autohidesScrollers = true; view.borderType = .noBorder; view.drawsBackground = false
            text.owner = self; text.delegate = self; text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
            text.defaultParagraphStyle = Self.paragraphStyle; text.backgroundColor = WorkspaceStyle.surface; text.textColor = WorkspaceStyle.ink; text.insertionPointColor = WorkspaceStyle.accent
            text.selectedTextAttributes = [.backgroundColor:WorkspaceStyle.tint,.foregroundColor:WorkspaceStyle.ink]
            text.allowsUndo = false; text.font = .systemFont(ofSize:15); text.textContainerInset = NSSize(width:10,height:12)
            text.minSize = .zero; text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            view.setContentHuggingPriority(.defaultLow,for:.vertical); view.documentView = text; return view
        }
        func pane(_ title:String,_ text:DraftTextView,minimum:CGFloat) -> NSStackView {
            let box = WorkspaceStyle.column(spacing:5)
            let label = text === result ? resultTitle : WorkspaceStyle.label(title,size:11)
            label.font = .systemFont(ofSize:11,weight:.medium); label.textColor = WorkspaceStyle.muted
            full(label,in:box); let scroller = scroll(text); text.setAccessibilityLabel(title); full(scroller,in:box)
            scroller.heightAnchor.constraint(greaterThanOrEqualToConstant:minimum).isActive = true
            return box
        }
        let sourcePane = WorkspaceStyle.column(spacing:8)
        transcript.heightAnchor.constraint(greaterThanOrEqualToConstant:150).isActive = true
        transcript.setContentHuggingPriority(.defaultLow,for:.vertical); full(transcript,in:sourcePane)
        transcript.onSelectionChanged = { [weak self] in guard self?.rendering == false else { return }; self?.refreshDestination() }
        transcript.onCopyAnswer = { [weak self] text in self?.copy(text) }
        transcript.onInsertAnswer = { [weak self] text in guard let self, self.session?.agent.isRunning == false else { return }; self.commit(text) }
        referenceToggle.target = self; referenceToggle.action = #selector(toggleReference); referenceToggle.setButtonType(.pushOnPushOff); referenceToggle.toolTip = "展开参考文字；内容随下一条消息发送"
        referencePane = pane("参考文字 · 可选",reference,minimum:55); full(referencePane,in:sourcePane); referencePane.heightAnchor.constraint(equalToConstant:100).isActive = true
        chatTools.orientation = .horizontal; chatTools.spacing = 8; chatTools.heightAnchor.constraint(equalToConstant:30).isActive = true
        for title in ["整理成待办","帮我写回复","解释代码"] { chatTools.addArrangedSubview(makeButton(title,#selector(useSuggestion(_:)))) }
        chatTools.addArrangedSubview(WorkspaceStyle.spacer()); full(chatTools,in:sourcePane)
        let composer = WorkspaceSurface(WorkspaceStyle.surface,stroke:WorkspaceStyle.line,radius:10)
        composer.setContentHuggingPriority(.defaultHigh,for:.vertical)
        sourceCardHeight = composer.heightAnchor.constraint(equalTo:sourcePane.heightAnchor)
        let inputStack = WorkspaceStyle.column(spacing:0); composer.addSubview(inputStack); WorkspaceStyle.pin(inputStack,to:composer,insets:NSEdgeInsets(top:2,left:8,bottom:5,right:8))
        let heading = row(); heading.heightAnchor.constraint(equalToConstant:38).isActive = true; sourceHeading = heading; heading.edgeInsets = NSEdgeInsets(top:8,left:8,bottom:0,right:8)
        sourceTitle.font = .systemFont(ofSize:11,weight:.medium); sourceTitle.textColor = WorkspaceStyle.muted
        heading.addArrangedSubview(sourceTitle); heading.addArrangedSubview(WorkspaceStyle.spacer()); heading.addArrangedSubview(makeButton("复制",#selector(copySource),"doc.on.doc")); full(heading,in:inputStack)
        let sourceScroll = scroll(source); full(sourceScroll,in:inputStack)
        sourceHeight = sourceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:75); sourceHeight.isActive = true
        let preferred = sourceScroll.heightAnchor.constraint(equalToConstant:88); preferred.priority = .defaultHigh; preferred.isActive = true
        let controls = row(); controls.heightAnchor.constraint(equalToConstant:36).isActive = true; controls.edgeInsets = NSEdgeInsets(top:2,left:3,bottom:2,right:3)
        controls.addArrangedSubview(referenceToggle); controls.addArrangedSubview(WorkspaceStyle.spacer())
        button(language,"中 ⇧",#selector(changeLanguage)); controls.addArrangedSubview(language)
        button(translate,"发送 ⌃↵",#selector(requestTranslation)); button(cancel,"停止",#selector(stopTranslation)); controls.addArrangedSubview(translate); controls.addArrangedSubview(cancel)
        full(controls,in:inputStack); full(composer,in:sourcePane)
        let resultBox = pane("结果 · 可修改",result,minimum:130); resultPane = resultBox
        let resultTools = row(); versions.target = self; versions.action = #selector(changeVersion); versions.widthAnchor.constraint(lessThanOrEqualToConstant:160).isActive = true
        resultTools.addArrangedSubview(versions); resultTools.addArrangedSubview(WorkspaceStyle.spacer()); button(copyAnswer,"复制",#selector(copyResult)); resultTools.addArrangedSubview(copyAnswer)
        resultBox.insertArrangedSubview(resultTools,at:1); resultTools.widthAnchor.constraint(equalTo:resultBox.widthAnchor).isActive = true
        let followBox = pane("继续追问 · ⌃Enter 发送",followUp,minimum:45); followUpPane = followBox
        let followRow = row(); followRow.addArrangedSubview(WorkspaceStyle.spacer()); button(sendFollowUp,"追问 ⌃↵",#selector(requestFollowUp)); followRow.addArrangedSubview(sendFollowUp)
        full(followRow,in:followBox); full(followBox,in:resultBox); followBox.heightAnchor.constraint(equalToConstant:120).isActive = true
        panes.addArrangedSubview(sourcePane); panes.addArrangedSubview(resultBox); full(panes,in:main)
        sourcePane.heightAnchor.constraint(equalTo:panes.heightAnchor,constant:-8).isActive = true; resultBox.heightAnchor.constraint(equalTo:panes.heightAnchor,constant:-8).isActive = true
        let meta = row(); meta.heightAnchor.constraint(equalToConstant:20).isActive = true; meta.edgeInsets = NSEdgeInsets(top:0,left:25,bottom:2,right:25)
        count.font = .systemFont(ofSize:10); count.textColor = WorkspaceStyle.muted; meta.addArrangedSubview(count); meta.addArrangedSubview(WorkspaceStyle.spacer()); full(meta,in:main)
        status.font = .systemFont(ofSize:10); status.textColor = WorkspaceStyle.muted; status.setContentCompressionResistancePriority(.required,for:.vertical)
        let statusRow = row(); statusRow.heightAnchor.constraint(equalToConstant:28).isActive = true; statusRow.edgeInsets = NSEdgeInsets(top:1,left:25,bottom:5,right:25); statusRow.addArrangedSubview(status); full(statusRow,in:main)
        separator(in:main)
        let footer = row(); footer.heightAnchor.constraint(equalToConstant:46).isActive = true; footer.edgeInsets = NSEdgeInsets(top:6,left:22,bottom:8,right:20)
        destinationLabel.font = .systemFont(ofSize:10); destinationLabel.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        footer.addArrangedSubview(destinationLabel); button(recover,"重新绑定光标",#selector(recoverDestination)); footer.addArrangedSubview(recover); footer.addArrangedSubview(WorkspaceStyle.spacer())
        button(insertSource,"原文上屏",#selector(commitSource)); button(insertResult,"插入回答 ⌘↵",#selector(commitResult)); footer.addArrangedSubview(insertSource); footer.addArrangedSubview(insertResult); full(footer,in:main)
        full(body,in:root)
    }
    func capture(to url:URL) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        let view = window.contentView!
        let image = NSImage(data:view.dataWithPDF(inside:view.bounds))!
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width*2),pixelsHigh:Int(view.bounds.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x:2,y:2)
        window.backgroundColor.setFill(); view.bounds.fill()
        image.draw(in:view.bounds,from:.zero,operation:.sourceOver,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using:.png,properties:[:])!.write(to:url)
    }
}

@MainActor
final class DraftEditorPanel: NSPanel {
    weak var owner: DraftEditor?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.control,.shift,.option])
        if owner?.handleCommitShortcut(event) == true { return true }
        if ConfigurationStore.shared.editorShortcut.matches(event) { return true }
        if flags == [.control] && [36,76].contains(event.keyCode) { owner?.requestTranslation(); return true }
        if flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "n", flags == [.command], owner?.session?.editorMode == .ask { owner?.startNewConversation(); return true }
            if key == "w" && flags == [.command] { owner?.hide(); return true }
            if key == "z" && (flags == [.command] || flags == [.command,.shift]) {
                guard owner?.hasPendingInput == false else { owner?.informPending(); return true }
                let manager = (firstResponder as? DraftTextView).flatMap { owner?.editingUndoManager(for:$0) } ?? firstResponder?.undoManager
                if flags.contains(.shift) { manager?.redo() } else { manager?.undo() }; return true
            }
            if flags == [.command], let action = ["v":#selector(NSText.paste(_:)),"c":#selector(NSText.copy(_:)),"x":#selector(NSText.cut(_:)),"a":#selector(NSText.selectAll(_:))][key] {
                return NSApp.sendAction(action,to:firstResponder,from:self)
            }
        }
        return super.performKeyEquivalent(with:event)
    }
}

@MainActor
protocol DraftTextOwner: AnyObject {
    func refresh()
    func flagsChanged(_ event:NSEvent)
    func handleKey(_ event:NSEvent,in view:DraftTextView) -> Bool
    func editingSession(for view:DraftTextView) -> CompositionSession?
    func informPending()
}

@MainActor
final class DraftTextView: NSTextView {
    weak var owner: (any DraftTextOwner)?
    var placeholder: String? { didSet { if oldValue != placeholder { needsDisplay = true } } }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder {
            (placeholder as NSString).draw(at:textContainerOrigin,withAttributes:[.font:font ?? NSFont.systemFont(ofSize:15),.foregroundColor:WorkspaceStyle.subtle])
        }
    }
    // Feed the shared Rime session directly; never recursively start our IMK
    // server for its own editor. AppKit still supplies editing/selection/clipboard.
    override var inputContext: NSTextInputContext? { nil }
    // NSTextStorage still records native undo when a manager is returned,
    // even with allowsUndo=false. Our Rime rendering replaces whole strings,
    // so native range-based undo must never share the snapshot undo stack.
    override var undoManager: UndoManager? { nil }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.owner?.refresh() } }
        return accepted
    }
    override func flagsChanged(with event:NSEvent) { owner?.flagsChanged(event) }
    override func keyDown(with event:NSEvent) {
        if owner?.handleKey(event,in:self) == true { return }
        interpretKeyEvents([event])
    }
    override func paste(_ sender:Any?) {
        if owner?.editingSession(for:self)?.hasPendingInput == true { owner?.informPending(); return }
        guard let value = NSPasteboard.general.string(forType:.string) else { return }
        insertText(value,replacementRange:selectedRange())
    }
}

extension CompositionSession {
    func cancelTranslationIfWorking() { if isTranslating || agent.isRunning { stopEditorRequest() } }
}
