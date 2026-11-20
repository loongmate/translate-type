import AppKit
import InputMethodKit
import Carbon

@main struct ControllerTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunControllerTests-" + UUID().uuidString)
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let previous = ConfigurationStore.shared.translateEnabled
        let previousLayout = ConfigurationStore.shared.pinyinLayout
        ConfigurationStore.shared.translateEnabled = false
        ConfigurationStore.shared.pinyinLayout = .fullPinyin
        defer { ConfigurationStore.shared.translateEnabled = previous; ConfigurationStore.shared.pinyinLayout = previousLayout }
        let server = IMKServer(name:"FangCunTests_" + UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        let client = TextClient()
        let controller = TTInputController(server:server,delegate:nil,client:client)!
        controller.activateServer(client)
        defer { controller.deactivateServer(client) }
        var timestamp: TimeInterval = 1
        @discardableResult
        func key(_ chars:String,_ code:UInt16 = 0,flags:NSEvent.ModifierFlags = []) -> Bool {
            timestamp += 0.02
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:timestamp,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars.lowercased(),isARepeat:false,keyCode:code)!
            return controller.handle(event,client:client)
        }
        func type(_ value:String) { for c in value { key(String(c)) } }
        func shift(_ down:Bool, elapsed:TimeInterval = 0.05) {
            timestamp += elapsed
            let event = NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:down ? [.shift] : [],timestamp:timestamp,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56)!
            _ = controller.handle(event,client:client)
        }
        func check(_ value:String,_ message:String) {
            precondition(client.text.string == value,"\(message): got \(client.text.string)")
            precondition(!client.text.hasMarkedText(),"\(message): text must be committed")
            print("PASS:",message)
        }
        type("nishuode"); key(" ",49)
        check("你说的","控制器默认中文：拼音加空格在 NSTextView 中文上屏")
        shift(true); shift(false); type("logo")
        check("你说的logo","轻按 Shift 后英文直输")
        precondition(client.selectedModes.isEmpty)
        precondition(controller.menu().items[1].state == .on)
        controller.deactivateServer(client); controller.activateServer(client)
        controller.setValue(InputSourceStatus.modeID,forTag:Int(kTextServiceInputModePropertyTag),client:client)
        precondition(controller.menu().items[1].state == .on)
        print("PASS: 英文为内部状态，不切换系统输入源，同一会话重新激活及模式回调后仍为英文")
        shift(true); shift(false); type("nihao"); key(" ",49)
        check("你说的logo你好","再次轻按 Shift 恢复中文候选与上屏")
        precondition(client.selectedModes.isEmpty)
        precondition(controller.menu().items[0].state == .on)
        print("PASS: Shift 切回中文仍使用同一个系统输入源")
        let nativeSelections = client.selectedModes.count
        controller.setValue(InputSourceStatus.modeID,forTag:Int(kTextServiceInputModePropertyTag),client:client)
        precondition(client.selectedModes.count == nativeSelections)
        print("PASS: 系统输入模式回调不递归切换模式")
        shift(true); key("A",0,flags:[.shift]); shift(false); key("\r",36)
        check("你说的logo你好A","Shift 配合字母保留大写，不切换输入语言")
        type("zhongwen"); key(" ",49)
        check("你说的logo你好A中文","输入大写英文后仍可继续中文")
        shift(true); shift(false)
        controller.deactivateServer(client)
        controller.selectedInputSourceChanged(to:"com.apple.keylayout.ABC")
        controller.activateServer(client)
        type("nihao"); key(" ",49)
        check("你说的logo你好A中文你好","切换到其他输入法再回来，恢复中文模式")
        shift(true)
        let click = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[.shift],timestamp:timestamp+0.01,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        _ = controller.handle(click,client:client)
        shift(false); type("nihao"); key(" ",49)
        check("你说的logo你好A中文你好你好","Shift 配合鼠标操作后仍是中文")
        type("tuopanlidelogo"); key(" ",49)
        check("你说的logo你好A中文你好你好托盘里的logo","控制器支持拼音夹英文")
        key("e",14,flags:[.control,.shift])
        type("nihao"); key(" ",49)
        precondition(client.text.hasMarkedText() && client.text.string.hasSuffix("你好"),"译英开启时保留中文草稿")
        let draftBeforeModeSwitch = client.text.string
        for english in [true,false] {
            shift(true); shift(false)
            controller.setValue(InputSourceStatus.modeID,forTag:Int(kTextServiceInputModePropertyTag),client:client)
            precondition(client.selectedModes.isEmpty && client.text.string == draftBeforeModeSwitch && client.text.hasMarkedText())
            precondition(controller.menu().items[english ? 1 : 0].state == .on)
            print("PASS: 内部中英切换及系统模式回调保留中文草稿：",english ? "英文" : "中文")
        }
        key("\r",36)
        check("你说的logo你好A中文你好你好托盘里的logo你好","译英草稿可确认中文上屏，全程没有翻译请求")
        key("e",14,flags:[.control,.shift])
        let base = client.text.string
        let start = base.utf16.count
        type("nihao")
        precondition(client.text.selectedRange().location == start+6)
        key("\u{f703}",124)
        precondition(client.text.selectedRange().location == start+6 && client.text.string == base+"ni hao","右键选择下一候选时不移动文本光标")
        key("\u{f702}",123)
        precondition(client.text.selectedRange().location == start+6,"左键从第二候选回到首项，仍不编辑拼音")
        for expected in [5,4,2] {
            key("\u{f702}",123)
            precondition(client.text.selectedRange() == NSRange(location:start+expected,length:0),"宿主输入框必须显示真实光标位置")
        }
        precondition(client.text.string == base+"nihao")
        key("m"); key("\u{8}",51)
        precondition(client.text.string == base+"nihao" && client.text.selectedRange().location == start+2,"插入、退格应作用于移动后的光标")
        for _ in 0..<3 { key("\u{f703}",124) }
        key(" ",49)
        check(base+"你好","真实文本视图的左右光标、编辑位置和最终选词一致")
        key("e",14,flags:[.control,.shift])
        type("nihao"); key(" ",49); type("nvhai")
        for _ in 0..<3 { key("\u{f702}",123) }
        precondition(client.text.string == base+"你好你好nühai" && client.text.selectedRange().location == start+6,"译英草稿前缀与 ü 均按 UTF-16 计算光标")
        let pendingText = client.text.string, pendingCaret = client.text.selectedRange()
        key("\r",36,flags:[.control])
        precondition(client.text.string == pendingText && client.text.selectedRange() == pendingCaret && client.text.hasMarkedText(),"Ctrl + Enter 在未选完时不提交、不清空、不移动光标")
        print("PASS: 真实客户端未选完时拦截 Ctrl + Enter 并完整保留输入")
        key("\u{1b}",53)
        check(base+"你好","取消预编辑不影响已上屏内容")
        // Drive the real controller and NSTextView, using a separate Rime
        // session only to read the candidate labels shown for this input.
        for translating in [false,true] {
            key("e",14,flags:[.control,.shift])
            let before = client.text.string
            let reference = try PinyinEngine()
            for c in "shi".unicodeScalars { _ = reference.process(Int(c.value)) }
            for _ in 0..<6 { _ = reference.process(0xff53) }
            _ = reference.process(0xff51)
            let state = reference.snapshot()
            let chosen = state.candidates[state.highlighted]
            type("shi")
            for _ in 0..<6 { key("\u{f703}",124) }
            key("\u{f702}",123)
            precondition(client.text.hasMarkedText() && client.text.string == before+"shi" && client.text.selectedRange().location == before.utf16.count+3,"跨页选择候选不能提前上屏或挪动输入光标")
            key(" ",49)
            if translating {
                precondition(client.text.hasMarkedText() && client.text.string == before+chosen,"译英模式按空格保留高亮候选为草稿")
                key("\r",36)
            }
            check(before+chosen,"\(translating ? "译英" : "中文")：真实客户端右移跨页、左移回选、空格确认对应候选")
        }
        if let i = CommandLine.arguments.firstIndex(of:"--capture-navigation"), CommandLine.arguments.count > i+1 {
            let session = CompositionSession(engine:try PinyinEngine(),translateEnabled:true)
            for c in "nihao".unicodeScalars { session.handle(key:Int(c.value)) }
            for _ in 0..<2 { session.handle(key:0xff53) }
            session.handle(key:0xff0d,control:true)
            let panel = CandidatePanel()
            panel.show(session:session,anchor:NSRect(x:100,y:400,width:1,height:20),settings:{})
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            let view = panel.contentView!
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]))
            panel.orderOut(nil)
        }
        key("e",14,flags:[.control,.shift]) // Back to direct Chinese output.
        let beforeDouble = client.text.string
        ConfigurationStore.shared.pinyinLayout = .sogou
        NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
        type("nihk")
        let composing = client.text.string, composingCaret = client.text.selectedRange()
        ConfigurationStore.shared.pinyinLayout = .flypy
        NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
        precondition(client.text.string == composing && client.text.selectedRange() == composingCaret,"切换方案不能重解释正在输入的双拼")
        key(" ",49)
        check(beforeDouble+"你好","搜狗双拼选完旧拼音后才切换新方案")
        type("nihc"); key(" ",49)
        check(beforeDouble+"你好你好","同一文本客户端立即使用小鹤双拼的新键位")
        controller.deactivateServer(client); controller.activateServer(client)
        type("nihc"); key(" ",49)
        check(beforeDouble+"你好你好你好","离开并恢复输入会话后记住双拼方案")

        for layout in PinyinLayout.allCases {
            ConfigurationStore.shared.pinyinLayout = layout
            NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
            for translating in [false,true] {
                if translating { key("e",14,flags:[.control,.shift]) }
                let before = client.text.string
                let reference = try PinyinEngine(layout:layout)
                for c in "ni".unicodeScalars { _ = reference.process(Int(c.value)) }
                let (_,state) = reference.process(0xff56)
                let expected = state.candidates[state.highlighted]
                precondition(state.page == 1)
                type("ni")
                let marked = client.text.string, caret = client.text.selectedRange()
                precondition(key("-",27),"首页减号不能泄漏给宿主")
                key("=",24); key("-",27)
                shift(true); key("+",24,flags:[.shift]); shift(false)
                key("+",69,flags:[.numericPad]); key("-",78,flags:[.numericPad])
                key("\u{f72c}",116); key("\u{f72d}",121)
                precondition(!key("+",24,flags:[.command,.shift]),"宿主放大快捷键应正常放行")
                precondition(client.text.string == marked && client.text.selectedRange() == caret && client.text.hasMarkedText(),"符号翻页保留预编辑文字和光标，不提前上屏")
                key(" ",49)
                if translating {
                    precondition(client.text.string == before+expected && client.text.hasMarkedText(),"翻页选择只进入译英草稿")
                    key("\r",36)
                }
                check(before+expected,"\(layout.name) / \(translating ? "译英" : "中文")：实际控制器的 -、=、Shift+加号、数字键盘加减、Page Up/Down 翻页后选词正确")
                if translating { key("e",14,flags:[.control,.shift]) }
            }
        }

        for layout in [PinyinLayout.fullPinyin,.sogou] {
            ConfigurationStore.shared.pinyinLayout = layout
            NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
            for translating in [false,true] {
                if translating { key("e",14,flags:[.control,.shift]) }
                let before = client.text.string
                var expectedSymbols = before
                for text in ["test@example.com","foo_bar_v2","cmd|grep","obj{key}","var$value","path~backup","baidu.com","www.baidu.com"] {
                    type(text)
                    precondition(client.text.string == expectedSymbols+text && client.text.hasMarkedText(),"\(text)：真实输入框符号不自动选词或上屏")
                    key(" ",49)
                    if translating { key("\r",36) }
                    expectedSymbols += text
                    check(expectedSymbols,"\(layout.name) / \(translating ? "译英" : "中文")：\(text) 原样确认")
                }
                let beforeProtocol = client.text.string
                shift(true); shift(false)
                let secureAddress = "https://code.aliyun.com:8443/a-b_v2?x=1+2&y=3#v4"
                type(secureAddress)
                if translating { key("\r",36) }
                check(beforeProtocol+secureAddress,"\(layout.name) / \(translating ? "译英" : "中文")：英文模式完整输入 HTTPS 地址，标点保留半角")
                shift(true); shift(false)
                let beforeBare = client.text.string
                let address = "code_aliyun.com/a-b_v2?x=1+2&y=3"
                type(address)
                precondition(client.text.string == beforeBare+address && client.text.hasMarkedText(),"网址应该完整原样显示在真实预编辑区")
                key("\u{f702}",123); key("\u{8}",51); key("=",24)
                let corrected = "code_aliyun.com/a-b_v2?x=1+2&y=3"
                key("\u{f703}",124)
                precondition(client.text.string == beforeBare+corrected && client.text.selectedRange().location == (beforeBare+corrected).utf16.count,"真实输入框的网址编辑光标准确")
                key("\r",36,flags:[.control])
                precondition(client.text.string == beforeBare+corrected && client.text.hasMarkedText(),"Ctrl+Enter 不替用户确认网址")
                key("\r",36)
                if translating {
                    precondition(client.text.string == beforeBare+corrected && client.text.hasMarkedText(),"译英模式 Enter 只确认网址到草稿")
                    key("\r",36)
                }
                check(beforeBare+corrected,"\(layout.name) / \(translating ? "译英" : "中文")：实际控制器的网址、数字符号、光标编辑与 Enter 原样确认")
                type(layout == .sogou ? "nihk" : "nihao"); key(".",47)
                precondition(client.text.string == beforeBare+corrected+"你好。" && client.text.hasMarkedText(),"未选拼音后的中文句号显示在真实预编辑区")
                if translating { key("\r",36); key("\r",36) }
                else { controller.commitComposition(client) }
                check(beforeBare+corrected+"你好。","\(layout.name)：原文确认后恢复中文，待定句号在确认草稿或宿主提交时上屏")
                let beforePunctuation = client.text.string
                var expectedPunctuation = beforePunctuation
                let punctuationKeys: [(String,UInt16,NSEvent.ModifierFlags,String)] = [
                    (",",43,[],"，"),("?",44,[.shift],"？"),("!",18,[.shift],"！"),
                    (":",41,[.shift],"："),("[",33,[],"【"),("]",30,[],"】"),
                    ("<",43,[.shift],"《"),(">",47,[.shift],"》"),
                    ("\"",39,[.shift],"“"),("\"",39,[.shift],"”")
                ]
                for (symbol,code,flags,mark) in punctuationKeys {
                    type(layout == .sogou ? "nihk" : "nihao")
                    precondition(key(symbol,code,flags:flags),"中文标点事件应由输入法处理")
                    expectedPunctuation += "你好"+mark
                    if translating {
                        precondition(client.text.hasMarkedText(),"译英模式标点只确认到草稿")
                        key("\r",36)
                    }
                    check(expectedPunctuation,"\(layout.name)：真实按键拼音接 \(symbol) 输出中文和 \(mark)")
                }
                if translating { key("e",14,flags:[.control,.shift]) }
            }
        }
        ConfigurationStore.shared.translateEnabled = false
        controller.deactivateServer(client); controller.activateServer(client)
        if let i = CommandLine.arguments.firstIndex(of:"--capture-settings"), CommandLine.arguments.count > i+1 {
            ConfigurationStore.shared.pinyinLayout = .flypy
            NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
            let beforeSettings = client.text.string
            let oldModel = ConfigurationStore.shared.model
            ConfigurationStore.shared.model = ModelConfiguration(endpoint:"http://127.0.0.1:18887/settings-test",model:"test-model")
            defer { ConfigurationStore.shared.model = oldModel }
            SettingsWindow.shared.show()
            let window = NSApp.windows.first(where: { $0.title == "方寸输入法 · 设置" })!
            func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let views = descendants(window.contentView!)
            let mode = views.first(where: { $0.identifier?.rawValue == "pinyin-mode" }) as! NSPopUpButton
            let layout = views.first(where: { $0.identifier?.rawValue == "double-pinyin-layout" }) as! NSPopUpButton
            precondition(mode.indexOfSelectedItem == 1 && layout.titleOfSelectedItem == "小鹤双拼")
            mode.selectItem(at:0); NSApp.sendAction(mode.action!,to:mode.target,from:mode)
            precondition(ConfigurationStore.shared.pinyinLayout == .fullPinyin && !layout.isEnabled)
            mode.selectItem(at:1); NSApp.sendAction(mode.action!,to:mode.target,from:mode)
            precondition(ConfigurationStore.shared.pinyinLayout == .flypy && layout.isEnabled,"回到双拼应记住上次方案")
            layout.selectItem(at:0); NSApp.sendAction(layout.action!,to:layout.target,from:layout)
            precondition(ConfigurationStore.shared.pinyinLayout == .sogou)
            type("nihk"); key(" ",49)
            check(beforeSettings+"你好","设置表单切换方案自动生效，无需模型配置或重启")
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            let path = CommandLine.arguments[i+1]
            try SettingsWindow.shared.capture(to:URL(fileURLWithPath:path+"-input.png"))
            let tabs = views.first(where: { $0 is NSTabView }) as! NSTabView
            tabs.selectTabViewItem(at:1)
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
            try SettingsWindow.shared.capture(to:URL(fileURLWithPath:path+"-translation.png"))
            window.close()
        }
        // macOS can supply its mode before activating a new controller.
        let earlyClient = TextClient()
        let earlyController = TTInputController(server:server,delegate:nil,client:earlyClient)!
        ConfigurationStore.shared.translateEnabled = false
        earlyController.setValue(InputSourceStatus.modeID,forTag:Int(kTextServiceInputModePropertyTag),client:earlyClient)
        earlyController.activateServer(earlyClient)
        let englishItem = earlyController.menu().items[1]
        NSApp.sendAction(englishItem.action!,to:englishItem.target,from:englishItem)
        func earlyType(_ input:String) {
            for c in input {
                let e = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:0,context:nil,characters:String(c),charactersIgnoringModifiers:String(c),isARepeat:false,keyCode:c == " " ? 49 : 0)!
                _ = earlyController.handle(e,client:earlyClient)
            }
        }
        earlyType("logo")
        precondition(earlyClient.text.string == "logo" && !earlyClient.text.hasMarkedText())
        precondition(earlyClient.selectedModes.isEmpty)
        print("PASS: 单一入口收到提前模式回调后，可通过菜单切为英文")
        ConfigurationStore.shared.pinyinLayout = .sogou
        NotificationCenter.default.post(name:.pinyinLayoutChanged,object:nil)
        let chineseItem = earlyController.menu().items[0]
        NSApp.sendAction(chineseItem.action!,to:chineseItem.target,from:chineseItem)
        earlyType("nihk ")
        precondition(earlyClient.text.string == "logo你好" && !earlyClient.text.hasMarkedText())
        print("PASS: 激活前已创建会话仍能响应拼音方案变化")
        earlyController.deactivateServer(earlyClient)
        print("ALL CONTROLLER TESTS PASSED")
    }
}
