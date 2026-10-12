import AppKit
import WebKit
import Carbon
import CryptoKit

// Own, disposable AppKit and WebKit fields. Expected text is a fixed fixture;
// the installed IME returns only hashes and ranges through an opt-in probe.
@MainActor final class ContextHostProbe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    static func textView(_ frame:NSRect) -> NSTextView {
        // Explicit TextKit 1 storage avoids TextKit 2's out-of-bounds font
        // update when a fixture replaces text during input-context teardown.
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size:NSSize(width:frame.width,height:.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        return NSTextView(frame:frame,textContainer:container)
    }
    let first = textView(NSRect(x:16,y:235,width:310,height:190))
    let second = textView(NSRect(x:16,y:20,width:310,height:190))
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
        if CommandLine.arguments.contains("--self-check") {
            for text in [first,second] {
                for value in ["", "上", "上海", "🙂第一行\n上", String(repeating:"甲",count:200)] {
                    text.unmarkText(); text.setSelectedRange(NSRange(location:0,length:0)); text.string = value
                    text.setSelectedRange(NSRange(location:value.utf16.count,length:0))
                    text.setMarkedText("hai",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
                    text.unmarkText(); text.setSelectedRange(NSRange(location:0,length:0)); text.string = "上"
                    guard text.string == "上" else { exit(1) }
                }
            }
            print("FIXTURE SELF CHECK PASSED: 10 composition resets, no visible window"); exit(0)
        }
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
    func sample(_ id:String,_ expected:String,establishConnection:Bool = true) async {
        guard NSApp.isActive, window.isKeyWindow, let view = window.firstResponder as? NSView, let context = view.inputContext else {
            rows.append(["case":id,"result":"SKIP","reason":"no-focused-input-context","front":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]); print("SKIP",id,"active",NSApp.isActive,"key",window.isKeyWindow,"responder",String(describing:window.firstResponder)); return
        }
        if previous == nil { previous = context.selectedKeyboardInputSource }
        if establishConnection {
        if context.selectedKeyboardInputSource != "com.translatetype.inputmethod.TranslateType.Hans" {
            context.selectedKeyboardInputSource = "com.translatetype.inputmethod.TranslateType.Hans"
        }
        if NSTextInputContext.current !== context { context.activate() }
        await wait(0.3)
        let event = NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56)!
        _ = context.handleEvent(event)
        await wait(0.2)
        }
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
    // Synthetic NSEvents passed to NSTextInputContext can bypass the input
    // method and insert raw letters. Use the opt-in, owned-host-only entry
    // instead: the full controller runs against the real remote IMK client.
    // This tests cross-process reads/writes, not physical keyboard dispatch.
    func typeFixture(_ text:String) async {
        for c in text {
            guard NSApp.isActive, window.isKeyWindow else { return }
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.fangcun.context-probe.sample"),object:nil,userInfo:["fixtureAction":"continuous-key","key":Int(c.unicodeScalars.first!.value),"bundle":Bundle.main.bundleIdentifier!],deliverImmediately:true)
            await wait(0.10)
        }
    }
    func continuousFixture(_ native:Bool) async {
        guard NSApp.isActive, window.isKeyWindow else { rows.append(["case":"flow-focus","result":"SKIP"]); return }
        // Force a fresh input session, with no old marked text or caret history.
        window.makeFirstResponder(second); await wait(0.2)
        if native { await self.native("flow-native-start",first,"") }
        else { window.makeFirstResponder(web); await browser("flow-web-start","plain","",0,nil,"") }
        await typeFixture("shang ")
        await sample(native ? "flow-native-confirmed" : "flow-web-confirmed","上",establishConnection:false)
        await typeFixture("hai")
        // The diagnostic returns eligibility only; the fixture's text verifies
        // the actual inserted candidate independently after space.
        let id = native ? "flow-native-context-active" : "flow-web-context-active"
        await sample(id,"上",establishConnection:false)
        if let i = rows.indices.last, let observations = rows[i]["observations"] as? [[String:Any]] {
            rows[i]["result"] = observations.allSatisfy { $0["contextActive"] as? Bool == true } ? "MATCH" : "MISMATCH"
        }
        await typeFixture(" ")
        let text:String
        if native { text = first.string }
        else { text = (try? await web.evaluateJavaScript("document.getElementById('plain').value")) as? String ?? "" }
        let result = text == "上海" ? "MATCH" : "MISMATCH"
        rows.append(["case":native ? "flow-native-insert" : "flow-web-insert","result":result]); print(result,"continuous insert")
    }
    func run() async {
        await wait(1)
        for _ in 0..<30 { if loaded { break }; await wait(0.1) }
        // Registration being selectable does not mean a newly installed IMK
        // server has finished starting. Establish the real connection first.
        first.unmarkText(); first.setSelectedRange(NSRange(location:0,length:0))
        first.string = "上"; first.setSelectedRange(NSRange(location:1,length:0))
        for _ in 0..<8 {
            await sample("connection-warmup","上")
            let attempt = rows.removeLast(); warmup.append(attempt)
            if attempt["result"] as? String == "MATCH" { break }
            if attempt["result"] as? String == "SKIP" { break }
        }
        if warmup.last?["result"] as? String != "MATCH" {
            try? JSONSerialization.data(withJSONObject:["results":rows,"warmup":warmup,"matched":0,"count":0],options:[.prettyPrinted,.sortedKeys]).write(to:outputReport,options:.atomic)
            if let previous { first.inputContext?.selectedKeyboardInputSource = previous }
            print("SKIP: host focus or IMK connection unavailable"); exit(77)
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
        if CommandLine.arguments.contains("--continuous") {
            await continuousFixture(true)
            if loaded { await continuousFixture(false) }
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
// Finder / Crash Reporter's Reopen action does not supply our CLI report
// paths. Exit normally instead of indexing missing arguments and crashing.
guard CommandLine.arguments.count >= 3 else {
    print("Run this development fixture with scripts/context-host-test.sh.")
    exit(0)
}
// A failed development fixture must not open Crash Reporter on the user's
// desktop. Keep the exception in the test log and return a failing exit code.
NSSetUncaughtExceptionHandler { exception in
    fputs("FIXTURE EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "")\n",stderr)
    exit(1)
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { ContextHostProbe() }; app.delegate = delegate; app.run()
