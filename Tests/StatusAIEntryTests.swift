import AppKit
import InputMethodKit

@main struct StatusAIEntryTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunStatusAIEntry-"+UUID().uuidString)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let settings = ConfigurationStore.shared
        let previousAction = settings.selectedActionID
        settings.selectedActionID = "english"
        defer { settings.selectedActionID = previousAction }
        let editor = DraftEditor.shared
        let indicator = InputLanguageIndicator(onAskAI:{ editor.openQuestionFromMenu() })
        defer { editor.hide(); indicator.remove() }
        let ask = indicator.item.menu!.items.first { $0.title == "问问 AI…" }!
        func click() { precondition(NSApp.sendAction(ask.action!,to:ask.target,from:ask)) }
        func check(_ condition:Bool,_ message:String) { precondition(condition,message); print("PASS:",message) }
        func settle() async throws {
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds:30_000_000)
                if !editor.isHandingOff { return }
            }
            check(false,"焦点交接在时限内完成")
        }

        click(); try await settle()
        let original = editor.session!
        check(editor.isVisible && original.editorMode == .ask && editor.window.firstResponder === editor.source,"首次点击图标菜单直接打开问 AI，并把光标放入问题输入区")
        check(!editor.canCommitSource && editor.destinationMessage.contains("未绑定"),"没有宿主输入框也能提问，不伪造上屏目标")
        check(!original.isTranslating,"打开问 AI 不自动调用模型")
        original.replaceEditorText("安排一个轻松的周末",selection:NSRange(location:9,length:0))
        let question = original.draft
        editor.hide(); click(); try await settle()
        check(editor.isVisible && editor.session === original && original.draft == question,"再次点击继续同一问题，不清空或创建重复编辑会话")

        editor.selectMode(.transform)
        original.replaceEditorText("需要保留的改文字草稿",selection:NSRange(location:10,length:0))
        let transform = original.draft
        click()
        check(original.editorMode == .ask && original.draft == question,"从改文字入口跳到已有问 AI 草稿")
        editor.selectMode(.transform)
        check(original.draft == transform,"问 AI 入口保留改文字草稿")
        _ = original.handle(key:110)
        let pending = original.snapshot.input
        click()
        check(original.editorMode == .transform && original.snapshot.input == pending,"有未确认拼音时保留原输入，不代替用户选词")
        original.discardPendingInput()

        let host = TextClient(bundleID:"com.fangcun.StatusAIHost")
        host.text.string = "前后"; host.text.setSelectedRange(NSRange(location:1,length:0))
        editor.hostActivated(host,sessionID:UUID(),resume:{ _,_ in false })
        editor.recoverDestination(); try await settle()
        check(editor.canCommitSource && host.text.string == "前后","独立问题会话可显式绑定后来的输入框，绑定本身不写入文字")
        editor.commitSource(); try await settle()
        check(!editor.hasDraft && host.text.string == "前"+transform+"后","独立会话绑定后的上屏流程正常")

        let state = CompositionSession(engine:try PinyinEngine(layout:.fullPinyin),translateEnabled:false)
        state.beginEditor(); state.replaceEditorText("已有草稿",selection:NSRange(location:4,length:0))
        editor.open(session:state,client:host,sessionID:UUID(),resume:{ _,_ in false })
        try await settle(); click()
        check(editor.session === state && state.editorMode == .ask && state.draft == "已有草稿","已有临时编辑会话直接切到问 AI，保留文字及宿主")
        editor.selectMode(.transform)
        check(state.draft == "已有草稿","从问 AI 返回后原稿仍在")
        editor.commitSource(); try await settle()
        let server = IMKServer(name:"FangCunStatusAITests_"+UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        let controller = TTInputController(server:server,delegate:nil,client:host)!
        controller.activateServer(host)
        check(controller.openAIQuestionFromStatus(),"当前输入框可由状态图标沿用原来的问 AI 打开流程")
        try await settle()
        check(editor.session?.editorMode == .ask && !editor.destinationMessage.contains("未绑定"),"从当前输入框打开问 AI 时保留上屏目标")
        controller.deactivateServer(host)
        check(!controller.openAIQuestionFromStatus(),"失去输入客户端后交给独立打开流程，不访问过期客户端")
        print("ALL STATUS AI ENTRY TESTS PASSED")
    }
}
