import Foundation

// Exploratory acceptance checks. Failures stay failures; this suite does not
// bless current defects as expected behavior. It never uses personal Rime data
// or a real model service. REVIEW records need a product/usability decision.
@MainActor private final class Driver {
    let session: CompositionSession
    var output = ""
    var steps: [String] = []
    init(translation:Bool = false, english:Bool = false) throws {
        session = CompositionSession(engine:try PinyinEngine(),translateEnabled:translation)
        session.onInsert = { [weak self] in self?.output += $0 }
        session.configuration = { ModelConfiguration(endpoint:"http://localhost:1/v1",model:"") }
        session.readKey = { _ in throw AppError.message("Audit never reads credentials or calls a model") }
        if english { session.setASCIIMode(true) }
    }
    @discardableResult func key(_ value:Int, control:Bool = false) -> Bool {
        let handled = session.handle(key:value,control:control)
        // Simulate only a host app's insertion of unhandled printable ASCII.
        // Cursor movement, commands and IMK/window events require separate tests.
        if !handled && !control && (32...126).contains(value), let c = UnicodeScalar(value) { output += String(c) }
        return handled
    }
    func type(_ value:String) { for c in value.unicodeScalars { key(Int(c.value)) } }
    func left(_ count:Int) { for _ in 0..<count { key(0xff51) } }
    func state() -> [String:Any] {
        let s = session.snapshot
        return ["output":output,"draft":session.draft,"raw":s.input,"preedit":s.preedit,
                "caret":session.markedCaret,"candidates":session.candidates,"highlighted":session.highlighted,
                "page":s.page,"translationAllowed":session.canRequestTranslation]
    }
}

