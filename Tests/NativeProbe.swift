import AppKit
import Carbon

// Only inject keyboard events into this test application's own process.
// NSEvent.keyEvent/postEvent is not an end-to-end IMK test: synthetic text can
// bypass the system input method. Never report that fallback as a real result.
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let text = NSTextView()
    private var original: TISInputSource?
    private let sourceID = "com.translatetype.inputmethod.TranslateType.Hans"

    func finish(_ code: Int32, _ message: String) -> Never {
        if let original { _ = TISSelectInputSource(original) }
        if let i = CommandLine.arguments.firstIndex(of:"--report"), CommandLine.arguments.count > i+1 {
            try? (message + "\n").write(toFile:CommandLine.arguments[i+1],atomically:true,encoding:.utf8)
        }
        print(message); fflush(stdout); exit(code)
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        guard CGPreflightPostEventAccess() else {
            finish(77,"SKIP: macOS 未授权测试程序投递键盘事件；未执行系统级按键测试。")
        }
        original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:310),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "方寸输入法 · 本机输入验证"
        text.font = .systemFont(ofSize:23); text.isRichText = false
        text.textContainerInset = NSSize(width:25,height:30)
        text.frame = window.contentView!.bounds; text.autoresizingMask = [.width,.height]
        window.contentView!.addSubview(text); window.center()
        activate(attempt:0)
    }
    private func activate(attempt:Int) {
        guard attempt < 20 else { finish(1,"FAIL: 测试窗口未获得焦点，未执行按键测试。") }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        NSRunningApplication.current.activate(options:[.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            guard NSApp.isActive && self.window.isKeyWindow else { self.activate(attempt:attempt+1); return }
            let sources = TISCreateInputSourceList(nil,false).takeRetainedValue() as! [TISInputSource]
            guard let source = sources.first(where: { item in
                guard let p = TISGetInputSourceProperty(item,kTISPropertyInputSourceID) else { return false }
                return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String == self.sourceID
            }) else { self.finish(1,"FAIL: 方寸输入法输入源尚未启用") }
            guard TISSelectInputSource(source) == noErr else { self.finish(1,"FAIL: 无法选中方寸输入法") }
            self.text.inputContext?.activate()
            self.text.inputContext?.selectedKeyboardInputSource = self.sourceID
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { self.typeNext(0) }
        }
    }
    private let keys: [CGKeyCode] = [45,34,4,0,31,49] // nihao + Space
    private func key(_ code:CGKeyCode) {
        guard NSApp.isActive && window.isKeyWindow else { finish(1,"FAIL: 测试中焦点变化，停止投递按键。") }
        for down in [true,false] {
            CGEvent(keyboardEventSource:CGEventSource(stateID:.privateState),virtualKey:code,keyDown:down)?.postToPid(getpid())
        }
    }
    private func typeNext(_ index:Int) {
        guard index < keys.count else {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                guard self.text.string == "你好" else { self.finish(1,"FAIL: 中文候选结果不符合预期：\(self.text.string)") }
                // Translation mode keeps the selected Chinese as a draft.
                if self.text.hasMarkedText() { self.key(36) }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                    let passed = self.text.string == "你好" && !self.text.hasMarkedText()
                    self.finish(passed ? 0 : 1,passed ? "NATIVE IMK INTEGRATION PASSED: 你好已上屏" : "FAIL: 中文尚未确认上屏")
                }
            }
            return
        }
        key(keys[index])
        DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { self.typeNext(index+1) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = ProbeDelegate()
app.delegate = delegate
app.run()
