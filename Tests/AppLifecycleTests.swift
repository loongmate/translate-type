import AppKit
import InputMethodKit
import Carbon

@main struct AppLifecycleTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        var checks = 0
        func check(_ condition:Bool,_ message:String) {
            precondition(condition,message); checks += 1; print("PASS:",message)
        }
        var settings:NSWindow? { app.windows.first { $0.title == "方寸输入法 · 设置" } }
        func checkHidden(_ message:String) { check(settings?.isVisible != true,message) }

        delegate.openRequestedSettings(arguments:["TranslateType"])
        checkHidden("后台启动不自动弹设置，也不依赖输入源注册状态")
        for visible in [false,true] {
            check(!delegate.applicationShouldHandleReopen(app,hasVisibleWindows:visible),"普通 reopen 不让 AppKit 自动恢复窗口")
            checkHidden("普通 reopen 不创建或打开设置")
        }
        delegate.application(app,open:[URL(string:"https://example.com")!,URL(string:"fangcun://unknown")!])
        checkHidden("无关链接不打开设置")
        delegate.application(app,open:[URL(string:"fangcun://settings")!])
        check(settings?.isVisible == true,"显式设置链接可以打开正在运行的输入法设置")
        let original = settings!
        original.close()
        delegate.openRequestedSettings(arguments:["TranslateType","-ApplePersistenceIgnoreState","YES"])
        checkHidden("系统启动参数不会被误认成打开设置")
        for _ in 0..<5 {
            _ = delegate.applicationShouldHandleReopen(app,hasVisibleWindows:false)
            NotificationCenter.default.post(name:NSApplication.didBecomeActiveNotification,object:app)
            NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:app)
        }
        checkHidden("关闭设置后反复激活和 reopen 不弹回设置")
        delegate.openRequestedSettings(arguments:["TranslateType","--settings"])
        check(settings === original && original.isVisible,"显式 --settings 保留兼容并复用设置窗口")
        original.close()

        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let user = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunLifecycleTests-"+UUID().uuidString)
        let cache = root.appendingPathComponent(".build/editor-rime-cache")
        try FileManager.default.createDirectory(at:user,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:cache.path) { try FileManager.default.copyItem(at:cache,to:user.appendingPathComponent("build")) }
        try PinyinEngine.initialize(resources:root.appendingPathComponent("Resources"),user:user)
        defer { try? FileManager.default.removeItem(at:user) }
        let server = IMKServer(name:"FangCunLifecycleTests_"+UUID().uuidString,bundleIdentifier:Bundle.main.bundleIdentifier!)!
        let first = TextClient(), second = TextClient()
        let controller = TTInputController(server:server,delegate:nil,client:first)!
        AppPresence.shared.start()
        for client in [first,second,first,second] {
            controller.activateServer(client)
            _ = delegate.applicationShouldHandleReopen(app,hasVisibleWindows:false)
            controller.deactivateServer(client)
        }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),object:nil,userInfo:nil,deliverImmediately:true)
        RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        checkHidden("实际 IMK 客户端切换和输入源通知不打开设置")
        controller.showPreferences(nil)
        check(original.isVisible,"输入法菜单的设置入口仍可主动打开设置")
        original.close()
        delegate.application(app,open:[URL(string:"fangcun://settings")!])
        check(settings === original && original.isVisible,"关闭后仍可通过显式链接重新打开设置")
        original.close()
        print("ALL APP LIFECYCLE TESTS PASSED: \(checks) checks")
    }
}
