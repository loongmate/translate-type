import Foundation

@main struct PunctuationTests {
    // Enumerate the entire printable ASCII symbol set independently of the
    // production classifier. Every key must either retain its documented IME
    // role or preserve the entire pending fragment without an implicit commit.
    static let symbols = Array("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)
    static let shifted = Set("~!@#$%^&*()_+{}|:\"<>?".unicodeScalars)
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
                        check(output.isEmpty && s.draft.isEmpty && s.hasPendingInput,label+"：不自动上屏或确认到草稿")
                        let paging = [43,45,61].contains(key)
                        let spelling = key == 39 || (key == 59 && semicolonSpelling)
                        if paging {
                            check(!engine.isLiteralInput && s.snapshot.input == before.input && s.snapshot.selectionStart == 0 && s.snapshot.caret == s.snapshot.preedit.utf16.count,label+"：保留符号翻页，不改变原始输入或进入拼音编辑")
                        } else if spelling {
                            check(!engine.isLiteralInput && s.snapshot.input == prefix+String(scalar),label+"：隔音或双拼编码仍属于拼音")
                        } else {
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
            let chinesePunctuation: [UInt32:String] = [47:"、",92:"、",44:"，",46:"。",58:"：",59:"；",63:"？",33:"！",40:"（",41:"）"]
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
                    let expected = "你好"+(chinesePunctuation[scalar.value] ?? String(scalar))
                    check(!s.hasPendingInput && !engine.isLiteralInput && (mode == 0 ? output == expected : s.draft == expected && output.isEmpty),"\(layout.name)/\(mode)/\(scalar)：已选中文后正常输入标点")
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
            partial.handle(key:Int(scalar.value),shift:shifted.contains(scalar))
            check(partial.snapshot.input == "你hao"+String(scalar) && partial.draft.isEmpty,"\(scalar)：保留已选中文前缀，不确认未选尾部")
        }
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
