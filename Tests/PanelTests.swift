import AppKit

@main struct PanelTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunPanelTests-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let panel = CandidatePanel()
        defer { panel.orderOut(nil) }
        let visible = NSScreen.main!.visibleFrame
        let anchor = NSRect(x:visible.midX-300,y:visible.midY+120,width:1,height:20)
        func show(_ s:CompositionSession) async throws {
            panel.show(session:s,anchor:anchor,settings:{})
            try await Task.sleep(nanoseconds:100_000_000)
            panel.contentView!.layoutSubtreeIfNeeded()
            precondition(visible.contains(panel.frame),"窗口必须完整留在屏幕内")
        }
        func capture(_ name:String) throws {
            let view = panel.contentView!
            let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(".build/build15-\(name).png"))
            print("RENDER:",name,"window",panel.frame.size)
        }
        let s = CompositionSession(engine:try PinyinEngine(layout:.sogou),translateEnabled:true)
        var output = ""; s.onInsert = { output += $0 }
        type("nizvhkhewouoyixwm;tmhlybdoih",in:s)
        let expected = s.candidates[0]
        precondition(expected.count > 8,"需要截图中的长候选场景")
        try await show(s); try capture("reported-long-candidate")
        print("FULL CANDIDATE:",expected)
        check(panel.frame.width <= 600 && !panel.canBecomeKey,"长句换行，窗口不抢输入焦点")
        s.handle(key:32)
        check(s.draft == expected && output.isEmpty,"空格完整确认长候选，保留译英草稿")
        s.handle(key:0xff1b)

        // Long real pinyin input, followed by caret movement within that input.
        type(String(repeating:"ni",count:200),in:s)
        try await show(s); try capture("long-pinyin")
        let composition = scrolls(panel).first { $0.identifier?.rawValue == "composition-scroll" }!
        let text = composition.documentView as! NSTextView
        print("COMPOSITION GEOMETRY:",text.frame,composition.contentView.bounds)
        check(text.string.replacingOccurrences(of:"│",with:"") == s.markedText,"长拼音的原生文本视图包含全部内容")
        check(text.frame.height > composition.contentView.bounds.height && composition.contentView.bounds.minY > 0,"超长拼音可滚动，并自动跟随末尾光标")
        check(caretVisible(in:composition,text:text),"拼音末尾的光标在可见区域")
        for _ in 0..<110 { s.handle(key:0xff51) }
        try await show(s)
        check(caretVisible(in:composition,text:text),"向左编辑长拼音时自动显示当前光标")
        try capture("long-pinyin-caret")
        composition.contentView.scroll(to:.zero); composition.reflectScrolledClipView(composition.contentView)
        check(composition.contentView.bounds.minY == 0,"可滚回查看长拼音开头")
        s.handle(key:0xff1b)

        for _ in 0..<50 { type("nihk",in:s); s.handle(key:32) }
        type("nizvhk",in:s)
        try await show(s); try capture("draft-and-pinyin")
        let withDraft = scrolls(panel).first { $0.identifier?.rawValue == "composition-scroll" }!.documentView as! NSTextView
        check(withDraft.string.replacingOccurrences(of:"│",with:"") == s.markedText && withDraft.string.hasPrefix(s.draft),"已选中文草稿和后续拼音都完整保留在窗口中")
        s.handle(key:0xff1b)

        type("nihk",in:s); s.handle(key:32)
        s.configuration = { ModelConfiguration(endpoint:"http://127.0.0.1:18887/long",model:"panel-test") }
        s.readKey = { _ in "synthetic-test-key" }
        s.requestTranslation()
        for _ in 0..<100 {
            if !s.isTranslating { break }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        precondition(s.translation?.hasSuffix("END OF TRANSLATION") == true,"本机模拟长译文失败：\(s.errorMessage ?? "无结果")")
        let translated = s.translation!
        try await show(s); try capture("long-translation-top")
        check(panel.frame.height <= 420,"超长译文不会把窗口撑出屏幕")
        let candidates = scrolls(panel).first { $0.identifier?.rawValue != "composition-scroll" }!
        check(candidates.documentView!.frame.height > candidates.contentView.bounds.height,"译文区有可滚动的完整文档")
        candidates.contentView.scroll(to:NSPoint(x:0,y:candidates.documentView!.frame.height-candidates.contentView.bounds.height))
        candidates.reflectScrolledClipView(candidates.contentView)
        try await Task.sleep(nanoseconds:100_000_000)
        try capture("long-translation-bottom")
        check(candidates.contentView.bounds.minY > 0,"可滚到长译文末尾")
        // Start at the top, then let the keyboard reveal the Chinese result.
        candidates.contentView.scroll(to:.zero); candidates.reflectScrolledClipView(candidates.contentView)
        s.handle(key:0xff54)
        try await show(s); try capture("translation-chinese-selected")
        check(candidates.contentView.bounds.minY > 0,"切换结果候选时自动滚到选中的原文")
        s.handle(key:0xff52)
        try await show(s)
        check(candidates.contentView.bounds.minY < 1,"返回英文候选时显示译文开头")
        s.handle(key:32)
        check(output == translated,"长译文完整上屏，没有截断")

        for corner in [NSPoint(x:visible.minX,y:visible.minY),NSPoint(x:visible.maxX-1,y:visible.maxY-1)] {
            let frame = CandidatePanel.placement(size:NSSize(width:600,height:420),anchor:NSRect(origin:corner,size:NSSize(width:1,height:20)),visible:visible)
            check(visible.contains(frame),"屏幕边缘的候选窗完整可见")
        }
        let compactScreen = NSRect(x:-640,y:0,width:640,height:300)
        check(compactScreen.contains(CandidatePanel.placement(size:NSSize(width:600,height:900),anchor:NSRect(x:-20,y:50,width:1,height:20),visible:compactScreen)),"小屏和负坐标屏幕的边界计算正确")
        print("ALL PANEL TESTS PASSED")
    }
    @MainActor static func scrolls(_ view:NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
    }
    @MainActor static func scrolls(_ panel:CandidatePanel) -> [NSScrollView] { scrolls(panel.contentView!) }
    @MainActor static func caretVisible(in scroll:NSScrollView,text:NSTextView)->Bool {
        let range = (text.string as NSString).range(of:"│")
        let glyph = text.layoutManager!.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
        let rect = text.layoutManager!.boundingRect(forGlyphRange:glyph,in:text.textContainer!)
        return scroll.contentView.bounds.intersects(rect)
    }
    @MainActor static func type(_ value:String,in s:CompositionSession) { for c in value.unicodeScalars { s.handle(key:Int(c.value)) } }
    static func check(_ condition:Bool,_ message:String) { precondition(condition,message); print("PASS:",message) }
}
