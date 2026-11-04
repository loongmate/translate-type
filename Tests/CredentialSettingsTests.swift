import AppKit

@main struct CredentialSettingsTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunKeySettings-"+UUID().uuidString)
        let previous = ConfigurationStore.shared.model
        ConfigurationStore.shared.model = ModelConfiguration(endpoint:"https://example.com/v1",model:"mock-model")
        defer { ConfigurationStore.shared.model = previous; try? FileManager.default.removeItem(at:directory) }
        func descendants(_ view:NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        func form() -> (NSWindow,NSSecureTextField,NSTextField,NSButton) {
            let window = NSApp.windows.first { $0.title == "方寸输入法 · 设置" && $0.isVisible }!
            let tabs = descendants(window.contentView!).first { $0 is NSTabView } as! NSTabView
            tabs.selectTabViewItem(withIdentifier:"AI")
            let views = descendants(window.contentView!)
            let key = views.first { $0.identifier?.rawValue == "api-key" } as! NSSecureTextField
            let endpoint = views.first { $0.identifier?.rawValue == "model-endpoint" } as! NSTextField
            let save = views.first { $0.identifier?.rawValue == "save-model" } as! NSButton
            return (window,key,endpoint,save)
        }
        func changed(_ field:NSTextField,in ui:SettingsWindow) {
            ui.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:field))
        }
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        var firstRead = true
        let slow = APIKeyStore(file:directory.appendingPathComponent("slow/keys.json")) { url in
            precondition(!Thread.isMainThread)
            if firstRead { firstRead = false; entered.signal(); _ = release.wait(timeout:.now()+5) }
            return try Data(contentsOf:url)
        }
        try await APIKeyStore(file:slow.file).save("synthetic-old",endpoint:"https://example.com/v1")
        let initial = try Data(contentsOf:slow.file)
        let ui = SettingsWindow(keyStore:slow)
        ui.show()
        let (window,key,_,save) = form()
        try await wait { signalled(entered) }
        save.performClick(nil)
        check(try Data(contentsOf:slow.file) == initial,"密钥尚未读完时保存不会把旧密钥覆盖为空值")
        key.stringValue = "synthetic-new"; changed(key,in:ui)
        var beat = false; DispatchQueue.main.async { beat = true }
        try await Task.sleep(nanoseconds:30_000_000)
        check(beat && key.stringValue == "synthetic-new","设置页等待密钥时仍可输入并响应主线程事件")
        save.performClick(nil); release.signal()
        try await wait { save.isEnabled }
        check(key.stringValue == "synthetic-new","迟到的旧密钥不会覆盖用户刚输入的新 Key")
        check(try await slow.read(endpoint:"https://example.com/v1") == "synthetic-new","异步保存写入用户确认的新 Key")
        window.close()

        let started2 = DispatchSemaphore(value:0), release2 = DispatchSemaphore(value:0)
        let other = APIKeyStore(file:directory.appendingPathComponent("other/keys.json")) { url in
            started2.signal(); _ = release2.wait(timeout:.now()+5)
            return try Data(contentsOf:url)
        }
        try await APIKeyStore(file:other.file).save("old-service-key",endpoint:"https://example.com/v1")
        let ui2 = SettingsWindow(keyStore:other); ui2.show()
        let (window2,key2,endpoint2,_) = form()
        try await wait { signalled(started2) }
        endpoint2.stringValue = "https://another.example/v1"; changed(endpoint2,in:ui2)
        release2.signal(); try await Task.sleep(nanoseconds:100_000_000)
        check(key2.stringValue.isEmpty,"换服务后迟到的旧 Key 不会填入新服务")
        window2.close()

        var attempts = 0
        let failed = APIKeyStore(file:directory.appendingPathComponent("failed/keys.json")) { url in
            attempts += 1
            if attempts == 1 { throw AppError.message("模拟文件读取失败") }
            return try Data(contentsOf:url)
        }
        try await APIKeyStore(file:failed.file).save("retained",endpoint:"https://example.com/v1")
        let retained = try Data(contentsOf:failed.file)
        let ui3 = SettingsWindow(keyStore:failed); ui3.show()
        let (window3,key3,_,save3) = form()
        let labels = descendants(window3.contentView!).compactMap { $0 as? NSTextField }
        try await wait { labels.contains { $0.stringValue.contains("无法读取本机 API Key 文件") } }
        save3.performClick(nil)
        check(try Data(contentsOf:failed.file) == retained,"文件读取失败后不能误用空字段保存，原记录保留")
        key3.stringValue = "replacement"; changed(key3,in:ui3); save3.performClick(nil)
        try await wait { save3.isEnabled }
        check(try await failed.read(endpoint:"https://example.com/v1") == "replacement","重新粘贴一次后恢复正常保存和读取")
        window3.close()
        print("ALL CREDENTIAL SETTINGS TESTS PASSED")
    }
    @MainActor static func wait(_ condition:()->Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        fatalError("设置异步操作未完成")
    }
    static func signalled(_ value:DispatchSemaphore) -> Bool { value.wait(timeout:.now()) == .success }
    static func check(_ value:Bool,_ label:String) { precondition(value,label); print("PASS:",label) }
}
