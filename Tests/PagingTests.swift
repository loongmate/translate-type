import Foundation

@main struct PagingTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunPagingTests-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        for layout in PinyinLayout.allCases {
            for translating in [false,true] {
                try paging(layout:layout,translating:translating)
                try symbols(layout:layout,translating:translating)
            }
        }
        print("ALL PAGING TESTS PASSED")
    }
    @MainActor static func paging(layout:PinyinLayout,translating:Bool) throws {
        let s = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:translating)
        let label = "\(layout.name) / \(translating ? "译英" : "中文")"
        var output = ""
        s.onInsert = { output += $0 }
        s.readKey = { _ in fatalError("翻页、选词和未选完的 Ctrl+Enter 不得请求翻译") }
        if translating { type("ni",in:s); s.handle(key:32) }
        let draft = s.draft
        type("ni",in:s)
        let initial = s.snapshot
        check(initial.page == 0 && initial.candidates.count == 5 && !initial.lastPage,"\(label)：准备多页候选")
        check(s.handle(key:45) && samePage(s.snapshot,initial),"\(label)：首页 - 停住，候选与拼音不变")
        check(s.handle(key:61) && s.snapshot.page == 1,"\(label)：= 下一页")
        let second = s.snapshot
        check(s.handle(key:43,shift:true) && s.snapshot.page == 2,"\(label)：Shift+= 的 + 下一页")
        check(s.handle(key:45) && samePage(s.snapshot,second),"\(label)：- 回到上一页的同组候选")
        s.handle(key:0xff0d,control:true)
        check(s.snapshot.input == initial.input && s.snapshot.preedit == initial.preedit && s.markedCaret == draft.utf16.count+initial.caret && s.draft == draft && output.isEmpty && !s.canRequestTranslation && !s.isTranslating,"\(label)：翻页不确认文字、不移动拼音光标、不调用模型")
        for shortcut in [45,61,43] {
            let before = s.snapshot
            check(!s.handle(key:shortcut,command:true) && !s.handle(key:shortcut,control:true) && !s.handle(key:shortcut,option:true) && samePage(s.snapshot,before),"\(label)：修饰键组合 \(shortcut) 交给宿主")
        }
        let chosen = s.candidates[s.highlighted]
        s.handle(key:32)
        check(translating ? s.draft == draft+chosen && output.isEmpty : output == chosen,"\(label)：翻页后空格确认实际高亮候选")
        s.handle(key:0xff1b); output = ""
        type("ni",in:s); s.handle(key:61)
        let numbered = s.candidates[1]
        s.handle(key:50)
        check(translating ? s.draft == numbered && output.isEmpty : output == numbered,"\(label)：翻页后数字 2 确认当前页第二项")
        s.handle(key:0xff1b); output = ""
        type("ni",in:s)
        for _ in 0..<512 {
            if s.snapshot.lastPage { break }
            let page = s.snapshot.page
            s.handle(key:43)
            precondition(s.snapshot.page == page+1,"每次翻页必须前进一步")
        }
        check(s.snapshot.lastPage,"\(label)：能翻到末页")
        let last = s.snapshot
        check(s.handle(key:43,shift:true) && s.handle(key:61) && samePage(s.snapshot,last) && output.isEmpty && s.draft.isEmpty,"\(label)：末页 + 和 = 均停住，不绕回、不插入符号")
        s.handle(key:45)
        check(s.snapshot.page == last.page-1,"\(label)：末页仍可向前翻页")
        s.handle(key:0xff1b)
        type("nini",in:s)
        s.handle(key:0xff51); s.handle(key:0xff51)
        let editing = s.snapshot
        check(editing.caret < editing.preedit.utf16.count && !editing.candidates.isEmpty,"\(label)：光标在拼音内部准备选词")
        s.handle(key:61); s.handle(key:45)
        check(s.snapshot.input == editing.input && s.snapshot.preedit == editing.preedit && s.snapshot.caret == editing.caret && s.draft.isEmpty && output.isEmpty,"\(label)：编辑拼音时翻页仍保留完整输入和光标")
        s.handle(key:0xff1b)
        type("nini",in:s)
        for _ in 0..<512 {
            if s.candidates.contains("你") || s.snapshot.lastPage { break }
            s.handle(key:61)
        }
        guard let prefix = s.candidates.firstIndex(of:"你") else { fatalError("缺少分段选词测试候选") }
        s.choose(prefix)
        let partial = s.snapshot
        check(s.hasPendingInput && s.markedText.hasPrefix("你") && output.isEmpty,"\(label)：只确认第一个音节，保留待选尾部")
        s.handle(key:61)
        check(s.snapshot.page == 1 && s.snapshot.input == partial.input && s.snapshot.preedit == partial.preedit && s.snapshot.caret == partial.caret && output.isEmpty,"\(label)：分段选词后的翻页保留已选中文和未选拼音")
        let suffix = s.candidates[s.highlighted]
        s.handle(key:32)
        check(translating ? s.draft == "你"+suffix && output.isEmpty : output == "你"+suffix,"\(label)：分段选词再翻页确认，前后文字均保留")
        s.handle(key:0xff1b)
    }
    @MainActor static func symbols(layout:PinyinLayout,translating:Bool) throws {
        let s = CompositionSession(engine:try PinyinEngine(layout:layout),translateEnabled:translating)
        let label = "\(layout.name) / \(translating ? "译英" : "中文")"
        var output = ""
        s.onInsert = { output += $0 }
        // Model the host's insertion when the IME deliberately returns false.
        func typeSymbol(_ key:Int,shift:Bool = false) {
            if !s.handle(key:key,shift:shift) { output += String(UnicodeScalar(key)!) }
        }
        for key in [45,61,43] { typeSymbol(key,shift:key == 43) }
        check(output+s.draft == "-=+" && !s.hasPendingInput,"\(label)：无候选时正常输入 -=+")
        s.handle(key:0xff1b); output = ""
        if translating {
            type("ni",in:s); s.handle(key:32)
            let draft = s.draft
            for key in [45,61,43] { typeSymbol(key,shift:key == 43) }
            check(s.draft == draft+"-=+" && output.isEmpty && s.canRequestTranslation,"\(label)：已选完的草稿中符号正常追加")
            s.handle(key:0xff1b)
        }
        s.setASCIIMode(true)
        type("App",in:s)
        for key in [45,61,43] { typeSymbol(key,shift:key == 43) }
        check(output+s.draft == "App-=+" && !s.hasPendingInput,"\(label)：英文直输不拦截符号")
    }
    static func samePage(_ a:PinyinSnapshot,_ b:PinyinSnapshot)->Bool {
        a.page == b.page && a.highlighted == b.highlighted && a.candidates == b.candidates && a.input == b.input && a.preedit == b.preedit && a.caret == b.caret
    }
    @MainActor static func type(_ text:String,in s:CompositionSession) {
        for c in text.unicodeScalars { s.handle(key:Int(c.value)) }
    }
    static func check(_ condition:Bool,_ message:String) {
        precondition(condition,message)
        print("PASS:",message)
    }
}
