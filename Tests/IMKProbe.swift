import AppKit

// A separate, owned host application. Calls only its own NSTextInputContext;
// no global event injection, accessibility control or user-app text access.
@MainActor final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var text: NSTextView!
    var context: NSTextInputContext!
    var previousSource: String?
    func applicationDidFinishLaunching(_ notification:Notification) {
        window = NSWindow(contentRect:NSRect(x:180,y:200,width:480,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "方寸 · 系统连接测试"
        text = NSTextView(frame:NSRect(x:0,y:0,width:480,height:180))
        text.font = .systemFont(ofSize:18)
        text.string = "测试前缀：尾部"; text.setSelectedRange(NSRange(location:5,length:0))
        window.contentView = text
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        window.makeFirstResponder(text)
        context = text.inputContext!
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.runProbe() }
    }
    func runProbe() {
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text); context.activate()
        print("host active/key/responder:",NSApp.isActive,window.isKeyWindow,window.firstResponder === text,"front:",NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")
        guard NSApp.isActive, window.isKeyWindow, NSTextInputContext.current === context else {
            print("SKIP: test window has no system keyboard focus; no input-source change or event sent")
            window.orderOut(nil); NSApp.terminate(nil); return
        }
        previousSource = context.selectedKeyboardInputSource
        context.selectedKeyboardInputSource = "com.translatetype.inputmethod.TranslateType.Hans"
        print("source:",context.selectedKeyboardInputSource ?? "nil", "own-context:",NSTextInputContext.current === context)
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.control,.shift],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        print("open handled:",context.handleEvent(event))
        DispatchQueue.main.asyncAfter(deadline:.now()+3) {
            print("host text intact:",self.text.string == "测试前缀：尾部", "synthetic result:",self.text.string.debugDescription)
            self.context.selectedKeyboardInputSource = self.previousSource
            self.context.deactivate()
            self.window.orderOut(nil)
            NSApp.terminate(nil)
        }
    }
}
setbuf(stdout,nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Probe() }; app.delegate = delegate
app.run()
