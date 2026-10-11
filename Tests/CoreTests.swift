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
        let secureEndpoint = "http://localhost:18887/keychain-test-" + UUID().uuidString
        try SecureKeyStore.save("test-only-secret",endpoint:secureEndpoint)
        let read = try SecureKeyStore.read(endpoint:secureEndpoint)
        try SecureKeyStore.save("",endpoint:secureEndpoint)
        check(read == "test-only-secret","钥匙串真实保存读取与清理")
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
        print("ALL CORE TESTS PASSED")
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
