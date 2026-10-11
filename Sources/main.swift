import AppKit
import InputMethodKit
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if let url = Bundle.main.url(forResource:"AppIcon",withExtension:"icns"), let icon = NSImage(contentsOf:url) { NSApp.applicationIconImage = icon }
            // Explicit local verification only: fixed public sample texts,
            // never read a user's draft, clipboard or surrounding document.
            if let index = CommandLine.arguments.firstIndex(of:"--ai-actions-probe"), CommandLine.arguments.count > index+1 {
                let report = URL(fileURLWithPath:CommandLine.arguments[index+1])
                Task { @MainActor in
                    var results: [[String:Any]] = []
                    do {
                        let config = ConfigurationStore.shared.model
                        let key = try SecureKeyStore.read(endpoint:config.endpoint)
                        let samples = [
                            ("german",AIAction.presets[1].instruction(configuration:config),"这周六下午三点见。"),
                            ("ask","你是文字助手，直接回答问题，不输出思考过程。","请用中文列出三个轻松的周末活动，每项一行。")
                        ]
                        for (name,instruction,input) in samples {
                            let started = Date()
                            let output = try await TranslationClient().generate(messages:[AIMessage(role:"system",content:instruction),AIMessage(role:"user",content:input)],configuration:config,apiKey:key)
                            results.append(["action":name,"success":true,"seconds":Date().timeIntervalSince(started),"hasReasoning":output.hasReasoning,"output":output.text])
                        }
                    } catch { results.append(["success":false,"error":error.localizedDescription]) }
                    try? JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:report,options:.atomic)
                    NSApp.terminate(nil)
                }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of:"--translation-probe"), CommandLine.arguments.count > index+1 {
                let report = URL(fileURLWithPath:CommandLine.arguments[index+1])
                Task { @MainActor in
                    let started = Date()
                    var result: [String:Any]
                    do {
                        let config = ConfigurationStore.shared.model
                        let key = try SecureKeyStore.read(endpoint:config.endpoint)
                        let translated = try await TranslationClient().perform("周末去海边走走吧",configuration:config,apiKey:key)
                        result = ["success":true,"seconds":Date().timeIntervalSince(started),"hasReasoning":translated.hasReasoning,"translation":translated.text]
                    } catch { result = ["success":false,"error":error.localizedDescription] }
                    try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:report,options:.atomic)
                    NSApp.terminate(nil)
                }
                return
            }
            if let index = CommandLine.arguments.firstIndex(of:"--capture-settings"), CommandLine.arguments.count > index+1 {
                SettingsWindow.shared.show()
                let path = CommandLine.arguments[index+1]
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    do { try SettingsWindow.shared.capture(to:URL(fileURLWithPath:path)) }
                    catch { NSLog("设置预览失败：%@",error.localizedDescription) }
                    NSApp.terminate(nil)
                }
                return
            }
            guard let resources = Bundle.main.resourceURL else { throw AppError.message("缺少拼音资源。") }
            let user = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TranslateType/Rime")
            try PinyinEngine.initialize(resources:resources,user:user)
            guard let connection = Bundle.main.object(forInfoDictionaryKey:"InputMethodConnectionName") as? String,
                  let bundleID = Bundle.main.bundleIdentifier else { throw AppError.message("缺少输入法注册信息。") }
            server = IMKServer(name:connection,bundleIdentifier:bundleID)
            if server == nil { throw AppError.message("无法启动系统输入法服务。") }
            NSLog("TranslateType input method server ready")
            AppPresence.shared.start()
            if CommandLine.arguments.contains("--settings") { SettingsWindow.shared.show() }
            if CommandLine.arguments.contains("--enable-input-source") { SettingsWindow.shared.enableInputSource() }
        } catch {
            let alert = NSAlert(); alert.messageText = "方寸输入法启动失败"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { SettingsWindow.shared.show(); return true }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
