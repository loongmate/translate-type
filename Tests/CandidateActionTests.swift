import AppKit
import InputMethodKit

@main struct CandidateActionTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunCandidateActions-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        let domain = "FangCunCandidateActions-"+UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!, store = ConfigurationStore(defaults:defaults)
        defer { defaults.removePersistentDomain(forName:domain); try? FileManager.default.removeItem(at:user) }
        var checks = 0
        func check(_ value:Bool,_ label:String) { if !value { print("FAIL:",label); exit(1) }; checks += 1; print("PASS:",label) }
        func records() async throws -> [[String:Any]] {
            let (data,_) = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:18887/records")!)
            return (try JSONSerialization.jsonObject(with:data) as! [String:Any])["requests"] as! [[String:Any]]
        }
        func messages() async throws -> [[String:String]] { try await records().last!["messages"] as! [[String:String]] }
        func settle(_ state:CompositionSession) async throws {
            for _ in 0..<100 { if !state.isTranslating { return }; try await Task.sleep(nanoseconds:30_000_000) }
            check(false,"模型请求完成")
        }
        let english = store.actions.first { $0.id == "english" }!
        let polish = store.actions.first { $0.id == "polish-english" }!
        let answer = store.actions.first { $0.id == "answer" }!
        check(store.candidateAction == english && english.candidateLabel == "译英","旧配置缺省仍使用译英")
        store.selectedActionID = "german"; store.candidateActionID = polish.id
        check(ConfigurationStore(defaults:defaults).candidateAction == polish && store.selectedActionID == "german","候选动作持久保存，与弹出编辑区动作独立")
        let s = CompositionSession(engine:try PinyinEngine(),translateEnabled:true,store:store)
        var output = "", keyReads = 0
        s.onInsert = { output += $0 }
        s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887",model:"candidate-test",instruction:"ONLY TRANSLATION preference") }
        s.readKey = { _ in keyReads += 1; return "synthetic-key" }
        func type(_ text:String) { for c in text.unicodeScalars { s.handle(key:Int(c.value)) } }
        s.setASCIIMode(true); type("He go to school yesterday.")
        check(s.draft == "He go to school yesterday." && output.isEmpty && keyReads == 0,"英文和标点全部留在草稿，打字不调用模型")
        s.handle(key:0xff0d,control:true); s.requestTranslation(); try await settle(s)
        var sent = try await messages()
        check(try await records().count == 1 && sent[0]["content"] == polish.prompt && !sent[0]["content"]!.contains("ONLY TRANSLATION"),"英语润色使用独立指令，重复触发只发一次")
        check(sent[1]["content"] == s.draft && s.translation == "Hello.","英文原文完整发送，结果进入候选")
        s.handle(key:0xff1b); s.requestTranslation()
        check(!s.isTranslating && keyReads == 1 && s.translation == "Hello.","相同草稿和动作可复用结果")
        s.setCandidateAction(answer)
        check(s.translation == nil && s.draft == "He go to school yesterday." && output.isEmpty,"切换动作清除旧结果，保留草稿且不上屏")
        s.requestTranslation(); try await settle(s); sent = try await messages()
        check(keyReads == 2 && sent[0]["content"] == answer.prompt,"不同动作不复用润色缓存")
        s.handle(key:0xff0d)
        check(output == "Hello." && s.draft.isEmpty,"Enter 只将结果上屏，不拼接原文或问题")
        output = ""; s.setASCIIMode(false); type("nihao")
        let pending = s.snapshot
        s.setCandidateAction(polish); s.requestTranslation()
        check(s.snapshot.input == pending.input && s.snapshot.caret == pending.caret && s.hasPendingInput && keyReads == 2,"待选拼音切换动作不丢输入，未完成选词不发请求")
        s.handle(key:32)
        s.setCandidateAction(answer); s.requestTranslation(); try await settle(s)
        check(try await messages()[1]["content"] == "你好","问答动作也支持中文选词后的问题")
        s.handle(key:0xff1b)
        let custom = AIAction(name:"我的英语语法优化",key:"grammar",prompt:"Fix English grammar. Return only the corrected sentence.")
        try store.saveAction(custom); s.setCandidateAction(custom); s.requestTranslation(); try await settle(s)
        check(try await messages()[0]["content"] == custom.prompt && s.candidateAction.candidateLabel == custom.name,"自定义名称显示在候选入口，指令原样发送")
        var changed = custom; changed.prompt = "Answer the question. Return only the answer."
        try store.saveAction(changed); s.refreshCandidateAction()
        check(s.translation == nil && s.draft == "你好" && s.candidateAction == changed,"编辑已选动作后结果失效，草稿保留")
        s.requestTranslation(); try await settle(s)
        check(try await messages()[0]["content"] == changed.prompt,"编辑后重新请求使用新指令")
        s.handle(key:0xff1b); type("nihao"); s.handle(key:32)
        s.requestTranslation(); try await Task.sleep(nanoseconds:60_000_000); s.setCandidateAction(english)
        try await Task.sleep(nanoseconds:300_000_000)
        check(!s.isTranslating && s.translation == nil && s.draft == "你好你好","切换动作取消进行中请求，迟到响应不会覆盖草稿")
        s.requestTranslation(); try await settle(s)
        check(try await messages()[0]["content"]!.contains("ONLY TRANSLATION preference"),"译英仍兼容原来的翻译偏好")
        store.candidateActionID = changed.id; s.refreshCandidateAction()
        store.customActions = []; s.refreshCandidateAction()
        check(s.candidateAction == english && s.translation == nil && s.draft == "你好你好","删除正在使用的动作自动回退译英，保留输入")
        store.candidateActionID = "unknown"
        check(store.candidateAction == english,"失效动作 ID 安全回退译英")
        s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/error",model:"candidate-test") }
        s.setCandidateAction(answer); s.requestTranslation(); try await settle(s)
        check(s.errorMessage?.contains("限流") == true && s.draft == "你好你好" && output.isEmpty,"失败保留原文，不自动上屏或重试")

        // Render real native candidates, including a long user-defined label.
        let long = AIAction(name:String(repeating:"自定义英语语法优化",count:4),key:"long",prompt:"Polish English.")
        try store.saveAction(long); s.setCandidateAction(long)
        let panel = CandidatePanel(), visible = NSScreen.main!.visibleFrame
        panel.show(session:s,anchor:NSRect(x:visible.midX,y:visible.midY,width:1,height:20),expand:{},ask:{},settings:{})
        try await Task.sleep(nanoseconds:100_000_000)
        panel.contentView!.layoutSubtreeIfNeeded()
        check(!panel.canBecomeKey && visible.contains(panel.frame) && panel.frame.width <= 600,"长动作名缩略显示，候选框仍在屏幕内且不抢焦点")
        let view = panel.contentView!, bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(".build/candidate-custom-action.png"))
        panel.orderOut(nil)

        // Exercise the actual settings picker and its shared action editor.
        let shared = ConfigurationStore.shared, oldID = shared.candidateActionID, oldActions = shared.customActions
        let oldModel = shared.model, oldEnabled = shared.translateEnabled, oldLayout = shared.pinyinLayout
        defer {
            shared.customActions = oldActions; shared.candidateActionID = oldID
            shared.model = oldModel; shared.translateEnabled = oldEnabled; shared.pinyinLayout = oldLayout
        }
        shared.candidateActionID = "english"
        SettingsWindow.shared.showCandidateActions()
        let window = NSApp.windows.first { $0.title == "方寸输入法 · 设置" }!
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let settingsViews = descendants(window.contentView!)
        let tabs = settingsViews.first { $0 is NSTabView } as! NSTabView
        check(tabs.selectedTabViewItem?.label == "候选动作","自定义入口直接打开候选动作设置页")
        let picker = settingsViews.compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.contains { $0.representedObject as? String == "answer" } }!
        picker.select(picker.itemArray.first { $0.representedObject as? String == "answer" }!)
        NSApp.sendAction(picker.action!,to:picker.target,from:picker)
        check(shared.candidateActionID == "answer","原生设置选择动作立即保存")
        try SettingsWindow.shared.capture(to:root.appendingPathComponent(".build/candidate-action-settings.png"))
        tabs.selectTabViewItem(at:0)
        try SettingsWindow.shared.capture(to:root.appendingPathComponent(".build/candidate-input-settings.png"))
        tabs.selectTabViewItem(at:2)
        let newButton = descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSButton }.first { $0.title == "＋ 自定义" }!
        newButton.performClick(nil)
        check(window.attachedSheet?.title == "自定义动作","设置可打开共用的自定义动作表单")
        let sheet = window.attachedSheet!, form = descendants(sheet.contentView!)
        let nameField = form.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("动作名称") == true }!
        let keyField = form.compactMap { $0 as? NSTextField }.first { $0.placeholderString?.hasPrefix("可选 key") == true }!
        let promptField = form.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "特殊指令" }!
        nameField.stringValue = "测试英语优化"; keyField.stringValue = "test-"+String(UUID().uuidString.prefix(8)); promptField.string = custom.prompt
        form.compactMap { $0 as? NSButton }.first { $0.title == "保存动作" }!.performClick(nil)
        check(shared.candidateAction.name == "测试英语优化" && shared.actions.contains { $0.id == shared.candidateActionID },"表单保存动作并选用，动作库可供编辑区复用")
        let editButton = descendants(tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSButton }.first { $0.title == "编辑指令" }!
        editButton.performClick(nil)
        descendants(window.attachedSheet!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "删除动作" }!.performClick(nil)
        check(shared.candidateAction.id == "english" && !shared.customActions.contains { $0.name == "测试英语优化" },"原生删除表单正确移除动作并回退译英")
        window.close()

        // Verify notifications and result-only insertion through the real IMK controller.
        shared.model = ModelConfiguration(endpoint:"http://127.0.0.1:18887",model:"controller-action-test",instruction:"translation-only")
        shared.translateEnabled = true; shared.pinyinLayout = .fullPinyin
        let server = IMKServer(name:"FangCunCandidateTests_"+UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        let client = TextClient(), controller = TTInputController(server:server,delegate:nil,client:client)!
        controller.activateServer(client)
        defer { controller.deactivateServer(client) }
        shared.candidateActionID = polish.id
        check(controller.menu().items.contains { $0.title == "英语润色" },"设置变更通知已激活控制器，入口名称立即更新")
        let englishItem = controller.menu().items[1]
        NSApp.sendAction(englishItem.action!,to:englishItem.target,from:englishItem)
        var stamp:TimeInterval = 100
        func key(_ text:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = []) {
            stamp += 0.03
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:stamp,windowNumber:0,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
            _ = controller.handle(event,client:client)
        }
        for c in "He go to school." { key(String(c),c == " " ? 49 : 0) }
        check(client.text.string == "He go to school." && client.text.hasMarkedText(),"实际文本客户端英文仍为预编辑草稿")
        key("\r",36,[.control]); try await Task.sleep(nanoseconds:600_000_000)
        check(try await messages()[0]["content"] == polish.prompt,"实际控制器快捷键执行所选润色指令")
        key("\r",36)
        check(client.text.string == "Hello." && !client.text.hasMarkedText(),"实际 IMK 文本客户端只收到模型结果")
        let actionMenu = controller.menu().items.first { $0.title == "候选框 AI 动作" }!.submenu!
        let answerItem = actionMenu.items.first { $0.representedObject as? String == "answer" }!
        NSApp.sendAction(answerItem.action!,to:answerItem.target,from:answerItem)
        check(shared.candidateActionID == "answer","系统输入法菜单可切换并保存候选动作")
        for c in "What is hello?" { key(String(c),c == " " ? 49 : 0) }
        key("\r",36,[.control]); try await Task.sleep(nanoseconds:600_000_000)
        check(try await messages()[0]["content"] == answer.prompt,"实际控制器问答不继承翻译指令")
        key("\r",36)
        check(client.text.string == "Hello.Hello." && !client.text.hasMarkedText(),"实际问答上屏只插入答案，问题不留在正文")
        print("Candidate action checks: \(checks); mock requests: \(try await records().count)")
    }
}
