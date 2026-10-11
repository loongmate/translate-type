import AppKit
import InputMethodKit

@main struct EditorTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunEditorTests-"+UUID().uuidString)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        if !FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:user.appendingPathComponent("build"),to:cache) }
        defer { try? FileManager.default.removeItem(at:user) }
        let settings = ConfigurationStore.shared
        let previous = (settings.translateEnabled,settings.pinyinLayout,settings.editorShortcut)
        settings.translateEnabled = true; settings.pinyinLayout = .fullPinyin; settings.editorShortcut = .standard
        defer { settings.translateEnabled = previous.0; settings.pinyinLayout = previous.1; settings.editorShortcut = previous.2 }
        let server = IMKServer(name:"FangCunEditorTests_"+UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        let client = TextClient(); client.text.string = "前缀：尾部"; client.text.setSelectedRange(NSRange(location:3,length:0))
        let controller = TTInputController(server:server,delegate:nil,client:client)!
        controller.activateServer(client)
        let editor = DraftEditor.shared
        var timestamp:TimeInterval = 10
        func event(_ chars:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = [],_ repeating:Bool = false) -> NSEvent {
            timestamp += 0.02
            let actual = chars.isEmpty ? ([UInt16(123):"\u{f702}",124:"\u{f703}",125:"\u{f701}",126:"\u{f700}",51:"\u{7f}",53:"\u{1b}"][code] ?? chars) : chars
            return NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:timestamp,windowNumber:editor.window?.windowNumber ?? 0,context:nil,characters:actual,charactersIgnoringModifiers:actual.lowercased(),isARepeat:repeating,keyCode:code)!
        }
        func host(_ chars:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = []) { _ = controller.handle(event(chars,code,flags),client:client) }
        func key(_ chars:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = []) { editor.source.keyDown(with:event(chars,code,flags)) }
        func type(_ text:String) { for c in text { key(String(c)) } }
        func check(_ value:Bool,_ message:String) { guard value else { print("FAIL:",message); exit(1) }; print("PASS:",message) }
        func tick() async throws {
            try await Task.sleep(nanoseconds:110_000_000)
            for _ in 0..<100 {
                if !editor.isHandingOff { return }
                try await Task.sleep(nanoseconds:25_000_000)
            }
            check(!editor.isHandingOff,"异步输入交接在时限内完成")
        }
        func closeDraft() async throws { editor.session?.discardPendingInput(); editor.session?.replaceEditorText("关闭测试",selection:NSRange(location:4,length:0)); editor.commitSource(); try await tick() }

        // IMKInputSession.h documents a globallyUniqueString wrapper and
        // NSNotFound for unsupported document-access operations. The earlier
        // mock always returned a stable ID and full document access.
        let volatileClient = TextClient()
        volatileClient.generatesIdentity = true
        let volatileSession = UUID()
        let volatileDestination = DraftDestination(client:volatileClient,sessionID:volatileSession)
        check(volatileDestination.problem == nil && volatileDestination.matches(volatileClient,sessionID:volatileSession),"每次变化的唯一字符串不是输入框切换，稳定会话仍可上屏")
        check(volatileDestination.insert("动态标识"),"动态标识客户端使用正常 IMK 上屏")

        let opaqueClient = TextClient()
        opaqueClient.selectionOverride = NSRange(location:NSNotFound,length:NSNotFound)
        opaqueClient.lengthOverride = NSNotFound; opaqueClient.substringUnavailable = true
        opaqueClient.markedOverride = NSRange(location:NSNotFound,length:NSNotFound)
        let opaqueDestination = DraftDestination(client:opaqueClient,sessionID:UUID())
        check(opaqueDestination.problem == nil,"不支持文档访问的客户端不误报为输入位置变化")
        check(opaqueDestination.insert("兼容输入") && opaqueClient.text.string == "兼容输入","不可读光标通过 IMK 当前插入点上屏")
        let partialClient = TextClient()
        partialClient.text.string = "头旧尾"; partialClient.text.setSelectedRange(NSRange(location:1,length:1))
        partialClient.lengthOverride = NSNotFound; partialClient.substringUnavailable = true
        let partialDestination = DraftDestination(client:partialClient,sessionID:UUID())
        check(partialDestination.problem == nil && partialDestination.insert("新") && partialClient.text.string == "头新尾","只有选区可读时仍正确替换选中文字")
        partialClient.text.setSelectedRange(NSRange(location:0,length:0))
        check(partialDestination.problem != nil && !partialDestination.insert("错误"),"长度不可读不影响对真实光标移动的保护")
        let lostCapability = TextClient()
        lostCapability.text.string = "前后"; lostCapability.text.setSelectedRange(NSRange(location:1,length:0))
        let lostDestination = DraftDestination(client:lostCapability,sessionID:UUID())
        lostCapability.selectionOverride = NSRange(location:NSNotFound,length:0)
        lostCapability.lengthOverride = NSNotFound; lostCapability.substringUnavailable = true
        check(lostDestination.problem == nil && lostDestination.insert("中") && lostCapability.text.string == "前中后","面板打开后文档查询暂时不可用不会伪造光标变化")
        let changedLength = TextClient()
        changedLength.text.string = String(repeating:"a",count:60); changedLength.text.setSelectedRange(NSRange(location:0,length:0))
        let lengthDestination = DraftDestination(client:changedLength,sessionID:UUID())
        changedLength.text.string += "b"; changedLength.text.setSelectedRange(NSRange(location:0,length:0))
        check(!lengthDestination.insert("错误") && lengthDestination.problem != nil,"提交时发现文档长度变化仍会拦截并提供恢复原因")
        lengthDestination.reanchor()
        check(lengthDestination.insert("确认"),"长度变化重新确认后恢复上屏")
        check(!volatileDestination.matches(volatileClient,sessionID:UUID()),"动态标识不会让不同会话被当成同一输入框")

        let opaqueController = TTInputController(server:server,delegate:nil,client:opaqueClient)!
        opaqueClient.text.string = "头尾"; opaqueClient.text.setSelectedRange(NSRange(location:1,length:0))
        opaqueClient.generatesIdentity = true
        opaqueController.activateServer(opaqueClient)
        for character in "nihao" { _ = opaqueController.handle(event(String(character)),client:opaqueClient) }
        _ = opaqueController.handle(event("\r",36,[.control,.shift]),client:opaqueClient)
        try await tick()
        check(opaqueClient.text.string == "头尾" && editor.session?.snapshot.input == "nihao","不可读预编辑范围时也能带入拼音并清除宿主下划线内容")
        key(" ",49)
        opaqueController.activateServer(opaqueClient)
        check(editor.canCommitSource,"动态标识且文档不可读时，选词后的上屏按钮保持可用")
        editor.recoverDestination()
        try await tick()
        check(editor.canCommitSource,"兼容客户端确认光标不会陷入永久失败循环")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(!editor.hasDraft && opaqueClient.text.string == "头你好尾","真实 Rime 选词经兼容客户端快捷上屏，保留两侧文字")
        opaqueController.deactivateServer(opaqueClient)

        for c in "nihao" { host(String(c)) }
        host("\r",36,[.control,.shift])
        try await tick()
        let s = editor.session!
        check(editor.isVisible && s.snapshot.input == "nihao","Ctrl+Shift+Enter 带入未选拼音，不翻译")
        check(client.text.string == "前缀：尾部","打开编辑区移除原预编辑，不意外上屏或覆盖周边文字")
        let pending = s.snapshot
        key("\r",36,[.control])
        check(!s.isTranslating && s.snapshot.input == pending.input && s.snapshot.highlighted == pending.highlighted,"未选完时 Ctrl+Enter 保持输入与候选")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        key("\r",36,[.command,.shift])
        try await tick()
        check(editor.hasDraft && s.snapshot.input == pending.input && client.text.string == "前缀：尾部","两种快捷上屏均等待选词，不隐式选择候选")
        check(editor.source.inputContext == nil,"编辑器不递归启动自身 IMK 客户端")
        key(" ",49)
        check(s.draft == "你好" && !s.hasPendingInput && client.text.string == "前缀：尾部","空格在编辑区确认中文，不回写宿主")
        key("\r",36); type("shijie"); key(" ",49)
        check(s.draft == "你好\n世界","Enter 换行后继续用真实全拼选词")
        editor.source.setSelectedRange(NSRange(location:0,length:2)); type("wo"); key(" ",49)
        check(s.draft == "我\n世界","在选区内输入中文替换选区，保留后续内容")
        controller.deactivateServer(client); controller.commitComposition(client)
        check(s.draft == "我\n世界" && client.text.string == "前缀：尾部","打开浮窗导致失焦或 commitComposition 时不丢草稿、不自动上屏")
        controller.activateServer(client)
        editor.source.setSelectedRange(NSRange(location:1,length:0))
        key("",123)
        check(editor.source.selectedRange().location == 0,"无候选时左键正常移动文本光标")
        key("",124)
        check(editor.source.selectedRange().location == 1,"无候选时右键正常移动文本光标")
        key("",51)
        check(s.draft == "\n世界","退格按真实光标删除，而不是删除草稿末尾")
        try await tick()

        // Preserve every existing pasteboard representation; do not log content.
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType:type).map { (type,$0) } } }
        defer { board.clearContents(); let items = saved.map { pairs -> NSPasteboardItem in let i = NSPasteboardItem(); for (type,data) in pairs { i.setData(data,forType:type) }; return i }; board.writeObjects(items) }
        board.clearContents(); board.setString("粘贴🧭\nEnglish",forType:.string)
        editor.source.setSelectedRange(NSRange(location:0,length:1))
        check(editor.window.performKeyEquivalent(with:event("v",9,[.command])),"原生编辑窗识别 Command+V")
        check(s.draft == "粘贴🧭\nEnglish世界","粘贴替换选区，Unicode、换行与尾部保留")
        try await tick()
        editor.history.undo()
        check(s.draft == "\n世界","粘贴支持撤销")
        editor.history.redo()
        check(s.draft == "粘贴🧭\nEnglish世界","粘贴支持重做")
        try await tick()
        editor.source.setSelectedRange(NSRange(location:2,length:2)); type("ni")
        let prePaste = s.markedText
        editor.source.paste(nil)
        check(s.markedText == prePaste,"尚未选词时粘贴不破坏合成状态")
        key("",53)
        check(!s.hasPendingInput && s.draft.contains("🧭") && editor.isVisible,"Esc 优先取消拼音，保留原选区与编辑窗")
        s.replaceEditorText("待译内容",selection:NSRange(location:4,length:0))
        var requests = 0
        s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/v1",model:"editor-test") }
        s.readKey = { _ in requests += 1; return "synthetic-key" }
        key("\r",36,[.control]); key("\r",36,[.control])
        try await Task.sleep(nanoseconds:500_000_000)
        check(requests == 1 && s.translation == "Hello.","真实客户端请求模拟兼容接口，只主动请求一次")
        editor.result.setSelectedRange(NSRange(location:0,length:editor.result.string.utf16.count))
        editor.result.insertText("Edited result.",replacementRange:editor.result.selectedRange())
        check(s.translation == "Edited result.","译文可以直接修改")
        editor.result.keyDown(with:event("!",18,[.shift]))
        check(s.translation == "Edited result.!","译文区域直接输入英文，不进入拼音候选")
        try editor.capture(to:root.appendingPathComponent(".build/build16-editor-translation.png"))
        s.replaceEditorText("修改原文",selection:NSRange(location:4,length:0))
        check(s.translation == nil && requests == 1,"改原文使译文失效，不自动调用")
        key("\r",36,[.control]); s.cancelTranslation()
        try await Task.sleep(nanoseconds:350_000_000)
        check(s.translation == nil && !s.isTranslating && s.draft == "修改原文","停止翻译后过期结果不能覆盖草稿")
        let other = TextClient(); other.text.string = "另一输入框"; editor.hostActivated(other)
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(editor.hasDraft && client.text.string == "前缀：尾部" && other.text.string == "另一输入框","同一应用切到另一个输入框后禁止误上屏")
        editor.hostActivated(client)
        client.text.setSelectedRange(NSRange(location:0,length:0)); key("\r",36,[.command,.shift])
        try await tick()
        check(editor.hasDraft && client.text.string == "前缀：尾部","原光标移动后禁止按旧位置上屏")
        client.text.setSelectedRange(NSRange(location:3,length:0))
        s.replaceEditorText("中文\nFangCun",selection:NSRange(location:10,length:0))
        editor.hide(); check(editor.hasDraft && !editor.isVisible,"关闭窗口只收起草稿")
        host("\r",36,[.control,.shift])
        try await tick()
        check(editor.isVisible && editor.session === s && s.draft == "中文\nFangCun","再次快捷键恢复同一草稿")
        key("\r",36,[.command])
        try await tick()
        check(!editor.hasDraft && client.text.string == "前缀：中文\nFangCun尾部","原文一次插回绑定光标，不发送、不中断后续文字")

        host("\r",36,[.control,.shift])
        try await tick()
        check(editor.hasDraft && editor.session!.draft.isEmpty,"空输入可直接打开空白编辑区")
        let second = editor.session!
        second.replaceEditorText("长文\n"+String(repeating:"这是一段可以自由编辑和粘贴的长文。\n",count:150),selection:NSRange(location:0,length:0))
        editor.window.setContentSize(NSSize(width:840,height:570)); try await tick()
        check(editor.source.enclosingScrollView!.hasVerticalScroller && editor.source.string.utf16.count > 2500,"数千字完整保留，文本区支持纵向滚动")
        try editor.capture(to:root.appendingPathComponent(".build/build16-editor-long.png"))
        second.replaceEditorText("你好",selection:NSRange(location:1,length:0)); type("shi")
        let beforeCollapse = second.snapshot.input
        editor.collapse()
        check(!editor.hasDraft && client.text.hasMarkedText(),"缩小回到原输入框的候选状态")
        controller.deactivateServer(client)
        check(editor.hasDraft && !editor.isVisible && second.snapshot.input == beforeCollapse && !client.text.hasMarkedText(),"缩小后切走应用只收起草稿，不自动选词或上屏")
        host("\r",36,[.control,.shift])
        try await tick()
        check(editor.session === second && second.snapshot.input == beforeCollapse && second.draft == "你好","缩回再放大保留未选拼音、草稿与插入位置")
        key(" ",49)
        check(second.draft.hasPrefix("你") && second.draft.hasSuffix("好") && second.draft.count > 2,"缩放后选词继续插在中文草稿中间")
        try await closeDraft()

        for layout in PinyinLayout.doublePinyin {
            settings.pinyinLayout = layout
            let fresh = TextClient(), ctrl = TTInputController(server:server,delegate:nil,client:TextClient())!
            ctrl.activateServer(fresh)
            _ = ctrl.handle(event("\r",36,[.control,.shift]),client:fresh)
            try await tick()
            check(editor.session?.pinyinLayout == layout,"编辑区复用\(layout.name)")
            let syllable = [PinyinLayout.flypy:"nihc",.pinyinJiajia:"nihd",.ziguang:"nihq"][layout] ?? "nihk"
            type(syllable); key(" ",49)
            check(editor.session?.draft == "你好","\(layout.name)在编辑区正常选词")
            try await closeDraft(); ctrl.deactivateServer(fresh)
        }
        settings.pinyinLayout = .fullPinyin
        controller.activateServer(client); host("\r",36,[.control,.shift])
        try await tick()
        let mixed = editor.session!
        mixed.setASCIIMode(true); type("Hello World!"); key("\r",36)
        check(mixed.draft == "Hello World!\n","编辑区英文直输保留空格标点，Enter 正常换行")
        mixed.setASCIIMode(false); type("tuopanlidelogo")
        while mixed.hasPendingInput { mixed.choose(0) }
        check(mixed.draft.hasSuffix("托盘里的logo"),"全拼夹杂英文在编辑区保持正常选词")
        mixed.replaceEditorText(String(repeating:"长文翻译内容。",count:700),selection:NSRange(location:0,length:0))
        mixed.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/v1",model:"editor-test") }
        mixed.readKey = { _ in "synthetic-key" }
        mixed.requestTranslation(); try await Task.sleep(nanoseconds:500_000_000)
        check(mixed.translation == "Hello." && mixed.draft.count > 4000,"超过原 4,000 字限制的长文能一次主动翻译")
        editor.result.selectAll(nil)
        editor.result.insertText("Long document result.",replacementRange:editor.result.selectedRange())
        let targetBefore = client.text.string
        editor.commitResult()
        try await tick()
        check(!editor.hasDraft && client.text.string.contains("Long document result.") && client.text.string.count > targetBefore.count,"修改后的真实译文完整上屏")
        settings.translateEnabled = false
        let plainClient = TextClient(), plainController = TTInputController(server:server,delegate:nil,client:TextClient())!
        plainController.activateServer(plainClient)
        _ = plainController.handle(event("\r",36,[.control,.shift]),client:plainClient)
        try await tick()
        type("nihao"); key(" ",49)
        check(editor.session?.draft == "你好" && plainClient.text.string.isEmpty && settings.translateEnabled == false,"中文直出模式打开编辑区后暂存中文，不修改全局译英开关")
        editor.session?.replaceEditorText(String(repeating:"字",count:20_001),selection:NSRange(location:0,length:0))
        check(editor.session?.canRequestTranslation == false && editor.source.string.count == 20_001,"超出翻译上限只禁用翻译，长草稿完整可编辑")
        try await closeDraft(); plainController.deactivateServer(plainClient)

        // Exercise the same window key-equivalent / responder routes used by
        // real Cmd+Enter, including selected destination text and Unicode.
        let shortcutClient = TextClient()
        let originalText = "头：旧内容：尾", draftText = "原文🧭\n第二行"
        var shortcutRequests = 0
        func shortcutDraft() async throws -> CompositionSession {
            shortcutClient.text.string = originalText
            shortcutClient.text.setSelectedRange(NSRange(location:2,length:3))
            let state = CompositionSession(engine:try PinyinEngine(layout:.fullPinyin),translateEnabled:true)
            state.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/v1",model:"editor-test") }
            state.readKey = { _ in shortcutRequests += 1; return "synthetic-key" }
            editor.open(session:state,client:shortcutClient,resume:{ _,_ in false })
            try await tick()
            state.replaceEditorText(draftText,selection:NSRange(location:0,length:0))
            return state
        }
        let pasteboardRevision = board.changeCount
        let shortcutSource = try await shortcutDraft()
        check(!editor.handleCommitShortcut(event("\r",36,[.command,.option])) && editor.hasDraft,"额外修饰键不会误触快捷上屏")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command],true))
        try await tick()
        check(editor.hasDraft && shortcutClient.text.string == originalText,"忽略长按产生的重复上屏事件")
        _ = editor.window.performKeyEquivalent(with:event("\r",76,[.command]))
        try await tick()
        check(!editor.hasDraft && shortcutClient.text.string == "头：\(draftText)：尾" && shortcutRequests == 0,"数字键盘 Cmd+Enter 将完整原文替换原选区，不调用模型")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(shortcutClient.text.string == "头：\(draftText)：尾" && shortcutSource.draft.isEmpty,"重复快捷键不会二次插入")

        let working = try await shortcutDraft()
        working.requestTranslation()
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(editor.hasDraft && working.isTranslating && shortcutClient.text.string == originalText,"翻译中 Cmd+Enter 不降级提交中文")
        key("\r",36,[.command,.shift])
        try await tick()
        check(!editor.hasDraft && !working.isTranslating && shortcutClient.text.string == "头：\(draftText)：尾","翻译中显式 Cmd+Shift+Enter 提交原文并取消请求")
        try await Task.sleep(nanoseconds:350_000_000)
        check(shortcutClient.text.string == "头：\(draftText)：尾","原文已上屏后迟到译文不能再次写入")

        for mode in ["window", "result", "original"] {
            let translated = try await shortcutDraft()
            translated.requestTranslation(); try await Task.sleep(nanoseconds:500_000_000)
            precondition(translated.translation == "Hello.")
            translated.editTranslation("Edited English 🧭\nSecond line.")
            editor.window.makeFirstResponder(mode == "window" ? editor.source : editor.result)
            let before = shortcutRequests
            if mode == "result" { editor.result.keyDown(with:event("\r",36,[.command])) }
            else { _ = editor.window.performKeyEquivalent(with:event("\r",36,mode == "original" ? [.command,.shift] : [.command])) }
            try await tick()
            let expected = mode == "original" ? draftText : "Edited English 🧭\nSecond line."
            check(!editor.hasDraft && !editor.isVisible && shortcutClient.text.string == "头：\(expected)：尾" && shortcutRequests == before,"\(mode) 焦点快捷上屏选定全文、自动收起且不额外请求")
        }
        let emptyResult = try await shortcutDraft()
        emptyResult.requestTranslation(); try await Task.sleep(nanoseconds:500_000_000)
        precondition(emptyResult.translation != nil)
        emptyResult.editTranslation("")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(editor.hasDraft && shortcutClient.text.string == originalText,"清空译文后 Cmd+Enter 不意外上屏中文")
        key("\r",76,[.command,.shift])
        try await tick()
        check(!editor.hasDraft && shortcutClient.text.string == "头：\(draftText)：尾","数字键盘 Cmd+Shift+Enter 显式上屏原文")
        let emptyDraft = try await shortcutDraft()
        emptyDraft.replaceEditorText("",selection:NSRange(location:0,length:0))
        key("\r",36,[.command])
        try await tick()
        check(editor.hasDraft && shortcutClient.text.string == originalText,"空草稿快捷上屏不改写原输入框选区")
        try await closeDraft()
        check(board.changeCount == pasteboardRevision,"快捷上屏直接写回 IMK 客户端，全程不修改剪贴板")

        // Real IMK senders can be renewed proxies. Test session identity and
        // explicit rebind through controllers, not only one stable mock object.
        let focusClient = TextClient(identity:"")
        focusClient.text.string = "左：原位置：右"; focusClient.text.setSelectedRange(NSRange(location:2,length:3))
        let focusController = TTInputController(server:server,delegate:nil,client:focusClient)!
        focusController.activateServer(focusClient)
        check(focusClient.text.string == "左：原位置：右","激活输入法不删除宿主选区")
        let frontBeforeEditor = NSWorkspace.shared.frontmostApplication?.processIdentifier
        _ = focusController.handle(event("\r",36,[.control,.shift]),client:focusClient)
        try await tick()
        check(focusClient.text.string == "左：原位置：右","带选区打开编辑区不删除原有文字")
        let focusDraft = editor.session!
        focusDraft.replaceEditorText("共享草稿",selection:NSRange(location:4,length:0))
        check(editor.window.styleMask.contains(.nonactivatingPanel) && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontBeforeEditor,"临时编辑窗使用非激活面板，不主动切换前台应用")
        check(editor.canCommitSource,"打开编辑区保留可上屏的原输入位置")

        let ownClient = TextClient(bundleID:InputSourceStatus.bundleID)
        let ownController = TTInputController(server:server,delegate:nil,client:ownClient)!
        ownController.activateServer(ownClient)
        check(editor.canCommitSource && editor.destination?.client as AnyObject? === focusClient,"输入法自身设置客户端激活不污染上屏目标")
        let testOwnClient = TextClient(bundleID:Bundle.main.bundleIdentifier!)
        editor.hostActivated(testOwnClient)
        check(editor.canCommitSource && editor.session === focusDraft,"当前输入法进程的其他客户端不标记切换输入框")
        ownController.deactivateServer(ownClient)

        let renewedProxy = TextClient(text:focusClient.text,identity:"")
        focusController.activateServer(renewedProxy)
        check(focusClient.text.string == "左：原位置：右","客户端代理更换不删除原有文字")
        check(editor.canCommitSource && editor.destination?.client as AnyObject? === renewedProxy,"同一 IMK 会话的无标识新代理继续指向原输入框")
        renewedProxy.text.setSelectedRange(NSRange(location:1,length:0)); editor.refreshDestination()
        check(!editor.canCommitSource,"代理更新后仍校验真实光标变化")
        editor.recoverDestination()
        try await tick()
        check(editor.canCommitSource && editor.destinationMessage.contains("目标："),"确认当前光标实际更新锚点并恢复上屏按钮")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(!editor.hasDraft && renewedProxy.text.string == "左共享草稿：原位置：右","恢复光标后快捷键写入确认的位置")

        // A second session with exactly the same text/range is still another
        // destination. Only the explicit recovery button may adopt it.
        focusClient.text.string = "左：原位置：右"; focusClient.text.setSelectedRange(NSRange(location:2,length:3))
        focusController.activateServer(focusClient)
        _ = focusController.handle(event("\r",36,[.control,.shift]),client:focusClient)
        try await tick()
        let movingDraft = editor.session!
        movingDraft.replaceEditorText("新位置的草稿",selection:NSRange(location:6,length:0))
        let newClient = TextClient(identity:"")
        newClient.text.string = focusClient.text.string; newClient.text.setSelectedRange(focusClient.text.selectedRange())
        let newController = TTInputController(server:server,delegate:nil,client:newClient)!
        newController.activateServer(newClient)
        _ = newController.handle(event("\r",36,[.control,.shift]),client:newClient)
        try await tick()
        check(!editor.canCommitSource && editor.session === movingDraft,"相同内容和光标的另一输入会话仍需明确确认")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(editor.hasDraft && newClient.text.string == "左：原位置：右" && focusClient.text.string == "左：原位置：右","确认前不会写入新旧输入框")
        editor.recoverDestination()
        try await tick()
        check(editor.canCommitSource && editor.destination?.client as AnyObject? === newClient && movingDraft.draft == "新位置的草稿","使用当前输入位置真正绑定新客户端并保留草稿")
        editor.collapse()
        check(!editor.hasDraft && newClient.text.hasMarkedText() && !focusClient.text.hasMarkedText(),"重新绑定后缩小由新输入控制器承接草稿")
        _ = newController.handle(event("\r",36,[.control,.shift]),client:newClient)
        try await tick()
        check(editor.session === movingDraft && editor.canCommitSource,"新位置再次放大能继续同一草稿")
        focusController.activateServer(focusClient)
        for character in "nihao" { _ = focusController.handle(event(String(character)),client:focusClient) }
        _ = focusController.handle(event(" ",49),client:focusClient)
        check(movingDraft.draft == "新位置的草稿" && !focusClient.text.string.contains("新位置的草稿"),"旧控制器重新打字不共享或篡改已转交的编辑草稿")
        newController.activateServer(newClient)
        _ = newController.handle(event("\r",36,[.control,.shift]),client:newClient)
        try await tick()
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(!editor.hasDraft && newClient.text.string == "左：新位置的草稿：右","重新绑定、缩放和旧会话输入后仍准确上屏")
        focusController.deactivateServer(focusClient); newController.deactivateServer(newClient)

        let reidentified = TextClient(identity:"before")
        let reidentifiedController = TTInputController(server:server,delegate:nil,client:reidentified)!
        reidentifiedController.activateServer(reidentified)
        _ = reidentifiedController.handle(event("\r",36,[.control,.shift]),client:reidentified)
        try await tick()
        editor.session?.replaceEditorText("确认后上屏",selection:NSRange(location:5,length:0))
        reidentified.identity = "after"
        reidentifiedController.activateServer(reidentified)
        check(!editor.canCommitSource,"同一代理对象返回不同客户端标识时不能绕过目标校验")
        editor.recoverDestination()
        try await tick()
        check(editor.canCommitSource,"客户端标识变化后可明确确认当前输入位置，避免永久灰掉")
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        try await tick()
        check(reidentified.text.string == "确认后上屏" && !editor.hasDraft,"标识变化恢复后可正常快捷上屏")
        for down in [true,false] {
            timestamp += 0.05
            let shift = NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:down ? [.shift] : [],timestamp:timestamp,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56)!
            _ = reidentifiedController.handle(shift,client:reidentified)
        }
        for character in "logo" { _ = reidentifiedController.handle(event(String(character)),client:reidentified) }
        check(reidentified.text.string == "确认后上屏logo" && !reidentified.text.hasMarkedText(),"上屏后即使系统没有再次激活会话，轻按 Shift 仍能切到英文")
        reidentifiedController.deactivateServer(reidentified)

        // Reproduce the actual build-20 log: the clear has been requested but
        // the browser still reports our old marked/selected range. Do not move
        // focus or anchor until the host has applied the request.
        let deferredClient = TextClient()
        deferredClient.generatesIdentity = true; deferredClient.lengthOverride = 0; deferredClient.substringUnavailable = true
        deferredClient.text.string = "前后"; deferredClient.text.setSelectedRange(NSRange(location:1,length:0))
        let deferredController = TTInputController(server:server,delegate:nil,client:deferredClient)!
        deferredController.activateServer(deferredClient)
        for character in "nihao" { _ = deferredController.handle(event(String(character)),client:deferredClient) }
        deferredClient.deferEmptyChanges = true
        _ = deferredController.handle(event("\r",36,[.control,.shift]),client:deferredClient)
        check(editor.isHandingOff && !editor.isVisible,"发出清除预编辑请求后先归还 IMK 事件，不立即抢走焦点")
        try await Task.sleep(nanoseconds:150_000_000)
        check(editor.isHandingOff && !editor.isVisible && deferredClient.pendingChangeCount == 1,"宿主延迟更新期间不锚定旧选区，且只清除一次")
        deferredController.activateServer(deferredClient)
        check(deferredClient.pendingChangeCount == 1,"交接时的激活回调不再次发送空预编辑或覆盖选区")
        deferredClient.deliverPendingChanges(); deferredClient.deferEmptyChanges = false
        try await tick()
        key(" ",49)
        check(editor.isVisible && editor.canCommitSource && deferredClient.text.string == "前后","异步清除完成后自动记录新光标，上屏按钮恢复而无需用户确认")
        deferredClient.canDeliverInsertion = { !editor.isVisible }
        let insertCount = deferredClient.insertedRanges.count
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        _ = editor.window.performKeyEquivalent(with:event("\r",36,[.command]))
        check(!editor.isVisible && editor.hasDraft && deferredClient.text.string == "前后","上屏先收起编辑窗、交还焦点，尚未写入时保留草稿")
        try await tick()
        check(deferredClient.text.string == "前你好后" && deferredClient.pendingChangeCount == 0 && !editor.hasDraft,"恢复宿主焦点后立即上屏，不等用户再输入一个字符")
        check(deferredClient.insertedRanges.count == insertCount+1,"焦点交接中的连续 Cmd+Enter 只提交一次")

        _ = deferredController.handle(event("\r",36,[.control,.shift]),client:deferredClient)
        try await tick()
        editor.session?.replaceEditorText("独立草稿",selection:NSRange(location:4,length:0))
        editor.hide()
        for character in "wo" { _ = deferredController.handle(event(String(character)),client:deferredClient) }
        check(editor.hasDraft && editor.session?.draft == "独立草稿" && !deferredClient.text.string.contains("独立草稿"),"返回原框打字不会把编辑区草稿自动带回预编辑")
        _ = deferredController.handle(event(" ",49),client:deferredClient)
        _ = deferredController.handle(event("\r",36),client:deferredClient)
        _ = deferredController.handle(event("\r",36,[.control,.shift]),client:deferredClient)
        try await tick()
        let beforeRebind = deferredClient.text.string
        editor.recoverDestination(); try await tick()
        check(editor.canCommitSource && deferredClient.text.string == beforeRebind && editor.session?.draft == "独立草稿","重新绑定只更新光标，不偷偷提交文字")
        check(editor.destinationMessage.hasPrefix("目标：") && !editor.destinationMessage.contains("已插入"),"目标位置提示明确区别于插入成功")
        editor.commitSource(); try await tick()
        check(deferredClient.text.string.contains("独立草稿") && !editor.hasDraft,"重新绑定后明确按上屏才写回草稿")

        _ = deferredController.handle(event("\r",36,[.control,.shift]),client:deferredClient)
        try await tick()
        editor.session?.replaceEditorText("不能误插",selection:NSRange(location:4,length:0))
        let beforeMove = deferredClient.text.string
        editor.commitSource()
        deferredClient.text.setSelectedRange(NSRange(location:0,length:0))
        try await tick()
        check(editor.hasDraft && editor.isVisible && deferredClient.text.string == beforeMove,"交还焦点后再次校验，期间光标变化时保留草稿并停止提交")
        editor.recoverDestination(); try await tick()
        editor.commitSource()
        _ = deferredController.handle(event("n"),client:deferredClient)
        try await tick()
        check(editor.hasDraft && editor.session?.draft == "不能误插" && !deferredClient.text.string.contains("不能误插"),"用户在上屏交接中继续打字时取消待提交内容，不覆盖新输入")
        _ = deferredController.handle(event("\r",36),client:deferredClient)
        editor.recoverDestination(); try await tick()
        editor.commitSource(); try await tick()
        check(!editor.hasDraft && deferredClient.text.string.contains("不能误插"),"取消交接后草稿仍可重新绑定并提交")
        deferredController.deactivateServer(deferredClient)

        let timeoutClient = TextClient()
        let timeoutController = TTInputController(server:server,delegate:nil,client:timeoutClient)!
        timeoutController.activateServer(timeoutClient)
        for character in "nihao" { _ = timeoutController.handle(event(String(character)),client:timeoutClient) }
        timeoutClient.deferEmptyChanges = true
        _ = timeoutController.handle(event("\r",36,[.control,.shift]),client:timeoutClient)
        try await tick()
        check(editor.isVisible && editor.session?.snapshot.input == "nihao" && !editor.canCommitSource,"宿主更新超时仍展示并保留完整草稿，不假装上屏成功")
        timeoutClient.deliverPendingChanges(); timeoutClient.deferEmptyChanges = false
        editor.recoverDestination(); try await tick(); key(" ",49)
        check(editor.canCommitSource,"宿主恢复后重新绑定会等待并记录真实光标，按钮可恢复")
        editor.commitSource(); try await tick()
        check(!editor.hasDraft && timeoutClient.text.string == "你好","超时恢复后无需额外按键即可提交一次完整中文")
        timeoutController.deactivateServer(timeoutClient)

        let custom = EditorShortcut(keyCode:14,modifiers:NSEvent.ModifierFlags([.control,.option]).rawValue,key:"e")
        settings.editorShortcut = custom
        check(custom.matches(event("e",14,[.control,.option])) && !custom.matches(event("e",14,[.control,.option,.shift])),"自定义快捷键精确匹配修饰键")
        check(EditorShortcut.recording(event("e",14,[.control,.shift])) == nil,"录制快捷键不能占用已有译英开关")
        settings.editorShortcut = .standard
        check(EditorShortcut.standard.matches(event("\r",76,[.control,.shift])),"数字键盘 Enter 也能打开编辑区")
        print("ALL EDITOR TESTS PASSED")
    }
}
