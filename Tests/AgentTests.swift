import AppKit
import InputMethodKit

@main struct AgentTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunAgentTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        var checks = 0
        func check(_ value:Bool,_ label:String) { guard value else { print("FAIL:",label); exit(1) }; checks += 1; print("PASS:",label) }
        func config(_ path:String = "agent") -> ModelConfiguration { ModelConfiguration(endpoint:"http://127.0.0.1:18887/"+path,model:"mock") }
        func settle(_ agent:AgentSession) async throws {
            for _ in 0..<500 { if !agent.isRunning { return }; try await Task.sleep(nanoseconds:20_000_000) }
            check(false,"agent 在时限内完成")
        }
        func call(_ tools:AgentTools,_ name:String,_ args:[String:Any]) async throws -> String {
            try await tools.execute(AgentToolCall(id:UUID().uuidString,name:name,arguments:String(decoding:try JSONSerialization.data(withJSONObject:args),as:UTF8.self)))
        }
        func object(_ text:String) throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any] }
        let tools = AgentTools(directory:temp.path)
        _ = try await call(tools,"write_file",["path":"folder/a.txt","content":"one\ntwo\ntwo"])
        var read = try object(await call(tools,"read_file",["path":"folder/a.txt","offset":1,"limit":1]))
        check(read["content"] as? String == "2: two","按行读取并标注行号")
        do { _ = try await call(tools,"edit_file",["path":"folder/a.txt","old_string":"two","new_string":"three"]); check(false,"模糊修改应拒绝") } catch { check(true,"精确修改拒绝多处匹配") }
        _ = try await call(tools,"edit_file",["path":"folder/a.txt","old_string":"two","new_string":"three","replace_all":true])
        read = try object(await call(tools,"read_file",["path":"folder/a.txt"]))
        check((read["content"] as? String)?.contains("three") == true,"显式 replace_all 修改全部匹配")
        let found = try object(await call(tools,"glob_search",["pattern":"**/*.txt"]))
        check((found["results"] as? [String])?.count == 1,"glob ** 同时匹配根及子目录")
        let grep = try object(await call(tools,"grep_search",["pattern":"THREE","-i":true]))
        check((grep["results"] as? [String])?.count == 2,"内容正则搜索和忽略大小写")
        do { _ = try await call(tools,"write_file",["path":"bad","content":12]); check(false,"错误类型应拒绝") } catch { check(true,"参数校验拒绝错误类型") }
        do { _ = try await call(tools,"read_file",["path":"folder/a.txt","offset":true]); check(false,"Bool 不能作整数") } catch { check(true,"JSON 布尔与整数严格区分") }
        do { _ = try await call(tools,"shell_exec",["cmd":"echo x","tty":true]); check(false,"不支持字段应拒绝") } catch { check(true,"不支持的参数不能静默忽略") }
        let shell = try object(await call(tools,"shell_exec",["cmd":"read line; printf 'got:%s' \"$line\"","background":true]))
        let shellID = shell["shell_id"] as! String
        check(shell["status"] as? String == "running","后台命令返回真实 running 状态")
        _ = try await call(tools,"shell_io",["op":"write","shell_id":shellID,"chars":"hello\n"])
        let output = try object(await call(tools,"shell_io",["op":"read","shell_id":shellID,"yield_time_ms":1000]))
        check(output["status"] as? String == "exited" && output["exit_code"] as? Int == 0 && (output["output"] as? String)?.contains("got:hello") == true,"stdin 交互、输出和退出码")
        let long = try object(await call(tools,"shell_exec",["cmd":"sleep 2; touch must-not-run","background":true]))
        _ = try await call(tools,"shell_manage",["op":"stop","shell_id":long["shell_id"]!])
        try await Task.sleep(nanoseconds:100_000_000)
        check(!FileManager.default.fileExists(atPath:temp.appendingPathComponent("must-not-run").path),"停止命令组阻止后续操作")
        _ = try await call(tools,"shell_exec",["cmd":"printf '%s' \"$PWD\"","yield_time_ms":1000])
        let noisy = try object(await call(tools,"shell_exec",["cmd":"yes x | head -c 200000; touch noisy-done","background":true]))
        try await Task.sleep(nanoseconds:500_000_000)
        check(FileManager.default.fileExists(atPath:temp.appendingPathComponent("noisy-done").path),"后台命令持续排空输出，不因管道写满而阻塞")
        let noisyResult = try object(await call(tools,"shell_io",["op":"read","shell_id":noisy["shell_id"]!,"yield_time_ms":1000]))
        check((noisyResult["omitted_bytes"] as? Int ?? 0) > 0 && (noisyResult["output"] as? String ?? "").utf8.count <= 64_000,"命令输出尾部有界并报告截断")
        await tools.stopAll()
        do { _ = try await call(tools,"write_file",["path":"after-stop","content":"bad"]); check(false,"已停止工具不可执行") } catch { check(true,"停止后不再执行工具") }
        check(AgentTools.plain("<script>bad()</script><p>A &amp; B</p>") == "A & B","网页提取移除脚本")

        let agent = AgentSession(); agent.setDirectory(temp.path)
        var sawPartial = false, sawTool = false
        agent.onUpdate = {
            if agent.isRunning && agent.messages.contains(where:{$0.role == "assistant" && !$0.content.isEmpty && $0.state == "running"}) { sawPartial = true }
            if agent.messages.contains(where:{$0.role == "tool" && $0.state == "running"}) { sawTool = true }
        }
        check(agent.send("写文件、修改、读取并运行命令",configuration:config(),readKey:{ _ in "test-only" }),"接受首条任务")
        check(!agent.send("重复",configuration:config(),readKey:{ _ in "" }),"运行中重复发送被拒绝")
        try await settle(agent)
        if let error = agent.error { print("Agent error:",error) }
        check(sawPartial && sawTool,"流式回答和工具进行状态可观察")
        check(agent.latestAnswer == "已完成。" && agent.error == nil,"自动连续四轮模型调用直至最终回答")
        check(try String(contentsOf:temp.appendingPathComponent("note.txt"),encoding:.utf8) == "你好，方寸","模型实际调用写入和编辑工具")
        check(agent.messages.filter { $0.role == "tool" }.count == 4,"同轮多个工具按调用 ID 回传")
        let toolText = agent.messages.first(where:{$0.name == "read_file"})?.content ?? ""
        check(toolText.contains("你好，方寸"),"后续工具读取上一工具修改后的内容")
        let (recordsData,_) = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:18887/records")!)
        let records = try object(String(decoding:recordsData,as:UTF8.self))["requests"] as! [[String:Any]]
        let request = records.last!, history = request["messages"] as! [[String:Any]]
        check(request["stream"] as? Bool == true && request["tools"] != nil,"请求使用标准 stream 和 tools 协议")
        check(history.filter { $0["role"] as? String == "tool" }.allSatisfy { $0["tool_call_id"] != nil } && history.contains { $0["tool_calls"] != nil },"完整 assistant/tool 调用协议历史")
        _ = agent.send("再确认一下",configuration:config(),readKey:{ _ in "" }); try await settle(agent)
        check(agent.messages.filter { $0.role == "user" }.count == 2 && agent.latestAnswer == "已完成。","继续对话保留全部历史")
        check(!agent.send("changed",configuration:config("slow"),readKey:{ _ in "" }),"切换服务不会泄露当前会话")
        agent.reset(); _ = agent.send("不完整工具",configuration:config("truncated"),readKey:{ _ in "" }); try await settle(agent)
        check(agent.error?.contains("中断") == true && !FileManager.default.fileExists(atPath:temp.appendingPathComponent("must-not-exist.txt").path),"不完整 SSE 工具不会执行")
        agent.reset(); _ = agent.send("slow",configuration:config("slow"),readKey:{ _ in "" }); agent.stop()
        let stopped = agent.messages
        try await Task.sleep(nanoseconds:300_000_000)
        check(!agent.isRunning && agent.messages == stopped,"停止后晚到数据不会更改消息")
        agent.reset(); _ = agent.send("loop",configuration:config("loop"),readKey:{ _ in "" }); try await settle(agent)
        check(agent.error?.contains("16 轮") == true && agent.messages.filter { $0.role == "tool" && $0.state == "failed" }.count == 16,"工具错误回传及多轮上限")
        check(!FileManager.default.fileExists(atPath:temp.appendingPathComponent("must-not-run").path),"命令子进程在原等待时间后仍未产生副作用")
        agent.reset(); _ = agent.send("hello",configuration:config("v1"),readKey:{ _ in "" }); try await settle(agent)
        check(agent.latestAnswer == "Hello.","多字节分片与普通流式回答")
        agent.reset(); _ = agent.send("hello",configuration:config("error"),readKey:{ _ in "" }); try await settle(agent)
        check(agent.error?.contains("限流") == true,"服务错误可操作且保留用户消息")
        agent.reset(); _ = agent.send("hello",configuration:config("redirect"),readKey:{ _ in "" }); try await settle(agent)
        check(agent.error?.contains("重定向") == true,"不跟随模型接口重定向以保护凭据")
        agent.reset()
        _ = agent.send("cancel key read",configuration:config("v1"),readKey:{ _ in try await Task.sleep(nanoseconds:300_000_000); return "" })
        agent.stop(); try await Task.sleep(nanoseconds:350_000_000)
        check(agent.messages.count == 1 && !agent.isRunning,"读取凭据期间停止不会启动模型或工具")

        // Real native editor integration and Rime composer, all with a local fake provider.
        let rime = temp.appendingPathComponent("rime")
        try FileManager.default.createDirectory(at:rime,withIntermediateDirectories:true)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:rime.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:rime)
        let editor = DraftEditor.shared
        editor.openQuestionFromMenu()
        let state = editor.session!
        state.configuration = { config("v1") }; state.readKey = { _ in "" }
        state.agent.setDirectory(temp.path)
        state.replaceEditorText("你好",selection:NSRange(location:2,length:0)); editor.requestTranslation()
        check(state.draft.isEmpty && state.agent.isRunning,"发送清空输入框、消息保留在对话中")
        state.replaceEditorText("下一条草稿",selection:NSRange(location:5,length:0))
        try await settle(state.agent)
        check(state.draft == "下一条草稿" && editor.transcript.textView.string.contains("Hello."),"生成时可写下一条，消息实时呈现")
        check(editor.selectedResult == "Hello.","插入只取已完成的 AI 回答")
        let userPosition = (editor.transcript.textView.string as NSString).range(of:"你好")
        editor.transcript.textView.setSelectedRange(userPosition)
        check(editor.selectedResult == nil,"选中用户文字不会误作 AI 回答插入")
        editor.transcript.textView.setSelectedRange(NSRange(location:0,length:0))
        let archive = state.editorArchive
        editor.selectMode(.transform); state.replaceEditorText("原文独立",selection:NSRange(location:4,length:0))
        editor.selectMode(.ask)
        check(state.draft == "下一条草稿" && state.agent.latestAnswer == "Hello.","切换模式保留独立草稿和消息历史")
        state.agent.reset(); state.restoreArchive(archive)
        check(state.agent.latestAnswer == "Hello." && state.agent.directory == temp.path,"归档恢复消息和工作目录")
        try editor.capture(to:root.appendingPathComponent(".build/build41-agent-chat.png"))
        editor.hide()
        print("Agent checks: \(checks)")
    }
}
