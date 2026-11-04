import Foundation
@main
struct CoreTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let oldDomain = "FangCunMigrationOld-" + UUID().uuidString
        let newDomain = "FangCunMigrationNew-" + UUID().uuidString
        let oldDefaults = UserDefaults(suiteName:oldDomain)!
        let newDefaults = UserDefaults(suiteName:newDomain)!
        defer {
            oldDefaults.removePersistentDomain(forName:oldDomain)
            newDefaults.removePersistentDomain(forName:newDomain)
        }
        let oldConfig = ModelConfiguration(endpoint:"http://localhost:18887/v1",model:"existing-model",instruction:"保留术语")
        oldDefaults.set(try JSONEncoder().encode(oldConfig),forKey:"modelConfiguration")
        oldDefaults.set(true,forKey:"translateEnabled")
        let migrated = ConfigurationStore(defaults:newDefaults,legacyDefaults:oldDefaults)
        check(migrated.model == oldConfig && migrated.translateEnabled,"更名迁移保留模型、特殊指令与译英开关")
        migrated.model = ModelConfiguration(model:"new-model")
        migrated.translateEnabled = false
        let reopened = ConfigurationStore(defaults:newDefaults,legacyDefaults:oldDefaults)
        check(reopened.model.model == "new-model" && !reopened.translateEnabled,"再次启动不覆盖新配置或关闭的译英开关")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateTypeTests-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:temp)
        defer { try? FileManager.default.removeItem(at:temp) }
        for layout in PinyinLayout.allCases {
            for translating in [false,true] {
                let punctuation = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:translating)
                var output = ""
                punctuation.onInsert = { output += $0 }
                let label = "\(layout.name) / \(translating ? "译英草稿" : "中文上屏")"
                func result() -> String { translating ? punctuation.draft : output }
                check(punctuation.handle(key:47) && result() == "、" && !punctuation.hasPendingInput,"\(label)：空输入按 / 直接确认顿号")
                for c in "ni".unicodeScalars { punctuation.handle(key:Int(c.value)) }
                check(punctuation.handle(key:47) && result() == "、" && punctuation.snapshot.input == "ni/","\(label)：未选字母后 / 保留原码和半角斜杠，不确认中文候选")
                punctuation.handle(key:32)
                check(result() == "、ni/" && !punctuation.hasPendingInput,"\(label)：空格明确确认含斜杠的原始片段")
                let before = result()
                check(!punctuation.handle(key:47,command:true) && result() == before,"\(label)：Command+/ 仍交给应用")
                check(punctuation.handle(key:63,shift:true) && result() == before+"？","\(label)：Shift+/ 仍为中文问号")
                let beforeBackslash = result()
                check(punctuation.handle(key:92) && result() == beforeBackslash+"、" && !punctuation.hasPendingInput,"\(label)：空输入按反斜杠直接确认顿号")
                let beforeLiteral = result()
                for c in "ni\\path".unicodeScalars { punctuation.handle(key:Int(c.value)) }
                check(punctuation.snapshot.input == "ni\\path" && result() == beforeLiteral,"\(label)：未选字母后的反斜杠保留原码，不确认中文候选")
                punctuation.handle(key:32)
                check(result() == beforeLiteral+"ni\\path" && !punctuation.hasPendingInput,"\(label)：空格完整确认含反斜杠的原始片段")
                check(!punctuation.handle(key:92,command:true),"\(label)：Command+反斜杠仍交给应用")
                let beforePipe = result()
                if !punctuation.handle(key:124,shift:true) { output += "|" }
                check(result() == beforePipe+"|" && !punctuation.hasPendingInput,"\(label)：Shift+反斜杠保留竖线（含交由宿主直输）")
                if translating { check(output.isEmpty && !punctuation.isTranslating,"\(label)：标点留在草稿，不上屏也不调用模型") }
                punctuation.setASCIIMode(true)
                let englishStart = result()
                let english = "https://a.b/c?x=1,2;ok!() C:\\path\\file"
                for c in english.unicodeScalars { punctuation.handle(key:Int(c.value)) }
                check(result() == englishStart+english,"\(label)：切英文后句点、斜杠及其他标点保持半角")
            }
        }
        let helloCodes: [PinyinLayout:String] = [.fullPinyin:"nihao",.sogou:"nihk",.flypy:"nihc",.natural:"nihk",.microsoft:"nihk",.abc:"nihk",.pinyinJiajia:"nihd",.ziguang:"nihq"]
        for layout in PinyinLayout.allCases {
            for translating in [false,true] {
                let literal = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:translating)
                var output = "", keyReads = 0
                literal.onInsert = { output += $0 }
                literal.readKey = { _ in keyReads += 1; throw AppError.message("网址测试不能调用模型") }
                let label = "\(layout.name) / \(translating ? "译英草稿" : "中文上屏")"
                func type(_ text:String) { for c in text.unicodeScalars { literal.handle(key:Int(c.value)) } }
                func result() -> String { translating ? literal.draft : output }
                let samples = ["code.aliyun.com","repo.aliyun.com/a-b_v2?x=1+2&y=3#v4","AliYun.com:8080/path,ok;yes!()","https:","https://code.aliyun.com:8443/a-b_v2?x=1+2&y=3#v4","http://localhost:3000/a?x=1","SSH://Host:22"]
                var expected = ""
                for (i,text) in samples.enumerated() {
                    for c in text.unicodeScalars { literal.handle(key:Int(c.value),shift:c == ":") }
                    check(literal.snapshot.input == text && literal.snapshot.preedit == text && literal.candidates == [text] && result() == expected && literal.hasPendingInput && !literal.asciiMode,"\(label)：\(text) 全段原样预编辑，不选中文、不改标点、不翻页")
                    literal.handle(key:0xff0d,control:true)
                    check(keyReads == 0 && !literal.isTranslating && literal.snapshot.input == text,"\(label)：未确认网址不能启动翻译或改变输入")
                    if i == 0 { literal.handle(key:0xff0d) }
                    else if i == 1 { literal.handle(key:32) }
                    else { literal.choose(0) }
                    expected += text
                    check(!literal.hasPendingInput && result() == expected && !literal.engine.isLiteralInput,"\(label)：Enter、空格或点击候选完整确认原始片段")
                    if translating { check(output.isEmpty,"\(label)：确认的原始片段只进入草稿，不提前上屏") }
                }
                type(helloCodes[layout]!)
                check(literal.candidates.contains("你好"),"\(label)：原样确认后自动恢复当前拼音方案")
                literal.choose(literal.candidates.firstIndex(of:"你好")!)
                type("."); expected += "你好。"
                check(result() == expected && !literal.hasPendingInput,"\(label)：明确选好中文后点号仍直接输入中文句号")
                literal.handle(key:58,shift:true); expected += "："
                check(result() == expected && !literal.hasPendingInput,"\(label)：明确选好中文后冒号仍直接输入中文冒号")
                type("nihao:")
                check(literal.snapshot.input == "nihao:" && result() == expected,"\(label)：冒号不猜测协议名称或拼音，nihao: 也保留原码")
                literal.discardPendingInput()
                type("nihao.")
                check(literal.snapshot.input == "nihao." && result() == expected,"\(label)：点号不猜测英文或拼音，nihao. 也保留原码")
                literal.discardPendingInput()
                type("code.aliyun.cmo")
                for _ in 0..<2 { literal.handle(key:0xff51) }
                literal.handle(key:0xffff); literal.handle(key:0xff53); type("m")
                check(literal.snapshot.input == "code.aliyun.com" && literal.snapshot.caret == 15,"\(label)：网址中左右移动、前向删除和插入作用于真实光标")
                literal.handle(key:0xff57); literal.handle(key:0xff08)
                check(literal.snapshot.input == "code.aliyun.co","\(label)：End 后退格删除一个原始字符，不撤销选词")
                literal.handle(key:0xff50); literal.handle(key:0xff08)
                check(literal.snapshot.input == "code.aliyun.co" && literal.snapshot.caret == 0,"\(label)：Home 和开头退格不损坏原始片段")
                literal.discardPendingInput()
                type("code.")
                for _ in 0..<5 { literal.handle(key:0xff08) }
                check(!literal.hasPendingInput && !literal.engine.isLiteralInput,"\(label)：删除完整片段后恢复普通中文输入")
                type("code."); literal.setASCIIMode(true); type("aliyun.com"); literal.setASCIIMode(false)
                expected += "code.aliyun.com"
                check(result() == expected && !literal.hasPendingInput,"\(label)：片段中切英文保留已有原码，切回后不残留直输状态")
                type("code.aliyun.com")
                literal.flushOriginal(); expected += "code.aliyun.com"
                check(output == expected && !literal.hasPendingInput && !literal.engine.isLiteralInput,"\(label)：失焦提交完整原始片段并清理状态")
            }
        }
        for translating in [false,true] {
            let partial = CompositionSession(engine:try PinyinEngine(),translateEnabled:translating)
            var output = ""
            partial.onInsert = { output += $0 }
            for c in "nihao".unicodeScalars { partial.handle(key:Int(c.value)) }
            partial.choose(partial.candidates.firstIndex(of:"你")!)
            partial.handle(key:46)
            check(partial.snapshot.input == "你hao." && partial.markedText == "你hao.","点号保留 Rime 中已经选好的中文前缀，只将未选尾部转为原码")
            partial.handle(key:32)
            check((translating ? partial.draft : output) == "你hao.","原样确认片段不把已选中文前缀还原为拼音")
            let middle = CompositionSession(engine:try PinyinEngine(),translateEnabled:translating)
            for c in "nvhai".unicodeScalars { middle.handle(key:Int(c.value)) }
            for _ in 0..<3 { middle.handle(key:0xff51) }
            middle.handle(key:46)
            check(middle.snapshot.input == "nv.hai" && middle.snapshot.caret == 3,"拼音光标中途按点保留后方输入，并按原始字母定位（含 ü 格式化）")
            let colon = CompositionSession(engine:try PinyinEngine(),translateEnabled:translating)
            for c in "nihao".unicodeScalars { colon.handle(key:Int(c.value)) }
            colon.choose(colon.candidates.firstIndex(of:"你")!)
            colon.handle(key:58,shift:true)
            check(colon.snapshot.input == "你hao:" && colon.markedText == "你hao:","冒号保留已选中文前缀，不确认未选尾部")
            let tab = CompositionSession(engine:try PinyinEngine(),translateEnabled:translating)
            var tabOutput = ""
            tab.onInsert = { tabOutput += $0 }
            for c in "code.aliyun.com".unicodeScalars { tab.handle(key:Int(c.value)) }
            check(!tab.handle(key:0xff09) && tabOutput == "code.aliyun.com" && !tab.hasPendingInput,"网址中 Tab 完整提交原文后交给宿主切换焦点")
            let deferred = CompositionSession(engine:try PinyinEngine(),translateEnabled:translating)
            for c in "code.aliyun.com".unicodeScalars { deferred.handle(key:Int(c.value)) }
            try deferred.requestPinyinLayout(.sogou)
            check(deferred.pinyinLayout == .fullPinyin && deferred.pendingPinyinLayout == .sogou && deferred.snapshot.input == "code.aliyun.com","网址未确认时切换拼音方案不重解释片段")
            deferred.handle(key:32)
            check(deferred.pinyinLayout == .sogou && !deferred.hasPendingInput,"确认网址后应用待切换的拼音方案")
        }
        var config = ModelConfiguration(endpoint:"http://127.0.0.1:18887/v1",model:"test-model",instruction:"")
        var inserted = ""
        let session = CompositionSession(engine:try PinyinEngine(),translateEnabled:false)
        session.configuration = { config }; session.readKey = { _ in "" }; session.onInsert = { inserted += $0 }
        func type(_ text:String) { for scalar in text.unicodeScalars { _ = session.handle(key:Int(scalar.value)) } }
        type("nihao")
        check(session.candidates.contains("你好"),"真实拼音词库产生中文候选")
        _ = session.handle(key:32)
        check(inserted == "你好","中文模式选词直接上屏")
        let navigation = CompositionSession(engine:try PinyinEngine(),translateEnabled:false)
        var navigationOutput = ""
        navigation.onInsert = { navigationOutput += $0 }
        func navigationType(_ value:String) { for c in value.unicodeScalars { navigation.handle(key:Int(c.value)) } }
        navigationType("nihao")
        let fullPreedit = navigation.snapshot.preedit
        let fullCandidates = navigation.candidates
        navigation.handle(key:0xff53)
        check(navigation.highlighted == 1 && navigation.candidates == fullCandidates && navigation.snapshot.caret == fullPreedit.utf16.count,"拼音末尾按右键选择第二候选，不绕回拼音")
        navigation.handle(key:0xff51)
        check(navigation.highlighted == 0 && navigation.snapshot.caret == fullPreedit.utf16.count,"候选中按左键先回首项，不移动拼音光标")
        for expected in [5,4,2,1,0,0] {
            check(navigation.handle(key:0xff51) && navigation.snapshot.caret == expected,"左键逐字移动，开头不循环：\(expected)")
            check(navigation.snapshot.input == "nihao" && navigationOutput.isEmpty,"移动光标不改原始拼音、不确认候选")
        }
        for _ in 0..<5 { navigation.handle(key:0xff53) }
        check(navigation.snapshot.caret == fullPreedit.utf16.count && navigation.candidates == fullCandidates,"光标移回末尾后恢复完整词组候选")
        navigation.handle(key:0xff54)
        check(navigation.highlighted == 1 && navigation.snapshot.input == "nihao","下键只移动候选高亮")
        navigation.handle(key:0xff52); navigation.handle(key:32)
        check(navigationOutput == "你好","上键返回第一候选，空格确认你好")
        navigationType("nihaoo"); navigation.handle(key:0xff51); navigation.handle(key:0xff08)
        check(navigation.snapshot.input == "nihao","移动后退格删除光标前的字母")
        navigation.handle(key:0xff53); navigation.handle(key:32)
        check(navigationOutput == "你好你好","拼音中途纠错后仍可正常选词")
        navigationType("nvhai")
        check(navigation.snapshot.preedit == "nü hai" && navigation.snapshot.caret == 6 && navigation.snapshot.selectionEnd == 6,"ü 的 UTF-8 字节位置转换成文本光标位置")
        for _ in 0..<3 { navigation.handle(key:0xff51) }
        check(navigation.snapshot.preedit == "nühai" && navigation.snapshot.caret == 2,"光标在 ü 后时不会错位")
        navigation.handle(key:0xff1b)
        navigation.setTranslateEnabled(true); navigationType("nihao"); navigation.handle(key:32)
        navigationType("nihao")
        for _ in 0..<3 { navigation.handle(key:0xff51) }
        check(navigation.markedText == "你好nihao" && navigation.markedCaret == 4 && navigation.draft == "你好","译英草稿的光标加上已选中文长度，不误删原文")
        navigation.handle(key:0xff1b)
        let pending = CompositionSession(engine:try PinyinEngine(),translateEnabled:true)
        pending.configuration = { config }
        var keyReads = 0
        pending.readKey = { _ in keyReads += 1; return "" }
        let beforePending = try await count()
        func pendingType(_ value:String) { for c in value.unicodeScalars { pending.handle(key:Int(c.value)) } }
        func blockedTranslation(_ message:String) {
            let state = pending.snapshot, draft = pending.draft
            check(!pending.canRequestTranslation,"未选完时禁用翻译入口："+message)
            check(pending.handle(key:0xff0d,control:true),"拦截未选完时的 Ctrl + Enter，不传给宿主应用")
            pending.requestTranslation() // Same guard protects the button and future callers.
            check(pending.snapshot.input == state.input && pending.snapshot.preedit == state.preedit && pending.snapshot.caret == state.caret && pending.snapshot.candidates == state.candidates && pending.snapshot.highlighted == state.highlighted && pending.draft == draft && !pending.isTranslating && pending.translation == nil,"未确认的输入完整保留："+message)
        }
        blockedTranslation("空草稿")
        pendingType("nihao"); blockedTranslation("末尾仍有完整候选")
        pending.handle(key:0xff53); blockedTranslation("右键只高亮候选，不代表选词完成")
        pending.handle(key:0xff51)
        for _ in 0..<3 { pending.handle(key:0xff51) }
        blockedTranslation("ni 后仍有 hao，禁止只取你并丢掉后半段")
        pending.handle(key:32)
        check(pending.snapshot.preedit == "你hao","空格只确认前半个词，剩余拼音待选")
        blockedTranslation("部分选词后仍有剩余拼音")
        pending.handle(key:32)
        check(pending.draft == "你好" && pending.canRequestTranslation,"选词全部完成后允许翻译")
        pendingType("nihao"); blockedTranslation("已有中文草稿加未确认拼音")
        check(try await count() == beforePending && keyReads == 0,"所有未选完的尝试均零模型请求、零密钥读取")
        pending.handle(key:32)
        check(pending.draft == "你好你好" && pending.canRequestTranslation,"继续空格选词可恢复翻译入口")
        pending.handle(key:0xff0d,control:true); pending.handle(key:0xff0d,control:true)
        try await until { !pending.isTranslating }
        let pendingRequests = try await requests()
        let pendingMessages = pendingRequests.last?["messages"] as? [[String:String]]
        check(pending.translation == "Hello." && keyReads == 1 && pendingMessages?.last?["content"] == "你好你好" && pendingRequests.count == beforePending+1,"选完后只请求一次，翻译完整已确认草稿")
        let baseline = try await count()
        session.setTranslateEnabled(true); inserted = ""
        type("nihao"); _ = session.handle(key:32)
        check(session.draft == "你好" && inserted.isEmpty,"译英模式选词只累计中文，不上屏")
        check(try await count() == baseline,"打字和选词期间零模型请求")
        session.requestTranslation(); session.requestTranslation()
        try await until { !session.isTranslating }
        check(session.translation == "Hello.","真实 HTTP 请求解析英文译文；错误：\(session.errorMessage ?? "无")；结果：\(session.translation ?? "无")")
        check(try await count() == baseline+1,"重复确认只发一次请求")
        _ = session.handle(key:0xff1b)
        session.requestTranslation()
        check(session.translation == "Hello.","相同文本配置复用本次缓存")
        check(try await count() == baseline+1,"复用缓存无新调用")
        _ = session.handle(key:0xff0d)
        check(inserted == "Hello." && session.markedText.isEmpty,"确认英文上屏，清空原文与候选")
        check(try await count() == baseline+1,"英文上屏不产生请求")
        type("nihao"); _ = session.handle(key:32)
        config.instruction = "请使用商务礼貌语气。"
        session.configurationChanged(); session.requestTranslation()
        try await until { !session.isTranslating }
        let records = try await requests()
        let lastMessages = records.last?["messages"] as? [[String:String]]
        check(lastMessages?.first?["content"]?.contains(config.instruction) == true,"特殊指令随整句请求一起发送")
        _ = session.handle(key:50)
        check(inserted == "Hello.你好","可选择原文中文上屏")
        type("nihao"); _ = session.handle(key:32)
        config.instruction = "新的指令"
        session.configurationChanged(); session.requestTranslation()
        try await untilAsync { try await count() >= baseline+3 }
        _ = session.handle(key:0xff08)
        try await Task.sleep(nanoseconds:400_000_000)
        check(session.draft == "你" && session.translation == nil,"编辑原文取消请求，旧结果不能覆盖新内容")
        session.flushOriginal()
        type("nihao"); _ = session.handle(key:32)
        config.endpoint = "http://127.0.0.1:18887/error/v1"
        session.configurationChanged(); session.requestTranslation()
        try await until { !session.isTranslating }
        check(session.errorMessage != nil && session.draft == "你好","错误响应保留中文，不自动重试")
        let failures = try await count()
        try await Task.sleep(nanoseconds:300_000_000)
        check(try await count() == failures,"失败后无后台调用")
        _ = session.handle(key:0xff0d)
        check(inserted.hasSuffix("你好"),"失败后可直接中文上屏")
        for invalid in ["http://example.com/v1","file:///tmp/foo","https://user:secret@example.com/v1"] {
            check(ModelConfiguration(endpoint:invalid).requestURL == nil,"拒绝无效或不安全接口：\(invalid)")
        }
        check(ModelConfiguration(instruction:"  \n ").effectiveInstruction == ModelConfiguration.defaultInstruction,"空白特殊指令使用默认规则")
        let secureEndpoint = "http://localhost:18887/local-key-test-" + UUID().uuidString
        let keys = APIKeyStore(file:temp.appendingPathComponent("Credentials/api-keys.json"))
        try await keys.save("test-only-secret",endpoint:secureEndpoint)
        let read = try await keys.read(endpoint:secureEndpoint)
        try await keys.save("",endpoint:secureEndpoint)
        check(read == "test-only-secret","本机私有文件保存、读取与清空 API Key，无钥匙串访问")
        for path in ["redirect","malformed"] {
            config.endpoint = "http://127.0.0.1:18887/\(path)/v1"
            do { _ = try await TranslationClient().translate("你好",configuration:config,apiKey:""); fatalError("错误接口不能成功") }
            catch { print("PASS: \(path) 响应安全失败") }
        }
        let beforeTyping = try await count()
        let mixed = CompositionSession(engine:try PinyinEngine(),translateEnabled:false)
        var mixedOutput = ""
        mixed.onInsert = { mixedOutput += $0 }
        func mixedType(_ text:String) { for scalar in text.unicodeScalars { _ = mixed.handle(key:Int(scalar.value)) } }
        for (input,expected) in [("zhichiAPI","支持API"),("woyaoxiugaiBug","我要修改Bug"),("zhegeApphenhao","这个App很好"),("tuopanlidelogo","托盘里的logo"),("shurufa","输入法"),("mingtianwomenquhaibian","明天我们去海边"),("nvhai","女孩"),("lvse","绿色"),("xi'an","西安"),("nihaologo","你好logo"),("woyaoxiugaibug","我要修改bug"),("zhegeapphenhao","这个app很好"),("women","我们")] {
            mixedOutput = ""; mixedType(input); _ = mixed.handle(key:32)
            check(mixedOutput == expected,"全拼与中英混输："+input+" → "+expected)
        }
        mixedOutput = ""; mixedType("logo"); _ = mixed.handle(key:0xff0d)
        check(mixedOutput == "logo","Enter 保留未选词的英文字母，不使用显示拼音的分隔空格")
        mixedOutput = ""; mixed.setASCIIMode(true); mixedType("Hello, API_2!")
        check(mixedOutput == "Hello, API_2!" && mixed.markedText.isEmpty,"英文直输保留大小写、半角标点、数字与下划线")
        mixed.setASCIIMode(false); mixed.setTranslateEnabled(true); mixedOutput = ""
        mixedType("nihao"); _ = mixed.handle(key:32); mixed.setASCIIMode(true); mixedType(" logo")
        mixed.setASCIIMode(false)
        check(mixed.draft == "你好 logo" && mixedOutput.isEmpty,"临时英文输入保留待译中文，不提前上屏")
        mixed.flushOriginal()
        mixedType("nihaologo"); _ = mixed.handle(key:32)
        check(mixed.draft == "你好logo","拼音夹英文原样进入整句翻译草稿")
        check(try await count() == beforeTyping,"全拼、中英混输和模式切换均不调用模型")
        var tap = ShiftTap()
        check(!tap.flagsChanged(shift:true,otherModifier:false) && tap.flagsChanged(shift:false,otherModifier:false),"单独轻按 Shift 切换输入语言")
        _ = tap.flagsChanged(shift:true,otherModifier:false); tap.keyDown()
        check(!tap.flagsChanged(shift:false,otherModifier:false),"Shift 输入大写不会切换语言")
        _ = tap.flagsChanged(shift:true,otherModifier:true)
        check(!tap.flagsChanged(shift:false,otherModifier:false),"Shift 组合快捷键不会切换语言")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:10)
        check(!tap.flagsChanged(shift:false,otherModifier:false,keyCode:56,timestamp:11),"长按 Shift 不误切英文")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:20)
        _ = tap.flagsChanged(shift:true,otherModifier:true,keyCode:55,timestamp:20.1)
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:55,timestamp:20.2)
        check(!tap.flagsChanged(shift:false,otherModifier:false,keyCode:56,timestamp:20.3),"系统截获快捷键时，其他修饰键事件仍会取消 Shift 切换")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:30)
        tap.keyDown()
        check(!tap.flagsChanged(shift:false,otherModifier:false,keyCode:56,timestamp:30.1),"Shift 配合鼠标选中内容不切英文")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:60,timestamp:40)
        check(tap.flagsChanged(shift:false,otherModifier:false,keyCode:60,timestamp:40.1),"右 Shift 也支持轻按切换")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:50)
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:50.02)
        check(tap.flagsChanged(shift:false,otherModifier:false,keyCode:56,timestamp:50.1),"重复 Shift 按下通知不取消单击切换")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:60,timestamp:60)
        tap.keyDown()
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:60,timestamp:60.02)
        check(!tap.flagsChanged(shift:false,otherModifier:false,keyCode:60,timestamp:60.1),"重复通知不重新激活已被打字取消的 Shift")
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:70)
        _ = tap.flagsChanged(shift:true,otherModifier:false,keyCode:56,timestamp:70.4)
        check(!tap.flagsChanged(shift:false,otherModifier:false,keyCode:56,timestamp:70.6),"重复通知不重置长按计时")
        let deepSeekBody = try JSONSerialization.jsonObject(with:TranslationClient.requestBody("你好",configuration:ModelConfiguration(endpoint:"https://api.deepseek.com",model:"deepseek-flash"))) as! [String:Any]
        check((deepSeekBody["thinking"] as? [String:String])?["type"] == "disabled","DeepSeek 请求明确关闭思考模式")
        let genericBody = try JSONSerialization.jsonObject(with:TranslationClient.requestBody("你好",configuration:ModelConfiguration(endpoint:"http://localhost:18887/v1",model:"test"))) as! [String:Any]
        check(genericBody["thinking"] == nil,"通用兼容协议不混入 DeepSeek 专属参数")
        let beforeNavigation = try await count()
        try candidateNavigationTests()
        check(try await count() == beforeNavigation,"候选导航、跨页和拼音编辑全程零模型请求")
        try await slowCredentialTests(temp:temp)
        print("ALL CORE TESTS PASSED")
    }
    @MainActor static func slowCredentialTests(temp:URL) async throws {
        for editor in [false,true] {
            let started = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
            var firstRead = true
            let keys = APIKeyStore(file:temp.appendingPathComponent("slow-\(editor)/api-keys.json")) { url in
                precondition(!Thread.isMainThread)
                if firstRead {
                    firstRead = false; started.signal(); _ = release.wait(timeout:.now()+5); finished.signal()
                }
                return try Data(contentsOf:url)
            }
            let values = ["http://127.0.0.1:18887/v1":"synthetic-slow-key"]
            try FileManager.default.createDirectory(at:keys.file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(values).write(to:keys.file)
            let s = CompositionSession(engine:try PinyinEngine(),translateEnabled:true)
            if editor { s.beginEditor() }
            s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/v1",model:"mock-model") }
            s.readKey = { try await keys.read(endpoint:$0) }
            s.setASCIIMode(true)
            for c in "source".unicodeScalars { s.handle(key:Int(c.value)) }
            let before = try await count()
            s.requestTranslation(); s.requestTranslation()
            var entered = false
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds:10_000_000)
                if started.wait(timeout:.now()) == .success { entered = true; break }
            }
            check(entered && s.isTranslating,"\(editor ? "编辑区" : "候选框")：模拟后台密钥读取被阻塞")
            let time = Date()
            s.handle(key:120)
            check(Date().timeIntervalSince(time) < 0.2 && s.draft == "sourcex" && !s.isTranslating,"慢密钥读取期间仍可立即打字，并取消旧请求")
            release.signal()
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds:10_000_000)
                if finished.wait(timeout:.now()) == .success { break }
            }
            try await Task.sleep(nanoseconds:100_000_000)
            check(try await count() == before && s.translation == nil && s.errorMessage == nil,"取消后迟到的密钥不会发送 HTTP 请求、显示旧错误或覆盖草稿")
            // A new request uses the now-local key and sends the edited text.
            s.requestTranslation(); try await until { !s.isTranslating }
            check(try await count() == before+1 && s.translation == "Hello.","密钥读取恢复后可正常执行新请求")
        }
    }
    @MainActor static func candidateNavigationTests() throws {
        for translating in [false,true] {
            let mode = translating ? "译英" : "中文"
            let session = CompositionSession(engine:try PinyinEngine(),translateEnabled:translating)
            var output = ""
            session.onInsert = { output += $0 }
            session.readKey = { _ in fatalError("候选导航不应读取密钥") }
            func type(_ value:String) { for c in value.unicodeScalars { session.handle(key:Int(c.value)) } }
            func index() -> Int { session.snapshot.page * 5 + session.highlighted }
            func move(_ key:Int,_ expected:Int) {
                check(session.handle(key:key) && index() == expected && session.snapshot.caret == session.snapshot.preedit.utf16.count && session.snapshot.input == "shi" && output.isEmpty && session.draft.isEmpty,"\(mode)：方向键高亮全局第 \(expected+1) 项，不编辑或提交拼音")
            }
            type("shi")
            let firstPage = session.candidates
            check(session.handle(key:0xff52) && index() == 0 && session.snapshot.caret == 3,"\(mode)：首项按上键停住，不把按键泄漏给宿主")
            for expected in 1...6 { move(0xff53,expected) }
            check(session.snapshot.page == 1 && session.highlighted == 1,"\(mode)：右键越过第五项后自动显示下一页")
            for expected in stride(from:5,through:0,by:-1) { move(0xff51,expected) }
            check(session.candidates == firstPage,"\(mode)：第二页首项向左回上一页末项，最终回到全局首项")
            for expected in [2,1,0,0] {
                session.handle(key:0xff51)
                check(session.snapshot.caret == expected && session.snapshot.input == "shi","\(mode)：首项后继续左移才编辑拼音，到开头停止")
            }
            for expected in 1...3 {
                session.handle(key:0xff53)
                check(session.snapshot.caret == expected && index() == 0,"\(mode)：拼音中向右逐字移回末尾，不提前选候选")
                if expected == 1 {
                    check(session.handle(key:0xff54) && index() == 1 && session.snapshot.caret == 1,"\(mode)：拼音编辑中下键仍可选候选，不移动光标")
                    check(session.handle(key:0xff52) && index() == 0 && session.snapshot.caret == 1,"\(mode)：拼音编辑中上键仍可返回上一候选")
                }
            }
            move(0xff53,1); move(0xff53,2)
            let selected = session.candidates[2]
            session.handle(key:32)
            check(!session.hasPendingInput && (translating ? session.draft == selected && output.isEmpty : output == selected),"\(mode)：空格确认第三个高亮项，不强制选择第一项")
            if translating { session.handle(key:0xff0d) }
            check(output == selected,"\(mode)：最终输出与刚才高亮的候选完全一致")

            session.handle(key:0xff1b); output = ""
            type("shi"); session.handle(key:0xff56)
            check(index() == 5,"\(mode)：Page Down 进入下一页首项")
            move(0xff51,4)
            session.handle(key:0xff1b)
            type("lv")
            var reachedLast = false
            for _ in 0..<512 {
                let previous = index()
                session.handle(key:0xff53)
                if index() == previous { reachedLast = true; break }
                check(index() == previous+1,"\(mode)：连续向右不跳过候选")
            }
            let last = index()
            for _ in 0..<3 { session.handle(key:0xff53) }
            check(reachedLast && session.snapshot.lastPage && index() == last && session.snapshot.input == "lv" && session.snapshot.caret == session.snapshot.preedit.utf16.count,"\(mode)：最后候选继续右移停住，不循环或进入拼音")
            check(session.handle(key:0xff54) && index() == last,"\(mode)：末项按下键停住，不泄漏给宿主")
            session.handle(key:0xff51)
            check(index() == last-1,"\(mode)：末项停住后仍能向左选择上一项")
            session.handle(key:0xff1b)

            type("nihao")
            // Earlier selections train Rime's test dictionary; locate a short
            // candidate instead of assuming it always remains in slot three.
            let partialIndex = session.candidates.firstIndex(where: { $0.count == 1 })!
            for _ in 0..<partialIndex { session.handle(key:0xff53) }
            let prefix = session.candidates[session.highlighted]
            session.handle(key:32)
            check(session.hasPendingInput && session.snapshot.preedit.hasPrefix(prefix) && output.isEmpty && !session.canRequestTranslation,"\(mode)：右键选择短候选后保留未选的 hao")
            session.handle(key:0xff53)
            let suffix = session.candidates[session.highlighted]
            session.handle(key:32)
            check(!session.hasPendingInput && (translating ? session.draft == prefix+suffix : output == prefix+suffix),"\(mode)：剩余拼音可继续右键选词，空格按两次选择组合结果")
        }
    }
    static func check(_ condition:Bool,_ message:String) { if !condition { fatalError(message) }; print("PASS: "+message) }
    static func requests() async throws -> [[String:Any]] {
        let (data,_) = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:18887/count")!)
        let object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        return object["requests"] as! [[String:Any]]
    }
    static func count() async throws -> Int { try await requests().count }
    @MainActor static func until(_ condition:()->Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds:50_000_000) }
        fatalError("异步操作未在 5 秒内结束")
    }
    static func untilAsync(_ condition:()async throws->Bool) async throws {
        for _ in 0..<100 { if try await condition() { return }; try await Task.sleep(nanoseconds:50_000_000) }
        fatalError("测试请求未开始")
    }
}
