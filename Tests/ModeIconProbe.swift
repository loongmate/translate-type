import AppKit
import Carbon

// Own host application only. Sends flagsChanged to its NSTextInputContext,
// which reaches the installed IME across processes; never posts global keys.
// This verifies mode/icon synchronization, not physical keyboard text input.
@MainActor final class ModeIconProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let text = NSTextView()
    private var previous: String?
    private var report = ""
    private let chinese = "com.translatetype.inputmethod.TranslateType.Hans"
    private let english = "com.translatetype.inputmethod.TranslateType.English"
    private func log(_ message:String) { report += message + "\n" }
    private func finish(_ message:String) {
        log(message)
        // Invisible modes are not selectable via TIS; restore the parent entry.
        if let previous { text.inputContext?.selectedKeyboardInputSource = previous == english ? chinese : previous }
        if CommandLine.arguments.count > 1 {
            try? report.write(toFile:CommandLine.arguments[1],atomically:true,encoding:.utf8)
        }
        window?.orderOut(nil); NSApp.terminate(nil)
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        previous = property(kTISPropertyInputSourceID)
        window = NSWindow(contentRect:NSRect(x:180,y:220,width:450,height:160),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "方寸 · 中英文图标验证"; window.contentView = text
        window.center(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps:true)
        Task { @MainActor in
            do {
                try await wait(1)
                if !hasFocus {
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                    window.makeFirstResponder(text); try await wait(0.5)
                }
                guard hasFocus, let context = text.inputContext else {
                    finish("SKIP: 验证窗口没有获得焦点（active=\(NSApp.isActive), key=\(window.isKeyWindow), responder=\(window.firstResponder === text)）"); return
                }
                context.selectedKeyboardInputSource = chinese
                context.activate()
                // A just-installed IME may still be establishing its connection.
                try await wait(1.2)
                guard checkMode(chinese,icon:"InputMenuIcon-v6.pdf") else { return }
                guard shift(true) else { return }; try await wait(0.08); guard shift(false) else { return }
                try await wait(0.4)
                guard checkMode(english,icon:"InputMenuEnglish-v1.pdf") else { return }
                guard shift(true) else { return }; try await wait(0.08); guard shift(false) else { return }
                try await wait(0.4)
                guard checkMode(chinese,icon:"InputMenuIcon-v6.pdf") else { return }
                finish("MODE ICON INTEGRATION PASSED: 方 → 英 → 方")
            } catch { finish("FAIL: \(error.localizedDescription)") }
        }
    }
    private var hasFocus: Bool { NSApp.isActive && window.isKeyWindow && window.firstResponder === text }
    private func wait(_ seconds:Double) async throws { try await Task.sleep(nanoseconds:UInt64(seconds * 1_000_000_000)) }
    private func property(_ key:CFString) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source,key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    private func checkMode(_ mode:String,icon:String) -> Bool {
        guard hasFocus else { finish("FAIL: 验证中窗口失焦"); return false }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard property(kTISPropertyInputSourceID) == mode,
              let pointer = TISGetInputSourceProperty(source,kTISPropertyIconImageURL),
              (Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL).lastPathComponent == icon else {
            finish("FAIL: 系统当前模式或图标未更新为 \(mode)"); return false
        }
        log("PASS: \(mode) / \(icon)"); return true
    }
    private func shift(_ down:Bool) -> Bool {
        guard hasFocus, let context = text.inputContext else { finish("FAIL: 验证中窗口失焦"); return false }
        let event = NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:down ? [.shift] : [],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56)!
        _ = context.handleEvent(event)
        // The actual TIS mode/icon, not this synchronous return value, is the
        // assertion: the input method's reply can arrive asynchronously.
        return true
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { ModeIconProbe() }; app.delegate = delegate; app.run()
