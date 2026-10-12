import AppKit
import InputMethodKit

@main struct ContextCandidateTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunContextTests-"+UUID().uuidString)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        if !FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:user.appendingPathComponent("build"),to:cache) }
        defer { try? FileManager.default.removeItem(at:user) }
        var checks = 0
        func check(_ ok:Bool,_ name:String) { if !ok { print("FAIL:",name); exit(1) }; checks += 1; print("PASS:",name) }
        func type(_ value:String,in s:CompositionSession) { for c in value.unicodeScalars { s.handle(key:Int(c.value)) } }
        func composition(_ prefix:String? = "上",layout:PinyinLayout = .fullPinyin) throws -> CompositionSession {
            let s = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:false)
            s.setContext(prefix); type(layout == .fullPinyin ? "hai" : "hl",in:s); return s
        }
        let plain = try composition(nil)
        let base = plain.candidates
        print("BASE:",base)
        check(base.first != "海" && base.contains("海"),"测试前提：原始 hai 首选不是海，海在本页")
        let s = try composition()
        print("CONTEXT:",s.candidates)
        check(s.contextActive && s.candidates.first == "海","上 + hai 优先海，显示上下文标记")
        let focusCommit = try composition(); var committedOnBlur = ""
        focusCommit.onInsert = { committedOnBlur += $0 }
        focusCommit.invalidateContext("focus-lost",preserveHighlight:true); focusCommit.flushOriginal()
        check(committedOnBlur == "海","失焦自动确认仍提交原来显示的海，不因退出感知变成还")
        let shortcutCommit = try composition(); var committedOnShortcut = ""
        shortcutCommit.onInsert = { committedOnShortcut += $0 }
        shortcutCommit.handle(key:9,command:true); shortcutCommit.flushOriginal()
        check(committedOnShortcut == "海","宿主快捷键结束预编辑时保留原高亮词")
        let panel = CandidatePanel()
        panel.show(session:s,anchor:NSRect(x:100,y:400,width:1,height:20),settings:{})
        let view = panel.contentView!; view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(".build/context-candidate-panel.png"))
        panel.orderOut(nil)
        try SettingsWindow.shared.capture(to:root.appendingPathComponent(".build/context-input-settings.png"))
        check(Set(s.candidates) == Set(base),"只调整现有候选，不添加或丢失候选")
        var inserted = ""; s.onInsert = { inserted += $0 }; s.handle(key:32)
        check(inserted == "海" && !s.hasPendingInput && !s.contextActive,"空格提交看到的首选海，提交后隐藏标记")
        for index in base.indices {
            let numbered = try composition(); let expected = numbered.candidates[index]
            var output = ""; numbered.onInsert = { output += $0 }; numbered.handle(key:49+index)
            check(output == expected,"数字键 \(index+1) 与排序后的候选一致")
            let clicked = try composition(); let chosen = clicked.candidates[index]
            output = ""; clicked.onInsert = { output += $0 }; clicked.choose(index)
            check(output == chosen,"鼠标选择候选 \(index+1) 与显示一致")
        }
        let arrow = try composition(); let second = arrow.candidates[1]
        arrow.handle(key:0xff53); check(arrow.highlighted == 1,"右键选择上下文排序后的第二项")
        arrow.handle(key:0xff51); check(arrow.highlighted == 0 && arrow.contextActive,"左键回到第一项，不移动拼音")
        arrow.handle(key:0xff54); var output = ""; arrow.onInsert = { output += $0 }; arrow.handle(key:32)
        check(output == second,"上下方向键后的空格提交高亮词")
        let caret = try composition(); caret.handle(key:0xff51)
        check(!caret.contextActive && caret.snapshot.caret < caret.snapshot.preedit.utf16.count,"首项再左移才编辑拼音，同时暂停感知")
        let back = try composition(); back.handle(key:0xff53); back.handle(key:0xff51); back.handle(key:0xff51)
        check(!back.contextActive && back.snapshot.caret < back.snapshot.preedit.utf16.count,"手动回到首项再左移也进入拼音，不落入原生索引")
        let crossPage = try composition()
        for _ in 0..<crossPage.candidates.count { crossPage.handle(key:0xff53) }
        check(crossPage.snapshot.page == 1 && crossPage.highlighted == 0,"右键越过末项到下一页首项，不跳过候选")
        let page = try composition(); page.handle(key:61)
        check(page.snapshot.page == 1 && !page.contextActive,"加号翻页回到普通候选且隐藏标记")
        let pageWord = page.candidates[page.highlighted]; output = ""; page.onInsert = { output += $0 }; page.handle(key:32)
        check(output == pageWord,"翻页后空格不误选前页映射")
        for prefix in ["墙上","皇上"] {
            let baseline = try composition(nil).candidates
            let negative = try composition(prefix)
            check(negative.candidates == baseline,"\(prefix)不借用上海的关联")
        }
        let baselineNow = try composition(nil).candidates
        let off = try composition(); off.invalidateContext("disabled")
        check(off.candidates == baselineNow && !off.contextActive,"关闭时立即恢复原候选和索引")
        output = ""; off.onInsert = { output += $0 }; off.handle(key:32)
        check(output == baselineNow[0],"关闭后空格使用普通首选")
        let double = try composition(layout:.sogou)
        check(double.candidates.first == "海" && double.contextActive,"搜狗双拼 hl 同样支持上下文")
        let raw = try composition(); output = ""; raw.onInsert = { output += $0 }; raw.handle(key:0xff0d)
        check(output == "hai","Enter 仍原样输入英文，不自动选海")

        let defaults = UserDefaults(suiteName:"FangCun.ContextSettingTests."+UUID().uuidString)!
        let store = ConfigurationStore(defaults:defaults)
        check(store.contextAwarenessEnabled,"新设置默认开启")
        store.contextAwarenessEnabled = false
        check(!ConfigurationStore(defaults:defaults).contextAwarenessEnabled,"关闭设置持久化")
        defaults.removeObject(forKey:"contextAwarenessEnabled")

        let oldTranslate = ConfigurationStore.shared.translateEnabled
        let oldLayout = ConfigurationStore.shared.pinyinLayout
        let oldContext = ConfigurationStore.shared.contextAwarenessEnabled
        ConfigurationStore.shared.translateEnabled = false; ConfigurationStore.shared.pinyinLayout = .fullPinyin
        ConfigurationStore.shared.contextAwarenessEnabled = true
        defer {
            ConfigurationStore.shared.translateEnabled = oldTranslate; ConfigurationStore.shared.pinyinLayout = oldLayout
            ConfigurationStore.shared.contextAwarenessEnabled = oldContext
        }
        let server = IMKServer(name:"FangCunContextTests_"+UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        let client = TextClient()
        let controller = TTInputController(server:server,delegate:nil,client:client)!
        defer { controller.deactivateServer(client) }
        var timestamp = 1.0
        @discardableResult func key(_ chars:String,_ code:UInt16 = 0,flags:NSEvent.ModifierFlags = [],target:TextClient? = nil)->Bool {
            timestamp += 0.02
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:timestamp,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!
            return controller.handle(event,client:target ?? client)
        }
        func type(_ text:String) { for c in text { key(String(c)) } }
        func restart(_ initial:String = "") {
            controller.deactivateServer(client); client.text.unmarkText(); client.text.string = initial
            client.text.setSelectedRange(NSRange(location:initial.utf16.count,length:0)); controller.activateServer(client)
        }
        func seed() { restart(); type("shang"); key(" ",49); check(client.text.string == "上","控制器：上字已确认") }
        restart("上"); type("hai")
        check(!controller.contextStatus.active,"重新聚焦已有上字不立即沿用历史")
        seed(); type("hai")
        check(controller.contextStatus.active,"连续输入且宿主核对通过，显示标记")
        key(" ",49); check(client.text.string == "上海","真实 NSTextView：上屏上，再打 hai 空格得到上海")
        seed(); type("hai"); controller.deactivateServer(client)
        check(client.text.string == "上海" && !controller.contextStatus.active,"控制器失焦：确认可见候选，然后停止感知")
        seed(); key(","); type("shang")
        check(!controller.contextStatus.dirty && !controller.contextStatus.active,"连续标点不变脏，但隔开词组关联并隐藏标记")
        key(" ",49); type("hai")
        check(controller.contextStatus.active,"标点后新确认的中文可继续提供上下文")
        key(" ",49); check(client.text.string.hasSuffix("上海"),"标点后无需重新聚焦也能连续选出上海")
        seed(); type("logo"); key("\r",36); type("shang")
        check(!controller.contextStatus.dirty && !controller.contextStatus.active,"原样确认的英文隔开关联，不误用之前的上字")
        key(" ",49); type("hai"); check(controller.contextStatus.active,"中英混输后新确认的中文重新提供上下文")
        seed(); client.reportsMarkedSelection = true; type("hai")
        check(controller.contextStatus.active,"IMK 返回整个预编辑作为选区时，核对精确预编辑范围")
        key(" ",49); check(client.text.string == "上海","预编辑选区表示下仍正确提交上海")
        client.reportsMarkedSelection = false
        seed(); key("\u{f702}",123)
        check(controller.contextStatus.dirty && !controller.contextStatus.active,"无拼音时左右键将上下文变脏")
        type("hai"); check(!controller.contextStatus.active,"脏标记在本次焦点内不自动恢复")
        seed(); key("\u{7f}",51); type("hai")
        check(!controller.contextStatus.active && controller.contextStatus.dirty,"删除键暂停上下文")
        seed(); type("hai"); key("\u{f703}",124,flags:[.shift])
        check(controller.contextStatus.dirty && !controller.contextStatus.active,"Shift 方向键选择文字时暂停")
        seed(); key("\u{f729}",115); type("hai")
        check(controller.contextStatus.dirty && !controller.contextStatus.active,"Home 导航立即变脏")
        seed(); key("v",9,flags:[.command]); type("hai")
        check(!controller.contextStatus.active,"粘贴快捷键暂停上下文")
        seed(); client.text.setSelectedRange(NSRange(location:0,length:0)); type("hai")
        check(!controller.contextStatus.active && controller.contextStatus.dirty,"无按键通知的光标变化也能检测")
        seed(); client.text.string = "下"; client.text.setSelectedRange(NSRange(location:1,length:0)); type("hai")
        check(!controller.contextStatus.active,"相同光标位置下前文被改写也暂停")
        seed(); client.identity = UUID().uuidString; type("hai")
        check(!controller.contextStatus.active,"同应用输入框身份变化暂停")
        seed(); client.substringUnavailable = true; type("hai")
        check(!controller.contextStatus.active,"宿主不提供前文时降级"); client.substringUnavailable = false
        seed(); client.text.setSelectedRange(NSRange(location:0,length:1)); type("hai")
        check(!controller.contextStatus.active,"选区替换暂停感知")
        seed(); let other = TextClient(); other.text.string = "上"; other.text.setSelectedRange(NSRange(location:1,length:0))
        key("h",target:other); check(!controller.contextStatus.active,"同应用同文本同光标的另一个输入框不串用")
        seed(); type("hai"); ConfigurationStore.shared.contextAwarenessEnabled = false
        NotificationCenter.default.post(name:.contextAwarenessChanged,object:nil)
        check(!controller.contextStatus.active,"设置关闭立即移除标记")
        let unrankedNow = try composition(nil).candidates[0]
        key(" ",49); check(client.text.string == "上"+unrankedNow,"设置关闭后不残留错误候选索引")
        ConfigurationStore.shared.contextAwarenessEnabled = true
        ConfigurationStore.shared.translateEnabled = true
        // A new controller represents a fresh focus with translation enabled.
        controller.deactivateServer(client)
        let draftClient = TextClient()
        let draftController = TTInputController(server:server,delegate:nil,client:draftClient)!
        draftController.activateServer(draftClient)
        func draftKey(_ character:Character) {
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:timestamp,windowNumber:0,context:nil,characters:String(character),charactersIgnoringModifiers:String(character),isARepeat:false,keyCode:character == " " ? 49 : 0)!
            _ = draftController.handle(event,client:draftClient)
        }
        for c in "shang hai" { draftKey(c) }
        check(draftController.contextStatus.active,"译英草稿中已确认的上字也能作为连续上下文")
        draftKey(" ")
        check(draftClient.text.string == "上海" && draftClient.text.hasMarkedText(),"译英空格只确认上海，仍留在草稿，不调用模型")
        draftController.deactivateServer(draftClient)
        print("ALL \(checks) CONTEXT CANDIDATE TESTS PASSED")
    }
}
