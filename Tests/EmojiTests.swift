import Foundation

@main struct EmojiTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1],relativeTo:root)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunEmojiTests-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:resources,user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let fixtures: [(PinyinLayout,[String])] = [
            (.fullPinyin,["zan","zhengfangxing","wujiaoxing","xiaolian"]),
            (.sogou,["zj","vgfhx;","wujcx;","xclm"]),
            (.flypy,["zj","vgfhxk","wujnxk","xnlm"]),
            (.natural,["zj","vgfhxy","wujcxy","xclm"]),
            (.microsoft,["zj","vgfhx;","wujcx;","xclm"]),
            (.abc,["zj","agfhxy","wujzxy","xzlw"]),
            (.pinyinJiajia,["zf","vtfgxq","wujkxq","xklj"]),
            (.ziguang,["zr","utfsx;","wujbx;","xblf"])
        ]
        let words = ["赞","正方形","五角星","笑脸"]
        let symbols = ["👍","⬛","⭐","😄"]
        for (layout,codes) in fixtures {
            for (i,code) in codes.enumerated() {
                for mode in 0..<3 {
                    let s = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:mode == 1)
                    if mode == 2 { s.beginEditor() }
                    var output = ""
                    s.onInsert = { output += $0 }
                    s.readKey = { _ in fatalError("表情候选不能调用模型") }
                    type(code,in:s)
                    let wordIndex = s.candidates.firstIndex(of:words[i])
                    let emojiIndex = s.candidates.firstIndex(of:symbols[i])
                    check(wordIndex != nil && emojiIndex != nil && wordIndex! < emojiIndex!,"\(layout.name)：\(code) 中文候选 \(words[i]) 保留在表情前，实际 \(s.candidates)")
                    check(s.candidates.contains(symbols[i]),"\(layout.name)：\(words[i]) 首页含 \(symbols[i])")
                    let index = s.candidates.firstIndex(of:symbols[i])!
                    switch mode {
                    case 0: s.handle(key:49+index)
                    case 1:
                        for _ in 0..<index { s.handle(key:0xff53) }
                        s.handle(key:32)
                    default: s.choose(index)
                    }
                    check(!s.hasPendingInput && (mode == 0 ? output == symbols[i] : s.draft == symbols[i] && output.isEmpty),"\(layout.name)：数字/高亮空格/点击准确确认表情，模式 \(mode)")
                    check(!s.isTranslating,"确认表情不触发 AI")
                }
            }
        }
        try fullPinyinBehavior()
        try keywordCoverage(resources:resources)
        print("ALL EMOJI TESTS PASSED")
    }

    @MainActor static func keywordCoverage(resources:URL) throws {
        let text = try String(contentsOf:resources.appendingPathComponent("opencc/emoji.txt"),encoding:.utf8)
        let entries = text.split(separator:"\n").map { $0.split(separator:"\t") }
        let names = Set(entries.map { String($0[0]) })
        var codes: [String:String] = [:]
        for file in ["pinyin_simp.dict.yaml","base.dict.yaml","fangcun_emoji_names.dict.yaml"] {
            for line in try String(contentsOf:resources.appendingPathComponent(file),encoding:.utf8).split(separator:"\n") {
                let fields = line.split(separator:"\t")
                if fields.count >= 2, names.contains(String(fields[0])), codes[String(fields[0])] == nil {
                    codes[String(fields[0])] = fields[1].replacingOccurrences(of:" ",with:"")
                }
            }
        }
        let s = CompositionSession(engine:try PinyinEngine(),translateEnabled:false)
        for fields in entries {
            let word = String(fields[0])
            guard let code = codes[word] else { fatalError("表情名称缺少拼音：\(word)") }
            let symbols = Set(fields[1].split(separator:" ").dropFirst().map(String.init))
            type(code,in:s)
            var seen = Set(s.candidates)
            for _ in 0..<32 {
                if symbols.isSubset(of:seen) || s.snapshot.lastPage { break }
                s.handle(key:61)
                seen.formUnion(s.candidates)
            }
            check(symbols.isSubset(of:seen),"\(word) / \(code)：所有表情均可候选，缺少 \(symbols.subtracting(seen))")
            s.discardPendingInput()
        }
    }

    @MainActor static func fullPinyinBehavior() throws {
        let s = CompositionSession(engine:try PinyinEngine(),translateEnabled:false)
        var output = ""
        s.onInsert = { output += $0 }
        type("zhengfangxing",in:s)
        s.handle(key:61)
        check(s.snapshot.page == 1 && s.candidates.contains("🟪"),"多个形状表情保留原生翻页")
        let index = s.candidates.firstIndex(of:"🟪")!
        s.choose(index)
        check(output == "🟪","翻页后点击准确提交所选颜色")
        type("aixin",in:s)
        check(s.candidates.contains("❤️"),"含变体选择符的爱心独立显示")
        s.choose(s.candidates.firstIndex(of:"❤️")!)
        check(output == "🟪❤️","爱心完整上屏，保留变体选择符")
        type("nihaozan",in:s)
        s.choose(s.candidates.firstIndex(of:"你好")!)
        check(s.candidates.contains("👍"),"连续拼音选完前缀后仍能选表情")
        s.choose(s.candidates.firstIndex(of:"👍")!)
        check(output == "🟪❤️你好👍","分段选择表情保留已选中文前缀")
        type("zan",in:s); s.handle(key:0xff0d)
        check(output.hasSuffix("zan"),"Enter 保留原始拼音")
        type("xiaolian",in:s); s.handle(key:0xff1b)
        check(!s.hasPendingInput,"Esc 取消表情候选")
        s.setASCIIMode(true); type("zan xiaolian",in:s)
        check(output.hasSuffix("zan xiaolian") && s.candidates.isEmpty,"英文模式按原样输入")
        s.setASCIIMode(false)
        type("woxihuanxiaolian",in:s)
        check(!s.candidates.contains(where: { $0.contains("😄") || $0.contains("😊") }),"普通整句候选不自动替换词中表情名称")
        s.discardPendingInput()
        type("zan",in:s); s.setContext("太")
        s.invalidateContext("emoji-test")
        check(s.candidates.contains("👍"),"上下文更新后表情候选仍可正确选择")
        s.choose(s.candidates.firstIndex(of:"👍")!)
        check(output.hasSuffix("👍"),"上下文更新后仍提交表情本身")
    }
    @MainActor static func type(_ text:String,in s:CompositionSession) {
        for c in text.unicodeScalars { s.handle(key:Int(c.value)) }
    }
    static func check(_ condition:Bool,_ message:String) {
        precondition(condition,message)
        print("PASS:",message)
    }
}
