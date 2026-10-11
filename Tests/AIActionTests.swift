import AppKit
import InputMethodKit

@main struct AIActionTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunAITests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let settings = ConfigurationStore.shared
        let old = (settings.selectedActionID,settings.customActions,settings.pinyinLayout)
        settings.selectedActionID = "english"; settings.customActions = []; settings.pinyinLayout = .fullPinyin
        defer { settings.customActions = old.1; settings.selectedActionID = old.0; settings.pinyinLayout = old.2 }
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
        func state() throws -> CompositionSession {
            let s = CompositionSession(engine:try PinyinEngine(),translateEnabled:true)
            s.beginEditor(); s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887",model:"mock-model",instruction:"ONLY ENGLISH preference") }; s.readKey = { _ in "synthetic-key" }; return s
        }
        let s = try state()
        check(s.editorMode == .transform && s.editorAction.id == "english","默认第一项改文字，动作英语")
        s.replaceEditorText("周末去海边",selection:NSRange(location:5,length:0))
        check(try await records().isEmpty,"输入文字不调用模型")
        s.requestTranslation(); s.requestTranslation(); try await settle(s)
        var sent = try await messages()
        check(try await records().count == 1 && s.translation == "Hello.","重复快捷键只产生一个进行中请求")
        check(sent.first!["content"]!.contains("ONLY ENGLISH preference"),"英语动作保留已配置的翻译偏好")
        s.setEditorAction(AIAction.presets[1]); check(s.translation == nil,"切换动作旧结果失效")
        s.requestTranslation(); try await settle(s); sent = try await messages()
        check(sent[0]["content"]!.contains("German") && !sent[0]["content"]!.contains("ONLY ENGLISH"),"德语独立指令，没有附加英文翻译规则")
        check(sent[1]["content"] == "周末去海边","原文单独放入 user 消息")
        let custom = AIAction(name:"取订单",key:"order",prompt:"只返回订单号，JSON 格式")
        try settings.saveAction(custom)
        check(settings.customActions == [custom],"自定义名称、key 和指令持久保存")
        do { try settings.saveAction(AIAction(name:"重复",key:"ORDER",prompt:"")); check(false,"重复 key 必须拒绝") } catch { check(true,"key 大小写重复被拒绝") }
        do { try settings.saveAction(AIAction(name:"空格",key:"has space",prompt:"")); check(false,"非法 key 必须拒绝") } catch { check(true,"含空格的 key 被拒绝") }
        s.setEditorAction(custom); s.requestTranslation(); try await settle(s); sent = try await messages()
        check(sent[0]["content"] == custom.prompt && sent.count == 2,"自定义指令不会被翻译模板包裹")
        let blank = AIAction(name:"按要求做",key:"",prompt:"")
        s.setEditorAction(blank); s.requestTranslation(); try await settle(s); sent = try await messages()
        check(sent[0]["content"]!.contains("无明确要求"),"空指令使用通用默认规则")
        s.setEditorAction(custom)
        let remembered = try state(); check(remembered.editorMode == .transform && remembered.editorAction == custom,"新编辑区仍先开改文字，记住所选动作")
        s.setEditorMode(.ask)
        check(s.draft.isEmpty && s.translation == nil,"问答有独立草稿")
        s.replaceEditorText("帮我写邀请",selection:NSRange(location:5,length:0)); s.setEditorReference("周六，下午三点，海边")
        let beforeAsk = try await records().count
        s.requestTranslation(); try await settle(s); sent = try await messages()
        check(sent.count == 3 && sent[0]["content"]!.contains("文字助手") && sent[1]["content"]!.contains("参考文字") && sent[2]["content"] == "帮我写邀请","问答、资料、系统规则分开组装")
        check(!sent[0]["content"]!.contains("Translate"),"问答不继承翻译指令")
        s.editTranslation("编辑后的邀请"); s.setEditorFollowUp("缩成一句话"); s.requestEditorAction(followUp:true); try await settle(s); sent = try await messages()
        check(sent.suffix(2).first!["role"] == "assistant" && sent.suffix(2).first!["content"] == "编辑后的邀请" && sent.last!["content"] == "缩成一句话","追问沿用用户编辑后的回答")
        check(s.answers.count == 2 && s.editorFollowUp.isEmpty,"追问产生新版本并清空已发送追问")
        s.selectAnswer(0); check(s.translation == "编辑后的邀请","可返回旧版本")
        s.setEditorFollowUp("更亲切"); s.requestEditorAction(followUp:true); try await settle(s); sent = try await messages()
        check(sent.count == 5 && sent.last!["content"] == "更亲切" && !sent.contains(where:{$0["content"] == "缩成一句话"}),"从旧版本追问形成正确分支，不混入后续版本")
        s.setEditorMode(.transform); check(s.draft == "周末去海边" && s.editorAction == custom,"切回改文字恢复原草稿和动作")
        s.setEditorMode(.ask); check(s.draft == "帮我写邀请" && s.answers.count == 3,"切回问答保留资料和版本")
        s.setEditorReference("改过的资料"); check(s.translation == nil && s.displayedAnswer != nil,"资料改变后旧结果可看但不可上屏")
        s.selectAnswer(0); check(s.translation == nil,"不能选择旧版本绕过资料失效检查")
        s.requestTranslation(); s.setEditorMode(.transform); try await Task.sleep(nanoseconds:350_000_000)
        check(!s.isTranslating && s.translation == nil && s.draft == "周末去海边","切换模式取消请求，晚到回答不会覆盖另一模式")
        s.setEditorMode(.ask); s.requestTranslation(); try await settle(s)
        s.setEditorFollowUp("取消这次"); s.requestEditorAction(followUp:true); s.stopEditorRequest(); try await Task.sleep(nanoseconds:300_000_000)
        check(s.translation == "Hello." && s.editorFollowUp == "取消这次","停止追问保留上一回答和未发送草稿")
        s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/error",model:"mock-model") }
        s.requestTranslation(); try await settle(s)
        check(s.errorMessage?.contains("限流") == true && s.draft == "帮我写邀请","请求失败保留输入，显示可操作错误")
        let pending = try state(); pending.handle(key:110); let countBefore = try await records().count; pending.requestTranslation()
        check(try await records().count == countBefore && pending.hasPendingInput,"尚有拼音候选不请求 AI")
        let deep = ModelConfiguration(endpoint:"https://api.deepseek.com/v1",model:"deepseek-chat")
        let body = try JSONSerialization.jsonObject(with:TranslationClient.requestBody(messages:[AIMessage(role:"user",content:"hello")],configuration:deep)) as! [String:Any]
        check((body["thinking"] as? [String:String])?["type"] == "disabled","新动作继续关闭 DeepSeek 思考")

        // Native panel + real Rime + IMK text client, without external requests.
        settings.selectedActionID = "english"
        let e = DraftEditor.shared, client = TextClient()
        client.text.string = "前缀|尾部"; client.text.setSelectedRange(NSRange(location:2,length:1))
        let ui = try state(); e.open(session:ui,client:client,resume:{_,_ in true})
        func tick() async throws { for _ in 0..<100 { try await Task.sleep(nanoseconds:25_000_000); if !e.isHandingOff { return } }; check(false,"上屏交接未超时") }
        try await tick()
        var stamp:TimeInterval = 100
        func key(_ text:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = [],in view:DraftTextView) {
            stamp += 0.03
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:stamp,windowNumber:e.window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
            e.window.makeFirstResponder(view); view.keyDown(with:event)
        }
        e.selectMode(.ask)
        ui.replaceEditorText("写一句邀请",selection:NSRange(location:5,length:0))
        for c in "nihao" { key(String(c),in:e.reference) }
        check(e.hasPendingInput && e.reference.string.contains("ni"),"参考资料支持全拼候选")
        e.requestTranslation(); check(!ui.isTranslating,"参考资料的未完成候选也阻止请求")
        e.selectMode(.transform); check(ui.editorMode == .ask,"未选完词不能切换模式丢失输入")
        key(" ",49,in:e.reference); check(ui.editorReference == "你好","参考资料空格选词正确")
        e.window.makeFirstResponder(e.source); e.requestTranslation(); try await settle(ui)
        check(e.result.string == "Hello." && ui.answers.count == 1,"原生问答生成并呈现真实响应")
        for c in "zaijian" { key(String(c),in:e.followUp) }
        key(" ",49,in:e.followUp); check(ui.editorFollowUp == "再见","追问支持中文选词")
        e.requestFollowUp(); try await settle(ui)
        check(ui.answers.count == 2 && e.followUp.string.isEmpty,"原生追问按钮可执行并更新版本")
        e.window.makeFirstResponder(e.result)
        e.result.insertText(" pasted",replacementRange:NSRange(location:6,length:0))
        e.editingUndoManager(for:e.result)?.undo()
        check(ui.translation == "Hello.","原生文本修改后撤销不混用 AppKit 的范围记录")
        let resultState = e.editingSession(for:e.result)!
        resultState.setASCIIMode(false); e.result.setSelectedRange(NSRange(location:6,length:0))
        for c in "nihao" { key(String(c),in:e.result) }
        e.commitResult(); try await tick(); check(client.text.string == "前缀|尾部" && e.hasPendingInput,"结果修改仍在选词时禁止插入")
        key(" ",49,in:e.result)
        check(ui.translation == "Hello.你好","可在回答中直接修改中文")
        e.editingUndoManager(for:e.result)?.undo(); check(ui.translation == "Hello.","结果中文修改可以撤销")
        e.editingUndoManager(for:e.result)?.redo(); check(ui.translation == "Hello.你好","结果中文修改可以重做")
        try e.capture(to:root.appendingPathComponent(".build/build22-ai-ask.png"))
        e.result.setSelectedRange(NSRange(location:6,length:2))
        check(e.selectedResult == "你好","结果选区按 UTF-16 正确截取中文")
        e.commitPreferred(); try await tick()
        check(client.text.string == "前缀你好尾部" && !e.hasDraft,"选中结果一次替换原目标选区并收起，无需复制粘贴")
        let transform = try state(); client.text.setSelectedRange(NSRange(location:client.text.string.utf16.count,length:0))
        e.open(session:transform,client:client,resume:{_,_ in true}); try await tick()
        e.restoreLastContent()
        check(transform.editorMode == .ask && transform.translation == "Hello.你好" && transform.answers.count == 2,"上屏后仍可取用上次问答、修改结果和版本")
        e.selectMode(.transform)
        transform.replaceEditorText("这周六去海边",selection:NSRange(location:6,length:0)); transform.setEditorAction(AIAction.presets[1]); transform.requestTranslation(); try await settle(transform)
        try e.capture(to:root.appendingPathComponent(".build/build22-ai-transform.png"))
        check(e.canCommitSource,"改文字保留直接上屏原文的按钮")
        transform.editTranslation("A😀你好Z"); e.result.setSelectedRange(NSRange(location:1,length:4))
        check(e.selectedResult == "😀你好","包含 emoji 的选择不会截断 UTF-16 字符")
        let board = NSPasteboard.general
        let backup = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map { (type,$0) } } }
        e.copyResult(); check(board.string(forType:.string) == "😀你好","复制按钮仅复制选中结果")
        board.clearContents()
        let items = backup.map { values -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in values { item.setData(data,forType:type) }; return item }
        if !items.isEmpty { board.writeObjects(items) }
        e.selectMode(.ask); transform.replaceEditorText("新问题",selection:NSRange(location:3,length:0))
        let hostBefore = client.text.string; e.commitPreferred(); try await tick()
        check(e.hasDraft && client.text.string == hostBefore,"问 AI 没有有效回答时 Cmd+Enter 不把问题上屏")
        transform.setEditorMode(.transform)
        _ = e.perform(NSSelectorFromString("newAction"))
        check(e.window.attachedSheet?.title == "自定义动作","新建动作打开原生编辑表单")
        if let sheet = e.window.attachedSheet { e.window.endSheet(sheet); sheet.orderOut(nil) }
        e.hide(); check(e.hasDraft,"收起保留 AI 草稿")
        print("AI action checks: \(checks); mock requests: \(try await records().count); before ask: \(beforeAsk)")
    }
}
