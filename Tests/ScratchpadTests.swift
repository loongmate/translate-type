import AppKit
import WebKit

@main struct ScratchpadTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        var checks = 0
        func check(_ value:Bool,_ label:String) { guard value else { print("FAIL:",label); exit(1) }; checks += 1; print("PASS:",label) }
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunScratchpadTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let rime = temp.appendingPathComponent("rime"), cache = root.appendingPathComponent(".build/editor-rime-cache")
        try FileManager.default.createDirectory(at:rime,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:rime.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:rime)
        let store = ScratchpadStore(url:temp.appendingPathComponent("scratchpad/draft.json"))
        let renderer = ScratchpadRenderer(library:root.appendingPathComponent("Resources/Preview/marked-18.1.1.umd.js"))
        let editor = ScratchpadEditor(store:store,renderer:renderer)
        defer { editor.hide() }
        var askCount = 0
        let indicator = InputLanguageIndicator(onAskAI:{ askCount += 1 },onScratchpad:{editor.show()})
        defer { indicator.remove() }
        let menu = indicator.item.menu!, askIndex = menu.items.firstIndex { $0.title == "问问 AI…" }!
        let entry = menu.items[askIndex+1]
        check(entry.title == "临时编辑器…","菜单入口紧接在问问 AI 下方")
        check(NSApp.sendAction(entry.action!,to:entry.target,from:entry) && editor.window.isVisible && askCount == 0,"菜单打开独立编辑器，不触发问 AI")
        let state = editor.session!
        check(!editor.previewVisible && state.draft.isEmpty,"初次打开只显示空白文本编辑器")
        check(DraftEditor.shared.session == nil && !state.agent.isRunning,"与问 AI 的草稿和会话相互独立")
        check(ScratchpadFormat.detect("# 标题",filename:nil) == .markdown,"自动识别 Markdown 标题")
        check(ScratchpadFormat.detect("这是 *斜体* 和 ~~删除线~~",filename:nil) == .markdown,"自动识别行内 Markdown")
        check(ScratchpadFormat.detect("一行普通文字\n保留换行",filename:nil) == .text,"普通文字保留为纯文本")
        check(ScratchpadFormat.detect("<section><h1>预览</h1></section>",filename:nil) == .html,"自动识别 HTML 片段")
        check(ScratchpadFormat.detect("```html\n<div>example</div>\n```",filename:nil) == .markdown,"HTML 代码围栏按 Markdown 渲染")
        check(ScratchpadFormat.detect("{\"answer\":42}",filename:nil) == .json,"自动识别有效 JSON")
        check(ScratchpadFormat.detect("plain",filename:"note.md") == .markdown,"打开文件时按 Markdown 扩展名识别")
        let markdown = """
        # 临时编辑器

        可以编辑 **Markdown**，在右侧实时预览。

        | 格式 | 支持 |
        | --- | --- |
        | Markdown | 表格、列表、代码 |
        | HTML | 页面和样式 |

        - [x] 支持中文输入
        - [ ] 继续整理草稿

        ```swift
        let greeting = "你好，方寸"
        ```

        > 内容自动保存在本机。
        """
        let parsed = try await renderer.render(markdown,format:.automatic)
        check(parsed.html.contains("<h1>") && parsed.html.contains("<table>") && parsed.html.contains("language-swift") && parsed.html.contains("type=\"checkbox\""),"真正解析标题、GFM 表格、代码围栏和任务列表")
        let plain = try await renderer.render("<unknown> & 1\n2",format:.text)
        check(plain.html.contains("&lt;unknown&gt; &amp; 1\n2"),"纯文本正确转义尖括号、符号并保留换行")
        let json = try await renderer.render("{\"answer\":42}",format:.automatic)
        check(json.format == .json && json.html.range(of:"&quot;answer&quot;\\s*:\\s*42",options:.regularExpression) != nil,"JSON 自动格式化预览")
        let incomplete = try await renderer.render("{",format:.json)
        check(incomplete.note != nil && incomplete.html.contains("<pre>{</pre>"),"不完整 JSON 保留原文供继续编辑")
        editor.replaceText(markdown); state.setASCIIMode(true)
        editor.setPreviewVisible(true)
        func awaitPreview(_ kind:ScratchpadFormat) async throws {
            for _ in 0..<400 {
                if editor.previewReady && editor.renderedPreview?.format == kind && editor.webView?.isLoading == false { return }
                try await Task.sleep(nanoseconds:25_000_000)
            }
            check(false,"预览在时限内完成")
        }
        func evaluate(_ script:String) async throws -> Any? { try await editor.webView!.evaluateJavaScript(script) }
        try await awaitPreview(.markdown)
        check(try await evaluate("document.querySelector('h1').textContent") as? String == "临时编辑器","右侧 WebKit 实际呈现 Markdown 标题")
        check(try await evaluate("document.querySelectorAll('table tbody tr').length") as? Int == 2,"右侧实际呈现 Markdown 表格")
        let width = editor.window.frame.width
        check(width >= min(1050,editor.window.screen!.visibleFrame.width),"展开预览时向右拓宽窗口")
        let image = try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<NSImage,Error>) in
            editor.webView!.takeSnapshot(with:nil) { image,error in
                if let image { continuation.resume(returning:image) } else { continuation.resume(throwing:error ?? AgentFailure("snapshot failed")) }
            }
        }
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(".build/build42-markdown-preview.png"))
        editor.replaceText("{\"answer\":42}"); try await awaitPreview(.json)
        check(try await evaluate("JSON.parse(document.querySelector('pre code').textContent).answer") as? Int == 42,"右侧 JSON 预览保留实际字段和值")
        editor.replaceText(markdown); try await awaitPreview(.markdown)
        editor.setPreviewVisible(false)
        check(state.draft == markdown && !editor.previewVisible,"收起预览保持编辑内容")
        editor.replaceText("<article style='padding:20px;background:#f3edff'><h1 style='color:#7857c2'>HTML 预览</h1><p>样式正常展示。</p><script>window.fromContent=true</script><img src='http://127.0.0.1:18888/should-not-load'><meta http-equiv=refresh content='0;url=http://127.0.0.1:18888/should-not-navigate'></article>")
        editor.setPreviewVisible(true); try await awaitPreview(.html)
        check(try await evaluate("document.querySelector('h1').textContent") as? String == "HTML 预览","自动切换 HTML 实际渲染")
        check(try await evaluate("getComputedStyle(document.querySelector('h1')).color") as? String == "rgb(120, 87, 194)","HTML 内联样式正常显示")
        check(try await evaluate("typeof window.fromContent") as? String == "undefined","自动预览不执行内容脚本")
        check(editor.webView!.url?.scheme == "about","HTML 自动跳转不能离开本地预览")
        check(try await evaluate("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content.includes(\"default-src 'none'\")") as? Bool == true,"本地预览限制外部资源加载")
        editor.setFormat(.text); try await awaitPreview(.text)
        check(try await evaluate("document.querySelector('h1') === null") as? Bool == true,"可手动改为纯文本而不渲染 HTML")
        editor.setPreviewVisible(false); editor.setFormat(.automatic)
        editor.replaceText(""); editor.history.removeAllActions(); state.setASCIIMode(false)
        var stamp:TimeInterval = 100
        func key(_ chars:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = []) {
            stamp += 0.03
            let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:stamp,windowNumber:editor.window.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)!
            editor.textView.keyDown(with:event)
        }
        for c in "nihao" { key(String(c)) }
        check(state.hasPendingInput && state.draft.isEmpty,"临时编辑器支持真实 Rime 中文预编辑")
        editor.clearText()
        check(state.hasPendingInput,"未确认中文时新建不会丢失输入")
        check(editor.draft.text == "nihao","自动恢复稿保留未确认拼音原码，不替用户选字")
        key(" ",49); check(state.draft == "你好","空格确认中文到文本编辑器")
        editor.history.undo(); check(state.draft.isEmpty,"中文输入可撤销")
        editor.history.redo(); check(state.draft == "你好","中文输入可重做")
        state.setASCIIMode(true); key("\r",36); key("x")
        check(state.draft == "你好\nx","英文、换行和中文混合编辑")
        key("\t",48); check(state.draft.hasSuffix("x\t"),"Tab 在文本中插入制表符")
        let sourceFile = temp.appendingPathComponent("opened.md")
        try "# 文件标题\n\n原始内容".write(to:sourceFile,atomically:true,encoding:.utf8)
        try editor.loadFile(sourceFile)
        check(editor.resolvedFormat == .markdown && state.draft.contains("文件标题"),"打开 UTF-8 文件并自动识别格式")
        state.replaceEditorText("# 修改后\n\n文本",selection:NSRange(location:0,length:0))
        let destination = temp.appendingPathComponent("saved.md"); try editor.export(to:destination)
        check(try String(contentsOf:destination,encoding:.utf8) == state.draft,"另存写入完整 UTF-8 文本")
        check(try String(contentsOf:sourceFile,encoding:.utf8).contains("原始内容"),"编辑和另存不自动覆盖打开的原文件")
        editor.setPreviewVisible(true); try await awaitPreview(.markdown)
        state.replaceEditorText("# 最新稿\n\n快速连续编辑一",selection:NSRange(location:0,length:0))
        state.replaceEditorText("# 修改后\n\n快速连续编辑的最终内容",selection:NSRange(location:0,length:0))
        editor.hide()
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds:20_000_000)
            if store.load() == editor.draft { break }
        }
        check(store.load() == editor.draft,"连续编辑后关闭窗口保存最新内容、格式和预览状态")
        let permissions = try FileManager.default.attributesOfItem(atPath:store.url.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600,"恢复稿仅当前用户可读写")
        editor.show(); check(state.draft.contains("修改后"),"再次打开保留同一编辑内容")
        let restored = ScratchpadEditor(store:store,renderer:renderer); restored.show()
        check(restored.session?.draft == state.draft && restored.previewVisible,"新实例恢复已保存内容和右侧预览状态")
        restored.hide()
        print("Scratchpad checks: \(checks)")
    }
}