@main struct InputBehaviorAudit {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunAudit-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let saved = ConfigurationStore.shared.translateEnabled
        defer { ConfigurationStore.shared.translateEnabled = saved }
        var records: [[String:Any]] = []
        func record(_ id:String,_ title:String,_ steps:String,_ expected:String,_ d:Driver,_ passed:Bool?, extra:[String:Any] = [:]) {
            let status = passed.map { $0 ? "PASS" : "FAIL" } ?? "REVIEW"
            var row: [String:Any] = ["id":id,"title":title,"steps":steps,"expected":expected,"status":status,"actual":d.state()]
            row.merge(extra,uniquingKeysWith:{$1}); records.append(row)
            print("\(status) \(id) \(title)")
        }
        // Inspect ranking before any selections can train the isolated user dict.
        let corpus = [
            ("nihao","你好"),("nishuode","你说的"),("zhongwenshuru","中文输入"),
            ("xuancikenengbuzhengque","选词可能不正确"),("ceshi","测试"),
            ("ceshiyeyaochongfenkaolvyiyongxing","测试也要充分考虑易用性"),
            ("woxiangqubeijing","我想去北京"),("jintianxiawusandiankaihui","今天下午三点开会"),
            ("women","我们"),("xi'an","西安"),("chang'an","长安"),("chongqing","重庆"),
            ("yinhang","银行"),("hangye","行业"),("fangcunshurufa","方寸输入法"),
            ("tuopanlidelogo","托盘里的logo"),("zhichiAPI","支持API"),
            ("woyaoxiugaiBug","我要修改Bug"),("wozaiGitHubtijiaolePR","我在GitHub提交了PR"),
            ("zhegeApphenhao","这个App很好"),("nvhai","女孩"),("lvse","绿色")
        ]
        for (i,item) in corpus.enumerated() {
            let d = try Driver(); d.type(item.0)
            let rank = d.session.candidates.firstIndex(of:item.1).map{$0+1} ?? 0
            record(String(format:"Q%02d",i+1),"首选词样本",item.0,"目标表达："+item.1,d,rank == 1 ? true : nil,
                   extra:["target":item.1,"rankInFirstPage":rank,"qualitySample":true])
        }
        for translation in [false,true] {
            let suffix = translation ? "T" : "C"
            for index in 0..<5 {
                let d = try Driver(translation:translation); d.type("hao")
                let expected = d.session.candidates[index]
                d.key(49+index)
                record("SEL-\(suffix)-\(index+1)","数字选择与所显示的候选一致","hao → 数字 \(index+1)",expected,d,
                       (translation ? d.session.draft : d.output) == expected && d.session.snapshot.input.isEmpty)
            }
            let space = try Driver(translation:translation); space.type("hao"); space.key(0xff54)
            let expected = space.session.candidates[space.session.highlighted]; space.key(32)
            record("SPACE-"+suffix,"空格确认当前高亮而非固定第一项","hao → ↓ → Space",expected,space,(translation ? space.session.draft : space.output) == expected)
            let page = try Driver(translation:translation); page.type("hao"); page.key(0xff56)
            let pageWord = page.session.candidates[1]; page.key(50)
            record("PAGE-"+suffix,"翻页后数字对应当前页","hao → PageDown → 2",pageWord,page,(translation ? page.session.draft : page.output) == pageWord)
            let click = try Driver(translation:translation); click.type("hao")
            let clicked = click.session.candidates[2]; click.session.choose(2)
            record("CHOOSE-"+suffix,"候选按钮的选择接口","hao → choose(2)",clicked,click,(translation ? click.session.draft : click.output) == clicked)
            let partial = try Driver(translation:translation); partial.type("nihao"); partial.left(3)
            let firstPart = partial.session.candidates[0]; partial.key(32)
            let secondPart = partial.session.candidates[0]; partial.key(32)
            record("PARTIAL-"+suffix,"分两次选词保留整句","nihao → ←×3 → Space → Space",firstPart+secondPart,partial,(translation ? partial.session.draft : partial.output) == firstPart+secondPart && partial.session.snapshot.input.isEmpty)
            let invalid = try Driver(translation:translation); invalid.type("hao"); invalid.key(57)
            record("INVALID-"+suffix,"不存在的候选序号不破坏输入","hao → 9","保留 hao，不确认其他候选",invalid,invalid.session.snapshot.input == "hao" && invalid.output.isEmpty && invalid.session.draft.isEmpty)
            let punctuation = try Driver(translation:translation); punctuation.type("nihao")
            let sentence = punctuation.session.candidates[0]; punctuation.key(32); punctuation.type(".")
            record("PUNCT-"+suffix,"句号跟随已选中文","nihao → Space → .",sentence+"。",punctuation,(translation ? punctuation.session.draft : punctuation.output) == sentence+"。")
            let explicitWord = try Driver(translation:translation); explicitWord.type("hao"); explicitWord.key(0xff54)
            let word = explicitWord.session.candidates[explicitWord.session.highlighted]; explicitWord.type(",")
            record("PUNCT-SELECT-"+suffix,"候选高亮后标点确认的词一致","hao → ↓ → ,",word+"，",explicitWord,(translation ? explicitWord.session.draft : explicitWord.output) == word+"，")
            let raw = try Driver(translation:translation); raw.type("logo"); raw.key(0xff0d)
            record("RAW-"+suffix,"未选择的英文原样确认","logo → Enter","logo",raw,(translation ? raw.session.draft : raw.output) == "logo")
            let partialRaw = try Driver(translation:translation); partialRaw.type("nihao"); partialRaw.left(3); partialRaw.key(32); partialRaw.key(0xff0d)
            record("PARTIAL-RAW-"+suffix,"原样确认不能把已选中文还原成拼音","nihao → ←×3 → Space（你）→ Enter","你hao",partialRaw,(translation ? partialRaw.session.draft : partialRaw.output) == "你hao")
            let shift = try Driver(translation:translation); shift.type("nihao"); shift.left(3); shift.key(32); shift.session.setASCIIMode(true)
            record("PARTIAL-SHIFT-"+suffix,"切英文不能撤销已确认的中文","nihao → ←×3 → Space（你）→ 切英文","你hao",shift,(translation ? shift.session.draft : shift.output) == "你hao")
            let blur = try Driver(translation:translation); blur.type("nihao")
            let whole = blur.session.candidates[0]; blur.left(3); blur.session.flushOriginal()
            record("FLUSH-"+suffix,"结束会话不能丢失光标后的输入","ni│hao → flushOriginal（失焦路径）","完整保留 nihao / 你hao / "+whole,blur,["nihao","你hao",whole].contains(blur.output))
        }
        let blank = try Driver(); blank.key(32)
        record("EMPTY-SPACE","空输入时空格交给宿主","Space","一个空格",blank,blank.output == " " && blank.session.markedText.isEmpty)
        for (id,input) in [("DECIMAL","3.14"),("EMAIL","test@example.com"),("URL","https://example.com/a?x=1"),("CODE","API_v2") ] {
            let cn = try Driver(); cn.type(input)
            record(id+"-C","中文模式的结构化英文",input,"需确定整段英文识别规则；不得当作中文正确率通过项",cn,nil)
            let en = try Driver(english:true); en.type(input)
            record(id+"-EN","英文模式保留符号",input,input,en,en.output == input && en.session.markedText.isEmpty)
        }
        let lone = try Driver(translation:true); lone.type(".")
        record("LONE-PUNCT","截图对应的仅标点草稿","开启译英 → .","展示实际状态，是否允许仅标点翻译需决定",lone,nil)
        let draft = try Driver(translation:true); draft.type("nihao"); draft.key(32)
        let before = draft.session.markedCaret; let moved = draft.key(0xff51)
        record("DRAFT-LEFT","已选中文草稿需要能移动光标纠错","译英 → nihao → Space → ←","光标从你好末尾左移一字，不上屏",draft,moved && draft.session.markedCaret == before-1 && draft.output.isEmpty)
        let deletion = try Driver(translation:true); deletion.type("nihao"); deletion.key(32); deletion.key(0xff08)
        record("DRAFT-BACKSPACE","草稿末尾退格只删一个字","译英 → nihao → Space → Backspace","你",deletion,deletion.session.draft == "你" && deletion.output.isEmpty)
        let spaces = try Driver(translation:true); spaces.type("nihao"); spaces.key(32)
        let beforeSpace = spaces.session.draft; spaces.key(32)
        record("DRAFT-SPACE","无候选时空格进入草稿","译英 → nihao → Space → Space",beforeSpace+" 后有一个空格",spaces,spaces.session.draft == beforeSpace+" " && spaces.output.isEmpty)
        let escape = try Driver(translation:true); escape.type("nihao"); escape.key(32); escape.type("shijie"); escape.key(0xff1b)
        record("DRAFT-ESC","取消当前拼音是否同时丢弃已选草稿","译英 → nihao → Space → shijie → Esc","当前实现会清空整段；需要决定分层取消规则",escape,nil)
        let tab = try Driver(translation:true); tab.type("nihao")
        let tabWhole = tab.session.candidates[0]; tab.left(3); tab.key(0xff09)
        record("TAB-TAIL","Tab 离开输入时保留未选尾部","译英 → ni│hao → Tab","完整保留 nihao / 你hao / "+tabWhole,tab,["nihao","你hao",tabWhole].contains(tab.output))
        let toggle = try Driver(translation:true); toggle.type("nihao")
        let toggleWhole = toggle.session.candidates[0]; toggle.left(3); toggle.session.setTranslateEnabled(false)
        record("TOGGLE-TAIL","关闭译英不能丢掉待选尾部","译英 → ni│hao → 关闭译英","完整保留 nihao / 你hao / "+toggleWhole,toggle,["nihao","你hao",toggleWhole].contains(toggle.output))
        let blocked = try Driver(translation:true); blocked.type("nihao"); blocked.key(32); blocked.type("nihao"); blocked.left(3)
        let text = blocked.session.markedText, caret = blocked.session.markedCaret
        blocked.key(0xff0d,control:true)
        record("BLOCK-TRANSLATION","未选完不能翻译或改动草稿","你好 + ni│hao → Ctrl+Enter","全文与光标保持不变，不启动翻译",blocked,blocked.session.markedText == text && blocked.session.markedCaret == caret && !blocked.session.isTranslating)
        let paragraphs = try Driver(translation:true); paragraphs.type("nihao"); paragraphs.key(32); paragraphs.key(0xff0d)
        record("DRAFT-RETURN","中文草稿的换行与中文上屏冲突","译英 → nihao → Space → Enter","当前 Enter 中文上屏；段内换行操作待设计",paragraphs,nil)
        let long = try Driver(translation:true)
        var expectedLong = ""
        for _ in 0..<60 { long.type("nihao"); expectedLong += long.session.candidates[0]+"。"; long.key(32); long.type(".") }
        record("LONG-DRAFT","连续长草稿不提前上屏","重复 60 次 nihao → Space → .","60 次实际高亮的选词与句号完整保留",long,long.session.draft == expectedLong && long.output.isEmpty)
        let failures = records.filter { $0["status"] as? String == "FAIL" }.count
        let reviews = records.filter { $0["status"] as? String == "REVIEW" }.count
        let report: [String:Any] = ["generatedAt":ISO8601DateFormatter().string(from:Date()),"level":"真实 Rime 与 CompositionSession，非系统端到端测试",
                                  "isolatedUserDictionary":true,"rankingCorpusBeforeSelections":true,"personalSettingsRead":false,"realModelCalls":0,
                                  "total":records.count,"passed":records.count-failures-reviews,"failed":failures,"review":reviews,"cases":records]
        let path = CommandLine.arguments.dropFirst().first ?? ".build/input-behavior-audit.json"
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]).write(to:URL(fileURLWithPath:path))
        print("AUDIT: \(records.count) checks; \(failures) failures; \(reviews) reviews. Report: \(path)")
        if failures > 0 { exit(1) }
    }
}
