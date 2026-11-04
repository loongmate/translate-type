import AppKit

@MainActor final class FakeInstallerSystem: InstallerSystem {
    var currentID = "com.apple.keylayout.ABC"
    var events:[String] = []
    var registerFailure = false
    var launchFailure = false
    var stopFailure = false
    var pendingAttempts = 0
    var enableCount = 0
    func prepareUpdate(previousID:String) throws { events.append("prepare") }
    func stop(at url:URL?) async throws {
        events.append("stop")
        if stopFailure { throw InstallFailure(message:"模拟旧进程无法退出") }
    }
    func register(at url:URL,payload:URL) async throws {
        events.append("register")
        if registerFailure { throw InstallFailure(message:"模拟注册失败") }
    }
    func enable(at url:URL,previousID:String) throws {
        events.append("enable"); enableCount += 1
        if enableCount <= pendingAttempts { throw InputSourceStatus.RegistrationError(message:"模拟新会话尚未发现",requiresRelogin:true) }
    }
    func launch(at url:URL) async throws {
        events.append("launch")
        if launchFailure { throw InstallFailure(message:"模拟启动失败") }
    }
    func restore(at url:URL?,previousID:String) async throws { events.append("restore") }
    func select() throws { events.append("select") }
}

final class InstallerFixture {
    let root:URL
    let payload:URL
    let locations:InstallTransaction.Locations
    let fm = FileManager.default
    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("FangCunInstallerTests-"+UUID().uuidString)
        payload = root.appendingPathComponent("download/FangCun.app")
        locations = InstallTransaction.Locations(inputMethods:root.appendingPathComponent("user/Input Methods"),support:root.appendingPathComponent("user/Installer"),systemInputMethods:root.appendingPathComponent("system/Input Methods"))
        try writeApp(at:payload,marker:"new")
    }
    deinit { try? fm.removeItem(at:root) }
    var destination:URL { locations.inputMethods.appendingPathComponent("FangCun.app") }
    func writeApp(at url:URL,marker:String,id:String = InstallTransaction.bundleID) throws {
        try fm.createDirectory(at:url.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        let info:[String:Any] = ["CFBundleIdentifier":id,"CFBundleExecutable":"TranslateType","CFBundleVersion":"43"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
        let binary = url.appendingPathComponent("Contents/MacOS/TranslateType")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:binary)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:binary.path)
        try Data(marker.utf8).write(to:url.appendingPathComponent("marker"))
    }
    func marker(_ url:URL) throws -> String { try String(contentsOf:url.appendingPathComponent("marker"),encoding:.utf8) }
    var backups:[URL] { (try? fm.contentsOfDirectory(at:locations.support.appendingPathComponent("Backups"),includingPropertiesForKeys:nil)) ?? [] }
    var staging:[URL] { ((try? fm.contentsOfDirectory(at:locations.inputMethods,includingPropertiesForKeys:nil)) ?? []).filter {$0.lastPathComponent.hasSuffix(".installing")} }
}

