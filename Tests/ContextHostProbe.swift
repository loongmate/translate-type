import AppKit
import WebKit
import Carbon
import CryptoKit

// Own, disposable AppKit and WebKit fields. Expected text is a fixed fixture;
// the installed IME returns only hashes and ranges through an opt-in probe.
@MainActor final class ContextHostProbe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let first = NSTextView(frame:NSRect(x:16,y:235,width:310,height:190))
    let second = NSTextView(frame:NSRect(x:16,y:20,width:310,height:190))
    let web = WKWebView(frame:NSRect(x:342,y:20,width:520,height:405))
    var window:NSWindow!
    var loaded = false
    var rows:[[String:Any]] = []
    var warmup:[[String:Any]] = []
    var previous:String?
    var inputReport:URL { URL(fileURLWithPath:CommandLine.arguments[1]) }
    var outputReport:URL { URL(fileURLWithPath:CommandLine.arguments[2]) }
    func applicationDidFinishLaunching(_ notification:Notification) {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:880,height:445),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "方寸 · 已上屏上下文能力验证（固定测试文本）"
        for text in [first,second] { text.font = .systemFont(ofSize:20); text.isRichText = false; window.contentView!.addSubview(text) }
        web.navigationDelegate = self; window.contentView!.addSubview(web)
        web.loadHTMLString("""
        <meta charset="utf-8"><style>body{font:18px system-ui;margin:20px}input,textarea,[contenteditable]{display:block;font:20px system-ui;border:1px solid #bbb;margin:8px 0 18px;padding:10px;box-sizing:border-box;width:100%;min-height:48px}textarea{height:80px}</style>
        <label>普通文本框<input id="plain"></label><label>多行文本<textarea id="area"></textarea></label><label>富文本输入<div id="rich" contenteditable="true"></div></label>
        """,baseURL:nil)
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(first); NSApp.activate(ignoringOtherApps:true)
        Task { @MainActor in await run() }
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { loaded = true }
    func wait(_ seconds:Double) async { try? await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) }
    func hash(_ text:String) -> String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
    func compose(_ action:String) async {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.fangcun.context-probe.sample"),object:nil,userInfo:["fixtureAction":action,"bundle":Bundle.main.bundleIdentifier!],deliverImmediately:true)
        await wait(0.25)
    }
    func reportRows(_ token:String) -> [[String:Any]] {
        guard let data = try? String(contentsOf:inputReport,encoding:.utf8) else { return [] }
        return data.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }.filter { $0["token"] as? String == token }
    }
    func sample(_ id:String,_ expected:String) async {
        guard NSApp.isActive, window.isKeyWindow, let view = window.firstResponder as? NSView, let context = view.inputContext else {
            rows.append(["case":id,"result":"SKIP","reason":"no-focused-input-context"]); return
        }
        if previous == nil { previous = context.selectedKeyboardInputSource }
        if context.selectedKeyboardInputSource != "com.translatetype.inputmethod.TranslateType.Hans" {
            context.selectedKeyboardInputSource = "com.translatetype.inputmethod.TranslateType.Hans"
        }
        if NSTextInputContext.current !== context { context.activate() }
        await wait(0.3)
        let event = NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56)!
        _ = context.handleEvent(event)
        await wait(0.2)
        let token = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.fangcun.context-probe.sample"),object:nil,userInfo:["token":token,"bundle":Bundle.main.bundleIdentifier!],deliverImmediately:true)
        var reports:[[String:Any]] = []
        for _ in 0..<20 { await wait(0.1); reports = reportRows(token); if !reports.isEmpty { break } }
        if reports.isEmpty { rows.append(["case":id,"result":"UNAVAILABLE","reason":"no-probe-reply"]); print("UNAVAILABLE",id); return }
        let matches = reports.allSatisfy { $0["sha256"] as? String == hash(expected) }
        let unavailable = reports.allSatisfy { $0["sha256"] == nil }
        let result = matches ? "MATCH" : unavailable ? "UNAVAILABLE" : "MISMATCH"
        rows.append(["case":id,"result":result,"observations":reports]); print(result,id)
    }
    func native(_ id:String,_ text:NSTextView,_ value:String,_ selection:NSRange? = nil,_ expected:String? = nil) async {
        first.unmarkText(); second.unmarkText(); window.makeFirstResponder(text)
        text.string = value; text.setSelectedRange(selection ?? NSRange(location:value.utf16.count,length:0))
        await sample(id,expected ?? value)
    }
    func browser(_ id:String,_ field:String,_ value:String,_ start:Int,_ end:Int? = nil,_ expected:String) async {
        let literal = String(data:try! JSONSerialization.data(withJSONObject:[value]),encoding:.utf8)!
        let code = """
        (()=>{const e=document.getElementById('\(field)'),s=\(literal)[0];e.focus();
        if(e.isContentEditable){e.textContent=s;const r=document.createRange();r.setStart(e.firstChild,\(start));r.setEnd(e.firstChild,\(end ?? start));getSelection().removeAllRanges();getSelection().addRange(r);}
        else {e.value=s;e.setSelectionRange(\(start),\(end ?? start));}return document.activeElement.id;})()
        """
        do { _ = try await web.evaluateJavaScript(code) } catch { rows.append(["case":id,"result":"SKIP","reason":"web-setup-failed"]); return }
        await wait(0.15); await sample(id,expected)
    }
    func run() async {
        await wait(1)
        for _ in 0..<30 { if loaded { break }; await wait(0.1) }
        // Registration being selectable does not mean a newly installed IMK
        // server has finished starting. Establish the real connection first.
        first.string = "上"; first.setSelectedRange(NSRange(location:1,length:0))
        for _ in 0..<8 {
            await sample("connection-warmup","上")
            let attempt = rows.removeLast(); warmup.append(attempt)
            if attempt["result"] as? String == "MATCH" { break }
            if attempt["result"] as? String == "SKIP" { break }
        }
        await native("native-committed-shang",first,"上")
        await native("native-longer-context",first,"墙上")
        await native("native-middle-caret",first,"我要去上海",NSRange(location:4,length:0),"我要去上")
        await native("native-selection",first,"上尾巴",NSRange(location:1,length:2),"上")
        await native("native-field-switch-same-caret",second,"下")
        await native("native-return-first-field",first,"上")
        await compose("begin-pinyin")
        await sample("native-exclude-pinyin","上")
        await compose("cancel-pinyin")
        await native("native-delete-all",first,"")
        await native("native-multiline-emoji",first,"🙂第一行\n上")
        await native("native-bounded-long-text",first,String(repeating:"甲",count:200)+"上",nil,String(repeating:"甲",count:63)+"上")
        if loaded {
            window.makeFirstResponder(web)
            await browser("web-input","plain","上",1,nil,"上")
            await browser("web-textarea","area","墙上",2,nil,"墙上")
            await browser("web-middle-caret","area","我要去上海",4,nil,"我要去上")
            await browser("web-selection","area","上尾巴",1,3,"上")
            await browser("web-other-field-same-caret","plain","下",1,nil,"下")
            await browser("web-contenteditable","rich","上",1,nil,"上")
            await browser("web-rich-middle","rich","我要去上海",4,nil,"我要去上")
            await browser("web-rich-selection","rich","上尾巴",1,3,"上")
            // Normal HTML collapses this newline to a visible space. Compare
            // the rendered editable text, not its different DOM textContent.
            await browser("web-rich-multiline-emoji","rich","🙂第一行\n上",7,nil,"🙂第一行 上")
        }
        let output:[String:Any] = ["results":rows,"warmup":warmup,"matched":rows.filter { $0["result"] as? String == "MATCH" }.count,"count":rows.count]
        try? JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:outputReport,options:.atomic)
        if let previous { (window.firstResponder as? NSView)?.inputContext?.selectedKeyboardInputSource = previous }
        window.orderOut(nil)
        if rows.allSatisfy({ $0["result"] as? String == "MATCH" }) { exit(0) }
        exit(rows.contains(where: { $0["result"] as? String == "MISMATCH" }) ? 1 : 77)
    }
}
setbuf(stdout,nil)
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { ContextHostProbe() }; app.delegate = delegate; app.run()
