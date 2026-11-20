import AppKit
import WebKit

@main struct WorkspaceDesignTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { print("FAIL:",error); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func runChecks() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunWorkspaceTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        var checks = 0
        func check(_ value:Bool,_ label:String) { guard value else { print("FAIL:",label); exit(1) }; checks += 1; print("PASS:",label) }
        let rime = temp.appendingPathComponent("rime"), cache = root.appendingPathComponent(".build/editor-rime-cache")
        try FileManager.default.createDirectory(at:rime,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:rime.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:rime)
        func buttons(_ view:NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let renderer = ScratchpadRenderer(library:root.appendingPathComponent("Resources/Preview/marked-18.1.1.umd.js"))
        let scratch = ScratchpadEditor(store:ScratchpadStore(url:temp.appendingPathComponent("draft.json")),renderer:renderer)
        let markdown = "# 给想法一点空间\n\n有些想法，值得先记下来。\n不必急着整理，也不必立刻有答案。\n\n## 这周，想做的几件事\n\n- [x] 记录那些一闪而过的灵感\n- [ ] 把零散的笔记整理成文章\n- [ ] 留一个下午，专心做点喜欢的事\n\n## 一个小小的约定\n\n先写下来，再慢慢变好。\n让工具轻一点，让表达自由一点。\n\n> 方寸之间，也能装下很多可能。"
        scratch.show(); scratch.replaceText(markdown); scratch.setPreviewVisible(true)
        scratch.window.appearance = NSAppearance(named:.aqua)
        for _ in 0..<400 { if scratch.previewReady && scratch.webView?.isLoading == false { break }; try await Task.sleep(nanoseconds:25_000_000) }
        check(scratch.previewReady,"新布局中的 WebKit 预览完成")
        scratch.window.contentView!.layoutSubtreeIfNeeded()
        check(scratch.textView.enclosingScrollView!.rulersVisible && scratch.textView.enclosingScrollView!.verticalRulerView is WorkspaceLineNumbers,"编辑器显示原生行号栏")
        check(scratch.textView.enclosingScrollView!.frame.width > scratch.window.contentView!.frame.width*0.35,"编辑与预览正常平分可用宽度")
        check(scratch.textView.selectedRange().location <= scratch.textView.string.utf16.count,"语法着色保留有效文本选区")
        let dark = try await renderer.render(markdown,format:.markdown,dark:true)
        check(dark.html.contains("color-scheme:dark") && dark.html.contains("#2c2933"),"预览支持深色正文和背景")
        let transcript = ChatTranscriptView(frame:NSRect(x:0,y:0,width:700,height:420))
        let call = AgentToolCall(id:"call-1",name:"read_file",arguments:"{\"path\":\"想法.md\"}")
        let progress = AgentMessage(role:"assistant",calls:[call])
        let messages = [AgentMessage(role:"user",content:"整理本周想法"),progress,AgentMessage(role:"tool",content:"private-tool-result",callID:call.id,name:call.name),AgentMessage(role:"assistant",content:"## 行动清单\n\n- **收集灵感**：随手记录。\n- 留出一个下午。\n\n你好😀")]
        transcript.update(messages)
        check(!transcript.textView.string.contains("private-tool-result") && transcript.textView.string.contains("1 个工具步骤"),"工具详情默认折叠，回答可直接阅读")
        transcript.toggleToolDetails(progress.id)
        check(transcript.textView.string.contains("private-tool-result") && transcript.textView.string.contains("read_file"),"展开工具后保留真实参数与结果")
        transcript.textView.setSelectedRange((transcript.textView.string as NSString).range(of:"private-tool-result"))
        check(transcript.answerSelection(or:"fallback") == nil,"工具结果不能误作回答插入")
        transcript.textView.setSelectedRange((transcript.textView.string as NSString).range(of:"你好😀"))
        check(transcript.answerSelection(or:nil) == "你好😀","格式化回答的 UTF-16 选区完整保留 emoji")
        transcript.toggleToolDetails(progress.id)
        check(!transcript.textView.string.contains("private-tool-result"),"收起工具详情恢复精简消息流")
        let editor = DraftEditor.shared; editor.openQuestionFromMenu(); let state = editor.session!
        let provider = ModelConfiguration(endpoint:"http://127.0.0.1:18887/v1",model:"mock")
        state.agent.setDirectory(temp.path); state.agent.restore(messages,directory:temp.path,provider:provider)
        state.replaceEditorText("第一份草稿",selection:NSRange(location:5,length:0)); state.setEditorReference("第一份参考")
        editor.window.contentView!.layoutSubtreeIfNeeded()
        check(editor.source.enclosingScrollView!.frame.width > editor.window.contentView!.frame.width*0.6,"对话正文填满侧栏之外的宽度")
        let firstID = UUID(uuidString:buttons(editor.window.contentView!).first(where:{$0.title == "整理本周想法"})!.identifier!.rawValue)!
        editor.startNewConversation()
        check(state.agent.messages.isEmpty && state.draft.isEmpty && state.editorReference.isEmpty,"新对话保留旧会话并清空新输入和参考")
        state.agent.restore([AgentMessage(role:"user",content:"第二个任务"),AgentMessage(role:"assistant",content:"第二个回答")],directory:root.path,provider:provider)
        state.replaceEditorText("第二份草稿",selection:NSRange(location:5,length:0))
        let secondID = UUID(uuidString:buttons(editor.window.contentView!).first(where:{$0.title == "第二个任务"})!.identifier!.rawValue)!
        editor.switchConversation(firstID)
        check(state.agent.messages == messages && state.agent.directory == temp.path && state.agent.provider == provider,"切换会话恢复完整工具历史、目录和模型来源")
        check(state.draft == "第一份草稿" && state.editorReference == "第一份参考","切换会话恢复各自的草稿和参考")
        editor.switchConversation(secondID)
        check(state.agent.latestAnswer == "第二个回答" && state.draft == "第二份草稿","可再次切回新会话，不覆盖原有输入")
        editor.window.setContentSize(NSSize(width:820,height:600)); editor.window.contentView!.layoutSubtreeIfNeeded()
        check(editor.source.enclosingScrollView!.frame.width > 400 && editor.source.enclosingScrollView!.frame.height >= 75,"最小窗口保留可编辑的输入框")
        editor.selectMode(.transform); state.replaceEditorText("独立原文",selection:NSRange(location:4,length:0)); editor.selectMode(.ask)
        check(state.draft == "第二份草稿" && state.agent.latestAnswer == "第二个回答","新布局中的改文字与问 AI 保持独立")
        state.setASCIIMode(false)
        for character in "nihao" { _ = state.handle(key:Int(character.asciiValue!),shift:false) }
        let pending = state.snapshot.input
        editor.startNewConversation(); editor.switchConversation(firstID)
        check(state.hasPendingInput && state.snapshot.input == pending,"未确认拼音时禁止新建与切换会话")
        state.discardPendingInput(); state.agent.reset()
        _ = state.agent.send("停止测试",configuration:provider,readKey:{ _ in try await Task.sleep(nanoseconds:500_000_000); return "" })
        editor.startNewConversation(); try await Task.sleep(nanoseconds:550_000_000)
        check(!state.agent.isRunning && state.agent.messages.isEmpty,"新对话终止旧请求，迟到内容不会写入新会话")
        editor.window.setContentSize(NSSize(width:1060,height:720)); editor.switchConversation(firstID)
        state.setEditorReference(""); state.replaceEditorText("",selection:NSRange(location:0,length:0)); state.agent.restore(messages,directory:root.path,provider:provider)
        editor.window.appearance = NSAppearance(named:.aqua); editor.refresh(); editor.window.contentView!.layoutSubtreeIfNeeded()
        try editor.capture(to:root.appendingPathComponent(".build/workspace-ai-native.png"))
        print("Workspace design checks: \(checks)")
        if CommandLine.arguments.contains("--preview") {
            if let reference = buttons(editor.window.contentView!).first(where:{$0.title.hasPrefix("参考文字") && $0.state == .on}) { reference.performClick(nil) }
            let controls = WorkspacePreviewControls(scratch:scratch,editor:editor)
            let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
            let submenu = NSMenu(title:"方寸设计验收"); appItem.submenu = submenu
            for (title,key,action) in [("临时编辑器","1",#selector(WorkspacePreviewControls.showScratchpad)),("问问 AI","2",#selector(WorkspacePreviewControls.showChat))] {
                let item = NSMenuItem(title:title,action:action,keyEquivalent:key); item.target = controls; submenu.addItem(item)
            }
            NSApp.mainMenu = menu
            NSApp.setActivationPolicy(.regular)
            scratch.hide(); editor.show(); NSApp.activate(ignoringOtherApps:true)
            print("WORKSPACE_PREVIEW_READY")
            while true {
                withExtendedLifetime(controls) {}
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
        editor.hide(); scratch.hide()
    }
}

@MainActor final class WorkspacePreviewControls: NSObject {
    let scratch: ScratchpadEditor, editor: DraftEditor
    init(scratch:ScratchpadEditor,editor:DraftEditor) { self.scratch = scratch; self.editor = editor }
    @objc func showScratchpad() { editor.hide(); scratch.show() }
    @objc func showChat() { scratch.hide(); editor.show() }
}
