import AppKit
import InputMethodKit
import Carbon

@main struct ClientBehaviorAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunClientAudit-"+UUID().uuidString)
        try PinyinEngine.initialize(resources:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let previous = ConfigurationStore.shared.translateEnabled
        defer { ConfigurationStore.shared.translateEnabled = previous }
        let server = IMKServer(name:"FangCunAudit_"+UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        var results: [[String:Any]] = []
        func run(_ id:String,_ steps:String,_ expected:String,_ action:(TTInputController,TextClient,(String,UInt16,NSEvent.ModifierFlags)->Bool)->Bool?) {
            ConfigurationStore.shared.translateEnabled = false
            let client = TextClient(), controller = TTInputController(server:server,delegate:nil,client:nil)!
            controller.activateServer(client)
            var tick: TimeInterval = 1
            func key(_ chars:String,_ code:UInt16 = 0,_ flags:NSEvent.ModifierFlags = []) -> Bool {
                tick += 0.02
                return controller.handle(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:tick,windowNumber:0,context:nil,characters:chars,charactersIgnoringModifiers:chars.lowercased(),isARepeat:false,keyCode:code)!,client:client)
            }
            let result = action(controller,client,key)
            let status = result.map { $0 ? "PASS" : "FAIL" } ?? "REVIEW"
            results.append(["id":id,"status":status,"steps":steps,"expected":expected,"text":client.text.string,
                            "hasMarkedText":client.text.hasMarkedText(),"selection":NSStringFromRange(client.text.selectedRange()),"markedRange":NSStringFromRange(client.text.markedRange())])
            print(status,id,client.text.string)
            controller.deactivateServer(client)
        }
        func type(_ value:String,_ key:(String,UInt16,NSEvent.ModifierFlags)->Bool) { for c in value { _ = key(String(c),0,[]) } }
        func middle(_ key:(String,UInt16,NSEvent.ModifierFlags)->Bool) { type("nihao",key); for _ in 0..<3 { _ = key("\u{f702}",123,[]) } }
        run("CLIENT-CLICK","ni│hao → 输入区域鼠标按下","保留光标后的 hao，不能只剩你") { controller,client,key in
            middle(key)
            let click = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:2,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            _ = controller.handle(click,client:client)
            return ["nihao","你hao","你好"].contains(client.text.string)
        }
        run("CLIENT-DEACTIVATE","ni│hao → deactivateServer","保留光标后的 hao，不能只剩你") { controller,client,key in
            middle(key); controller.deactivateServer(client); return ["nihao","你hao","你好"].contains(client.text.string)
        }
        run("CLIENT-PARTIAL-ENTER","ni│hao → Space → Enter","已选的你保留，只把 hao 原样确认") { _,client,key in
            middle(key); _ = key(" ",49,[]); _ = key("\r",36,[]); return client.text.string == "你hao"
        }
        run("CLIENT-DRAFT-EDIT","译英 → nihao → Space → ← → Backspace","光标在你和好之间时退格，剩下好") { _,client,key in
            _ = key("e",14,[.control,.shift]); type("nihao",key); _ = key(" ",49,[])
            // Simulate the host's fallback only for keys the IME did not handle.
            if !key("\u{f702}",123,[]) { client.text.moveLeft(nil) }
            if !key("\u{8}",51,[]) { client.text.deleteBackward(nil) }
            return client.text.string == "好"
        }
        run("CLIENT-BLOCK","译英 → ni│hao → Ctrl+Enter","输入和光标保持不变") { _,client,key in
            _ = key("e",14,[.control,.shift]); middle(key)
            let before = client.text.string, range = client.text.selectedRange()
            let handled = key("\r",36,[.control])
            return handled && client.text.string == before && client.text.selectedRange() == range && client.text.hasMarkedText()
        }
        run("CLIENT-PUNCT","译英 → nihao → Space → 鼠标按下 → .","记录已上屏中文和单独待确认句号的边界") { controller,_,key in
            _ = key("e",14,[.control,.shift]); type("nihao",key); _ = key(" ",49,[])
            let click = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:2,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1)!
            _ = controller.handle(click,client:nil); _ = key(".",47,[])
            return nil
        }
        let failed = results.filter { $0["status"] as? String == "FAIL" }.count
        let reviews = results.filter { $0["status"] as? String == "REVIEW" }.count
        let report:[String:Any] = ["generatedAt":ISO8601DateFormatter().string(from:Date()),"level":"真实 IMK 控制器与 NSTextView，人工投递事件；非系统端到端",
                                  "realModelCalls":0,"total":results.count,"passed":results.count-failed-reviews,"failed":failed,"review":reviews,"cases":results]
        let path = CommandLine.arguments.dropFirst().first ?? ".build/client-behavior-audit.json"
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        if failed > 0 { exit(1) }
    }
}
