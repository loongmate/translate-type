import Foundation

@main struct DoublePinyinTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let domain = "FangCunLayoutTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let store = ConfigurationStore(defaults:defaults)
        check(store.pinyinLayout == .fullPinyin,"旧配置默认保留全拼")
        store.pinyinLayout = .flypy; store.pinyinLayout = .fullPinyin
        let reopened = ConfigurationStore(defaults:defaults)
        check(reopened.pinyinLayout == .fullPinyin && reopened.lastDoublePinyinLayout == .flypy,"全拼与双拼之间切换后记住上次双拼方案")
        defaults.set("unknown-layout",forKey:"pinyinLayout")
        check(reopened.pinyinLayout == .fullPinyin,"未知方案安全回退全拼")
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunDoubleTests-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let fixtures: [(PinyinLayout,String,String,String)] = [
            (.sogou,"nihk","vswf","bzj;"), (.flypy,"nihc","vswf","bwjk"),
            (.natural,"nihk","vswf","bzjy"), (.microsoft,"nihk","vswf","bzj;"),
            (.abc,"nihk","aswf","bqjy"), (.pinyinJiajia,"nihd","vywr","bwjq"),
            (.ziguang,"nihq","uhww","bkj;")
        ]
        for (layout,hello,chinese,beijing) in fixtures {
            for (code,expected) in [(hello,"你好"),(chinese,"中文"),(beijing,"北京")] {
                let session = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:false)
                var result = ""; session.onInsert = { result += $0 }
                type(code,in:session)
                check(session.candidates.contains(expected),"\(layout.name)：\(code) 候选包含 \(expected)，实际 \(session.candidates)")
                session.handle(key:32)
                check(result == expected && session.markedText.isEmpty,"\(layout.name)：空格上屏 \(expected)")
            }
            let mixed = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:true)
            type(hello+"logo",in:mixed)
            // logo also spells Chinese syllables in double pinyin. Select
            // the intended Chinese prefix, then the literal English word.
            let prefixIndex = mixed.candidates.firstIndex(of:"你好")!
            mixed.choose(prefixIndex)
            check(mixed.hasPendingInput && mixed.candidates.contains("logo"),"\(layout.name)：选完中文前缀后，剩余英文仍可选择，实际 \(mixed.candidates)")
            mixed.choose(mixed.candidates.firstIndex(of:"logo")!)
            check(mixed.draft == "你好logo" && mixed.canRequestTranslation,"\(layout.name)：连续双拼夹英文选词不丢字，完成后才可翻译")
            let literal = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:false)
            var literalOutput = ""; literal.onInsert = { literalOutput += $0 }
            type("API",in:literal)
            check(literal.candidates.contains("API"),"\(layout.name)：大写英文保留原码与大小写")
            literal.choose(literal.candidates.firstIndex(of:"API")!)
            type("logo",in:literal); literal.handle(key:0xff0d)
            literal.setASCIIMode(true); type(" App_v2;",in:literal)
            check(literalOutput == "APIlogo App_v2;","\(layout.name)：英文候选、Enter 原样字母与英文直输均可使用")
            literal.setASCIIMode(false); literalOutput = ""
            type(";",in:literal)
            check(literalOutput == "；","\(layout.name)：空输入时分号仍作为标点")
            let zero = (layout == .flypy || layout == .natural) ? "aa" : "oa"
            type(zero,in:literal)
            check(literal.candidates.contains("啊"),"\(layout.name)：零声母编码 \(zero) 可输入啊")
            literal.handle(key:0xff1b)
            for translating in [false,true] {
                let s = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:translating)
                var output = ""; s.onInsert = { output += $0 }
                s.readKey = { _ in fatalError("未选完双拼不能读取密钥或调用模型") }
                type("ni",in:s)
                s.handle(key:0xff0d,control:true)
                check(output.isEmpty && s.snapshot.input == "ni" && !s.isTranslating,"\(layout.name)：未选词时不触发翻译")
                for _ in 0..<5 { s.handle(key:0xff53) }
                check(s.snapshot.page == 1 && s.highlighted == 0,"\(layout.name)：右键连续跨页")
                s.handle(key:0xff51)
                check(s.snapshot.page == 0 && s.highlighted == 4,"\(layout.name)：左键回到上一页末项")
                let expected = s.candidates[4]
                s.handle(key:32)
                check(translating ? s.draft == expected && output.isEmpty : output == expected,"\(layout.name)：空格提交跨页回选的高亮项")
                s.handle(key:0xff1b); output = ""
                type(hello,in:s)
                s.handle(key:0xff51); type("x",in:s); s.handle(key:0xff08)
                check(s.snapshot.input == hello,"\(layout.name)：双拼内部插入和退格按光标位置编辑")
                s.handle(key:0xff53); s.handle(key:32)
                check(translating ? s.draft == "你好" : output == "你好","\(layout.name)：编辑后回末尾能正常确认整词")
            }
        }
        try switchingTests()
        print("ALL DOUBLE PINYIN TESTS PASSED")
    }
    @MainActor static func switchingTests() throws {
        let s = CompositionSession(engine:try PinyinEngine(layout:.sogou),translateEnabled:true)
        var output = ""; s.onInsert = { output += $0 }
        type("nihk",in:s); s.handle(key:32)
        type("vswf",in:s); s.handle(key:0xff51); s.handle(key:0xff51)
        let state = s.snapshot
        try s.requestPinyinLayout(.flypy)
        check(s.pinyinLayout == .sogou && s.pendingPinyinLayout == .flypy && s.snapshot.input == state.input && s.snapshot.preedit == state.preedit && s.snapshot.caret == state.caret && s.candidates == state.candidates && s.draft == "你好" && output.isEmpty,"移动光标后切方案，保留旧方案、候选、中文草稿和未选尾部")
        s.handle(key:0xff53); s.handle(key:0xff53); s.handle(key:32)
        check(s.pinyinLayout == .flypy && s.pendingPinyinLayout == nil && s.draft == "你好中文" && output.isEmpty,"完成整段拼音后切方案，中文草稿保留不提前上屏")
        type("nihc",in:s); s.handle(key:32)
        check(s.draft == "你好中文你好","同一待译草稿可跨双拼方案继续输入")
        try s.requestPinyinLayout(.fullPinyin)
        type("shijie",in:s); s.handle(key:32)
        check(s.draft == "你好中文你好世界" && s.canRequestTranslation,"切回全拼可继续同一整段草稿")
        type("nihao",in:s)
        try s.requestPinyinLayout(.sogou); try s.requestPinyinLayout(.fullPinyin)
        check(s.pendingPinyinLayout == nil && s.snapshot.input == "nihao","切回当前方案会取消尚未生效的变更")
        try s.requestPinyinLayout(.microsoft); try s.requestPinyinLayout(.flypy)
        s.handle(key:32)
        check(s.pinyinLayout == .flypy && s.draft == "你好中文你好世界你好","连续更改方案只应用最后一次选择")
        type("nihc",in:s); try s.requestPinyinLayout(.sogou); s.handle(key:0xff0d)
        check(s.pinyinLayout == .sogou && s.draft.hasSuffix("nihc"),"Enter 原样输入旧方案字母后，安全应用新方案")
        type("nihk",in:s); try s.requestPinyinLayout(.fullPinyin); s.handle(key:0xff1b)
        check(s.pinyinLayout == .fullPinyin && s.markedText.isEmpty,"取消预编辑后应用待切换方案")
    }
    @MainActor static func type(_ text:String,in session:CompositionSession) {
        for c in text.unicodeScalars { session.handle(key:Int(c.value)) }
    }
    static func check(_ condition:Bool,_ message:String) {
        if !condition { fatalError(message) }
        print("PASS:",message)
    }
}
