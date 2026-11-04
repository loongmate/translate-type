import AppKit
import Carbon
import ApplicationServices

// Own host application only. Sends flagsChanged to its NSTextInputContext,
// which reaches the installed IME across processes; never posts global keys.
// Also checks the menu bar's accessibility description when permitted. This
// does not capture menu-bar pixels or replace a physical keyboard input test.
@MainActor final class ModeIconProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let text = NSTextView()
    private var previous: String?
    private var report = ""
    private var menuChecks = 0
    private var indicatorChecks = 0
    private let chinese = "com.translatetype.inputmethod.TranslateType.Hans"
    private func log(_ message:String) { report += message + "\n" }
    private func finish(_ message:String) {
        log(message)
        if let previous { text.inputContext?.selectedKeyboardInputSource = previous }
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
                try await wait(0.3)
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
                try await wait(0.2)
                guard checkMode(chinese,icon:"InputMenuIcon-v6.pdf",asciiMode:true) else { return }
                guard shift(true) else { return }; try await wait(0.08); guard shift(false) else { return }
                try await wait(0.2)
                guard checkMode(chinese,icon:"InputMenuIcon-v6.pdf") else { return }
                log("MENU BAR ACCESSIBILITY: native \(menuChecks)/3, language indicator \(indicatorChecks)/3; pixels not captured")
                finish("MODE ICON METADATA PASSED: 单一输入源，附加状态图标 中 → 英 → 中 (input text and menu-bar pixels not checked)")
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
    private func checkMode(_ mode:String,icon:String,asciiMode:Bool = false) -> Bool {
        guard hasFocus else { finish("FAIL: 验证中窗口失焦（active=\(NSApp.isActive), key=\(window.isKeyWindow), responder=\(window.firstResponder === text)）"); return false }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard property(kTISPropertyInputSourceID) == mode,
              let pointer = TISGetInputSourceProperty(source,kTISPropertyIconImageURL),
              (Unmanaged<CFURL>.fromOpaque(pointer).takeUnretainedValue() as URL).lastPathComponent == icon else {
            finish("FAIL: 系统当前模式或图标未更新为 \(mode) / \(icon)"); return false
        }
        log("PASS: \(mode) / \(icon)")
        let sources = TISCreateInputSourceList(nil,false).takeRetainedValue() as! [TISInputSource]
        let entries = sources.filter { source in
            guard let pointer = TISGetInputSourceProperty(source,kTISPropertyInputSourceID),
                  let capable = TISGetInputSourceProperty(source,kTISPropertyInputSourceIsSelectCapable) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            return id.hasPrefix("com.translatetype.inputmethod.TranslateType.") && CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(capable).takeUnretainedValue())
        }
        guard entries.count == 1 else { finish("FAIL: 方寸可选入口有 \(entries.count) 个"); return false }
        log("PASS: 系统只有一个启用且可选的方寸入口")
        return checkMenu(mode) && checkIndicator(asciiMode:asciiMode)
    }
    private func checkIndicator(asciiMode:Bool) -> Bool {
        guard AXIsProcessTrusted() else { log("SKIP: Language indicator accessibility not permitted"); return true }
        guard let ime = NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier == "com.translatetype.inputmethod.TranslateType"}) else {
            finish("FAIL: 输入法进程不可用"); return false
        }
        func attribute(_ element:AXUIElement,_ key:String) -> CFTypeRef? {
            var value:CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
            return value
        }
        let app = AXUIElementCreateApplication(ime.processIdentifier)
        var bars = (attribute(app,kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
            attribute($0,kAXRoleAttribute) as? String == kAXMenuBarRole
        }
        if let extras = attribute(app,kAXExtrasMenuBarAttribute) { bars.append(extras as! AXUIElement) }
        let items = bars.flatMap { attribute($0,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        let labels = items.flatMap { element in
            [kAXDescriptionAttribute,kAXTitleAttribute].compactMap { attribute(element,$0) as? String }
        }
        let expected = "方寸语言状态 · \(asciiMode ? "英文" : "中文")"
        guard labels.contains(expected) else {
            finish("FAIL: 状态图标预期 \(expected)，实际 \(labels)"); return false
        }
        indicatorChecks += 1
        log("PASS: language indicator = \(expected)")
        return true
    }
    private func checkMenu(_ mode:String) -> Bool {
        guard AXIsProcessTrusted() else { log("SKIP: Menu-bar accessibility not permitted"); return true }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.TextInputMenuAgent" }) else {
            finish("FAIL: Input menu agent unavailable"); return false
        }
        func attribute(_ element:AXUIElement,_ key:String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
            return value
        }
        let application = AXUIElementCreateApplication(agent.processIdentifier)
        let menuBars = (attribute(application,kAXChildrenAttribute) as? [AXUIElement] ?? []).filter {
            attribute($0,kAXRoleAttribute) as? String == kAXMenuBarRole
        }
        let descriptions = menuBars.flatMap { attribute($0,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
            .compactMap { attribute($0,kAXDescriptionAttribute) as? String }
        let expected = "方寸输入法"
        guard descriptions.contains(expected) else {
            finish("FAIL: Menu-bar description expected \(expected), got \(descriptions)"); return false
        }
        menuChecks += 1; log("PASS: menu-bar description = \(expected)"); return true
    }
    private func shift(_ down:Bool) -> Bool {
        guard hasFocus, let context = text.inputContext else { finish("FAIL: 验证中窗口失焦"); return false }
        let event = NSEvent.keyEvent(with:.flagsChanged,location:.zero,modifierFlags:down ? [.shift] : [],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:56)!
        let handled = context.handleEvent(event)
        log("SHIFT \(down ? "down" : "up"): handled=\(handled)")
        // The actual TIS mode/icon, not this synchronous return value, is the
        // assertion: the input method's reply can arrive asynchronously.
        return true
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = MainActor.assumeIsolated { ModeIconProbe() }; app.delegate = delegate; app.run()
