import Foundation

@main struct PunctuationTests {
    // Enumerate the entire printable ASCII symbol set independently of the
    // production classifier: Chinese punctuation confirms the displayed text;
    // spelling, paging and literal fragments retain their own input rules.
    static let symbols = Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)
    static let shifted = Set("~!@#$%^&*()_+{}|:\"<>?".unicodeScalars)
    static let chinesePunctuation: [UInt32:String] = [47:"、",92:"、",44:"，",46:"。",58:"：",59:"；",63:"？",33:"！",40:"（",41:"）",91:"【",93:"】",60:"《",62:"》",34:"“"]
    static var checks = 0
    static let fixtures: [(PinyinLayout,String,String,Bool)] = [
        (.fullPinyin,"nihao","beijing",false),(.sogou,"nihk","bzj;",true),
        (.flypy,"nihc","bwjk",false),(.natural,"nihk","bzjy",false),
        (.microsoft,"nihk","bzj;",true),(.abc,"nihk","bqjy",false),
        (.pinyinJiajia,"nihd","bwjq",false),(.ziguang,"nihq","bkj;",true)
    ]
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunPunctuationTests-"+UUID().uuidString)
        let cache = root.appendingPathComponent(".build/punctuation-rime-cache")
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        if !FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:user.appendingPathComponent("build"),to:cache) }
        defer { try? FileManager.default.removeItem(at:user) }
        check(symbols.count == 32 && Set(symbols).count == 32,"完整覆盖 32 种 ASCII 符号")
        var cases = 0
        for (layout,hello,beijing,semicolonSpelling) in fixtures {
            let engine = try PinyinEngine(layout:layout)
            for mode in 0..<3 {
                for prefix in ["ni","code","API"] {
                    for scalar in symbols {
                        engine.clear()
                        let s = CompositionSession(engine:engine,translateEnabled:mode == 1)
                        var output = ""
                        s.onInsert = { output += $0 }
                        s.readKey = { _ in fatalError("符号测试不能调用模型") }
                        if mode == 2 { s.beginEditor() }
                        type(prefix,in:s)
                        let before = s.snapshot, key = Int(scalar.value)
                        let label = "\(layout.name)/\(mode)/\(prefix)/\(scalar)"
                        check(s.handle(key:key,shift:shifted.contains(scalar)),label+"：消费普通按键")
                        let paging = [43,45,61].contains(key)
                        let spelling = key == 39 || (key == 59 && semicolonSpelling)
                        if paging {
                            check(!engine.isLiteralInput && s.snapshot.input == before.input && s.snapshot.selectionStart == 0 && s.snapshot.caret == s.snapshot.preedit.utf16.count,label+"：保留符号翻页，不改变原始输入或进入拼音编辑")
                        } else if spelling {
                            check(!engine.isLiteralInput && s.snapshot.input == prefix+String(scalar),label+"：隔音或双拼编码仍属于拼音")
                        } else if let punctuation = chinesePunctuation[scalar.value] {
                            if key == 46 {
                                check(s.markedText == before.preview+"。" && s.hasPendingInput && (mode == 0 ? output : s.draft).isEmpty,label+"：句号立即显示，暂留预编辑")
                                switch mode {
                                case 0: s.handle(key:32)
                                case 1: s.handle(key:0xff0d)
                                default: s.choose(0)
                                }
                            }
                            let result = mode == 0 ? output : s.draft
                            let endings = key == 34 ? ["“","”"] : [punctuation]
                            check(endings.contains(where:{ result == before.preview+$0 }) && !s.hasPendingInput && !engine.isLiteralInput,label+"：确认当前候选并输入中文标点，不退回原始字母")
                            check(!s.isTranslating && (mode == 0 || output.isEmpty),label+"：标点不调用模型，译英与编辑区只更新草稿")
                        } else {
                            check(output.isEmpty && s.draft.isEmpty && s.hasPendingInput,label+"：普通符号保留待确认片段")
                            let start = prefix+String(scalar)
                            check(engine.isLiteralInput && s.snapshot.input == start && s.snapshot.preedit == start && s.candidates == [start] && !s.asciiMode,label+"：整段原样预编辑")
                            // After any ordinary symbol, all symbols (including
                            // the IME exceptions) and digits become plain text.
                            let suffix = "v2"+String(String.UnicodeScalarView(symbols))+"0123456789"
                            type(suffix,in:s)
                            let expected = start+suffix
                            check(s.snapshot.input == expected && output.isEmpty && s.draft.isEmpty && s.snapshot.page == 0,label+"：后续全部符号和数字原样输入，不选词、不翻页")
                            if mode != 0 {
                                s.handle(key:0xff0d,control:true)
                                check(s.snapshot.input == expected && !s.isTranslating && !s.canRequestTranslation,label+"：未确认原文不能调用模型")
                            }
                            check(!s.handle(key:key,command:true) && s.snapshot.input == expected,label+"：Command 快捷键仍交给宿主")
                            switch key % 3 {
                            case 0:s.handle(key:32)
                            case 1:s.handle(key:0xff0d)
                            default:s.choose(0)
                            }
                            check(!s.hasPendingInput && !engine.isLiteralInput && (mode == 0 ? output == expected : s.draft == expected && output.isEmpty),label+"：空格、Enter 或点击确认完整原文")
                        }
                        cases += 1
                    }
                    print("PASS: \(layout.name) / \(["中文","译英","编辑区"][mode]) / \(prefix)：32 种符号逐项验证")
                }
            }
            // Explicit Chinese confirmation still permits normal punctuation.
            for mode in 0..<3 {
                for scalar in symbols {
                    engine.clear()
                    let s = CompositionSession(engine:engine,translateEnabled:mode == 1)
                    var output = ""
                    s.onInsert = { output += $0 }
                    if mode == 2 { s.beginEditor() }
                    type(hello,in:s)
                    check(s.candidates.contains("你好"),"\(layout.name)：拼音方案仍可输入你好")
                    s.choose(s.candidates.firstIndex(of:"你好")!)
                    if !s.handle(key:Int(scalar.value),shift:shifted.contains(scalar)) { output += String(scalar) }
                    let endings = scalar.value == 34 ? ["“","”"] : [chinesePunctuation[scalar.value] ?? String(scalar)]
                    let result = mode == 0 ? output : s.draft
                    check(!s.hasPendingInput && !engine.isLiteralInput && endings.contains(where:{ result == "你好"+$0 }) && (mode == 0 || output.isEmpty),"\(layout.name)/\(mode)/\(scalar)：已选中文后正常输入标点")
                }
                for navigation in [0xff54,0xff56] {
                    engine.clear()
                    let s = CompositionSession(engine:engine,translateEnabled:mode == 1)
                    var output = ""
                    s.onInsert = { output += $0 }
                    if mode == 2 { s.beginEditor() }
                    type("ni",in:s)
                    s.handle(key:navigation)
                    let selected = s.snapshot.preview
                    s.handle(key:44)
                    check((mode == 0 ? output : s.draft) == selected+"，" && !s.hasPendingInput,"\(layout.name)/\(mode)：标点确认移动高亮或翻页后的候选")
                    s.setASCIIMode(true)
                    let before = mode == 0 ? output : s.draft
                    let text = String(String.UnicodeScalarView(symbols))
                    type(text,in:s)
                    check((mode == 0 ? output : s.draft) == before+text && !s.hasPendingInput,"\(layout.name)/\(mode)：英文模式全部 32 种符号保持半角")
                }
                engine.clear()
                let s = CompositionSession(engine:engine,translateEnabled:mode == 1)
                var output = ""
                s.onInsert = { output += $0 }
                if mode == 2 { s.beginEditor() }
                func result() -> String { mode == 0 ? output : s.draft }
                let label = "\(layout.name)/\(mode)"
                var confirmed = ""
                for domain in ["baidu.com/a-b?x=1+2", "Example.CN", "example.net", "example.org", "www.baidu.com"] {
                    type(domain,in:s)
                    check(result() == confirmed && s.snapshot.input == domain && s.snapshot.preedit == domain && engine.isLiteralInput,label+"：\(domain) 整段保持原文")
                    s.handle(key:32)
                    confirmed += domain
                    check(result() == confirmed && !s.hasPendingInput,label+"：原样提交域名后恢复拼音")
                }
                type(hello+".n",in:s)
                check(result() == confirmed && s.snapshot.preedit == "你好。n",label+"：可能的网址后缀暂留预编辑")
                type("i",in:s)
                confirmed += "你好。"
                check(result() == confirmed && s.snapshot.input == "ni" && !engine.hasPendingPeriod,label+"：排除网址后确认句号，完整重放后续拼音")
                s.handle(key:0xff0d)
                confirmed += "ni"
                type(hello+".co",in:s)
                for _ in 0..<3 { s.handle(key:0xff08) }
                check(result() == confirmed && s.snapshot.input == hello && !engine.hasPendingPeriod,label+"：退格删掉后缀和句号后恢复原候选")
                type(".,",in:s)
                check(result() == confirmed+"你好。，" && !s.hasPendingInput,label+"：逗号紧接待定句号时两者立即提交")
                if mode != 2 {
                    type(hello+".",in:s)
                    s.flushOriginal()
                    check(output == confirmed+"你好。，你好。" && !s.hasPendingInput,label+"：宿主提交时保留待定句号并清理预编辑")
                }
            }
            engine.clear()
            let spelling = CompositionSession(engine:engine,translateEnabled:false)
            type(beijing,in:spelling)
            check(spelling.candidates.contains("北京") && !engine.isLiteralInput,"\(layout.name)：北京编码（含双拼分号）不被当成普通标点")
        }
        let engine = try PinyinEngine()
        let separator = CompositionSession(engine:engine,translateEnabled:false)
        type("xi'an",in:separator)
        check(separator.candidates.contains("西安") && !engine.isLiteralInput,"隔音符号仍可输入西安")
        for scalar in symbols where ![39,43,45,61].contains(Int(scalar.value)) {
            engine.clear()
            let partial = CompositionSession(engine:engine,translateEnabled:true)
            type("nihao",in:partial)
            partial.choose(partial.candidates.firstIndex(of:"你")!)
            let preview = partial.snapshot.preview
            partial.handle(key:Int(scalar.value),shift:shifted.contains(scalar))
            if let punctuation = chinesePunctuation[scalar.value] {
                let endings = scalar.value == 34 ? ["“","”"] : [punctuation]
                check(endings.contains(where:{ partial.draft == preview+$0 }) && !partial.hasPendingInput,"\(scalar)：分段选词后保留中文前缀并确认剩余候选")
            } else {
                check(partial.snapshot.input == "你hao"+String(scalar) && partial.draft.isEmpty,"\(scalar)：普通符号保留已选中文前缀和原始尾部")
            }
        }
        engine.clear()
        let contextual = CompositionSession(engine:engine,translateEnabled:false)
        var output = ""
        contextual.onInsert = { output += $0 }
        contextual.setContext("上")
        type("hai.",in:contextual)
        check(contextual.markedText == "海。" && output.isEmpty,"待定句号显示上下文排序后的高亮候选")
        type("hai",in:contextual)
        check(output == "海。" && contextual.snapshot.input == "hai" && !contextual.contextActive,"句号后的拼音不沿用上一句的上下文")
        print("ALL PUNCTUATION TESTS PASSED: \(cases) pending-input cases, \(checks) assertions")
    }
    @MainActor static func type(_ text:String,in session:CompositionSession) {
        for scalar in text.unicodeScalars { session.handle(key:Int(scalar.value),shift:shifted.contains(scalar)) }
    }
    static func check(_ condition:Bool,_ message:String) {
        checks += 1
        guard condition else { print("FAIL:",message); exit(1) }
    }
}