@main struct InstallerTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil); _ = NSApplication.shared
        var checks = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); checks += 1; print("PASS:",label) }
        func service(_ fixture:InstallerFixture,_ system:FakeInstallerSystem) -> InstallerService {
            InstallerService(system:system,locations:fixture.locations,retryDelay:1,validator:{_,_ in})
        }
        if CommandLine.arguments.count == 3 || CommandLine.arguments.count == 4 {
            let f = try InstallerFixture()
            let payload = URL(fileURLWithPath:CommandLine.arguments[1])
            let installer = URL(fileURLWithPath:CommandLine.arguments[2])
            let team = try InstallerService.team(at:installer)
            let transaction = try InstallTransaction(locations:f.locations)
            try transaction.stage(payload:payload) { try InstallerService.verify($0,team:team) }
            check(f.fm.fileExists(atPath:transaction.staging.path),"真实签名 payload 在临时安装目录复制后仍通过严格验证")
            if CommandLine.arguments.last == "--notarized" {
                try transaction.replace()
                _ = try InstallerService.command("/usr/bin/xcrun",["stapler","validate",transaction.destination.path])
                let assessment = try InstallerService.command("/usr/sbin/spctl",["--assess","--type","execute","--verbose=4",transaction.destination.path])
                check(assessment.contains("Notarized Developer ID"),"通过真实安装复制和重命名后，公证票据与 Gatekeeper 验证仍有效")
            }
            return
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            let result = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            if case .ready = result { check(true,"首次安装返回已启用结果") } else { check(false,"首次安装状态错误") }
            check(try f.marker(f.destination) == "new" && f.backups.isEmpty,"首次安装将真实文件复制到目标目录")
            check(s.events == ["prepare","stop","register","enable","launch"],"验证后按复制、注册、启用、打开的顺序执行")
            check(f.staging.isEmpty,"首次安装不残留 staging")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            try f.writeApp(at:f.destination,marker:"old")
            let userData = f.root.appendingPathComponent("user/preferences.json")
            try Data("saved-key-and-draft".utf8).write(to:userData)
            _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            check(try f.marker(f.destination) == "new" && f.backups.count == 1 && f.marker(f.backups[0]) == "old","升级保留可恢复的旧版快照")
            check(try String(contentsOf:userData) == "saved-key-and-draft","升级不修改用户配置与恢复稿")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            let legacy = f.locations.inputMethods.appendingPathComponent("方寸输入法.app")
            try f.writeApp(at:legacy,marker:"legacy")
            _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            check(!f.fm.fileExists(atPath:legacy.path) && f.fm.fileExists(atPath:f.destination.path),"旧安装名迁移后只保留一个安装副本")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.registerFailure = true
            try f.writeApp(at:f.destination,marker:"old")
            do { _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}; check(false,"注册失败必须报错") }
            catch { check(error.localizedDescription.contains("已恢复原应用"),"注册失败明确提示已恢复旧版") }
            check(try f.marker(f.destination) == "old" && s.events.last == "restore","注册失败自动还原文件并恢复输入源")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.launchFailure = true
            do { _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}; check(false,"启动失败必须报错") }
            catch { check(!f.fm.fileExists(atPath:f.destination.path) && s.events.last == "restore","首次安装启动失败移除新副本并恢复原输入源") }
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.pendingAttempts = 20
            let result = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            if case .needsLogin = result { check(true,"系统未发现输入法时明确返回需要重新登录") } else { check(false,"未发现不能报告成功") }
            check(s.enableCount == 10 && f.fm.fileExists(atPath:f.destination.path),"新安装等待注册传播后保留应用供下次登录发现")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.pendingAttempts = 20
            try f.writeApp(at:f.destination,marker:"old")
            do { _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}; check(false,"更新未通过启用不能报告成功") }
            catch { check(try f.marker(f.destination) == "old","升级无法启用时恢复可用的旧版") }
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.pendingAttempts = 2
            _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            check(s.enableCount == 3,"注册短暂延迟后可正常完成")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.stopFailure = true
            try f.writeApp(at:f.destination,marker:"old")
            do { _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}; check(false,"旧进程未退出必须停止") }
            catch { check(try f.marker(f.destination) == "old" && !s.events.contains("register"),"旧进程无法退出时不替换、不注册") }
        }
        do {
            let f = try InstallerFixture()
            try f.writeApp(at:f.destination,marker:"foreign",id:"org.example.other")
            do { _ = try InstallTransaction(locations:f.locations); check(false,"同名其他产品必须拒绝") }
            catch { check(try f.marker(f.destination) == "foreign","不覆盖同名的其他产品") }
        }
        do {
            let f = try InstallerFixture()
            try f.writeApp(at:f.locations.systemInputMethods.appendingPathComponent("FangCun.app"),marker:"system")
            do { _ = try InstallTransaction(locations:f.locations); check(false,"系统级副本必须提示迁移") }
            catch { check(!f.fm.fileExists(atPath:f.destination.path),"系统级副本存在时阻止生成第二份用户安装") }
        }
        do {
            let f = try InstallerFixture()
            try f.writeApp(at:f.destination,marker:"one")
            let second = f.locations.inputMethods.appendingPathComponent("TranslateType.app")
            try f.writeApp(at:second,marker:"two")
            do { _ = try InstallTransaction(locations:f.locations); check(false,"多个旧副本必须停止") }
            catch { check(try f.marker(f.destination) == "one" && f.marker(second) == "two","多个副本存在时原样保留并拒绝安装") }
        }
        do {
            let f = try InstallerFixture()
            try f.fm.createDirectory(at:f.locations.inputMethods,withIntermediateDirectories:true)
            try f.fm.createSymbolicLink(at:f.destination,withDestinationURL:f.payload)
            do { _ = try InstallTransaction(locations:f.locations); check(false,"符号链接必须停止") }
            catch { check(try f.marker(f.payload) == "new","不沿符号链接替换其他位置的应用") }
        }
        do {
            let f = try InstallerFixture()
            let transaction = try InstallTransaction(locations:f.locations)
            do { _ = try InstallTransaction(locations:f.locations); check(false,"必须阻止并发安装") }
            catch { check(true,"同一账户安装锁阻止并发修改") }
            withExtendedLifetime(transaction) {}
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            let failed = InstallerService(system:s,locations:f.locations,validator:{_,_ in throw InstallFailure(message:"模拟签名无效") })
            do { _ = try await failed.install(payload:f.payload,installer:f.payload) {_ in}; check(false,"无效签名必须拒绝") }
            catch { check(s.events.isEmpty && !f.fm.fileExists(atPath:f.destination.path),"签名无效时不停止进程、不修改现有安装") }
        }
        do {
            let f = try InstallerFixture()
            let transaction = try InstallTransaction(locations:f.locations)
            try f.fm.removeItem(at:f.payload.appendingPathComponent("Contents/MacOS/TranslateType"))
            do { try transaction.stage(payload:f.payload,verify:{_ in}); check(false,"不完整 payload 必须拒绝") }
            catch { check(!f.fm.fileExists(atPath:f.destination.path),"缺少可执行文件时拒绝安装") }
        }
        func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func ui(_ fixture:InstallerFixture,_ system:FakeInstallerSystem) -> (InstallerDelegate,NSWindow,[NSView]) {
            let delegate = InstallerDelegate(service:service(fixture,system),payload:fixture.payload,installer:fixture.payload)
            delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
            let window = NSApp.windows.first {$0.title == "安装方寸输入法" && $0.isVisible}!
            return (delegate,window,descendants(window.contentView!))
        }
        func wait(_ condition:()->Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds:10_000_000)
            }
            throw InstallFailure(message:"安装器界面未及时完成")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            let (delegate,window,views) = ui(f,s)
            let button = views.compactMap {$0 as? NSButton}.first {$0.title == "安装方寸输入法"}!
            button.performClick(nil)
            check(!delegate.windowShouldClose(window),"安装过程中不能关闭窗口中断文件替换")
            try await wait { button.title == "开始使用" }
            check(button.isEnabled && f.fm.fileExists(atPath:f.destination.path),"真实安装按钮完成复制并切换为开始使用")
            check(views.compactMap {$0 as? NSTextField}.contains {$0.stringValue.contains("方寸已添加到系统输入法")},"完成界面明确显示启用结果")
            check(delegate.windowShouldClose(window),"安装完成后可关闭窗口")
            window.close(); withExtendedLifetime(delegate) {}
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.pendingAttempts = 20
            let (delegate,window,views) = ui(f,s)
            let button = views.compactMap {$0 as? NSButton}.first {$0.title == "安装方寸输入法"}!
            button.performClick(nil)
            try await wait { button.title == "需要重新登录" }
            check(!button.isEnabled && views.compactMap {$0 as? NSTextField}.contains {$0.stringValue.contains("退出登录后重新登录")},"需要登录的界面不会显示安装成功或开始使用")
            window.close(); withExtendedLifetime(delegate) {}
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.registerFailure = true
            let (delegate,window,views) = ui(f,s)
            let button = views.compactMap {$0 as? NSButton}.first {$0.title == "安装方寸输入法"}!
            button.performClick(nil)
            try await wait { button.title == "重试安装" }
            check(button.isEnabled && !f.fm.fileExists(atPath:f.destination.path),"安装失败界面允许重试且无残留新应用")
            window.close(); withExtendedLifetime(delegate) {}
        }
        print("Installer checks: \(checks)")
    }
}
