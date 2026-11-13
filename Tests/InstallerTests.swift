import AppKit

/// Observe the installed path from a separate thread, across real filesystem operations.
final class InstalledPathObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var samples = 0
    private var missing = 0
    private let done = DispatchSemaphore(value:0)
    init(_ url:URL) {
        let ready = DispatchSemaphore(value:0)
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            ready.signal()
            while true {
                lock.lock(); let finish = stopped; lock.unlock()
                if finish { break }
                var info = stat()
                let result = lstat(url.path,&info)
                lock.lock(); samples += 1; if result != 0 { missing += 1 }; lock.unlock()
            }
            done.signal()
        }
        ready.wait()
    }
    func finish() -> (samples:Int,missing:Int) {
        lock.lock(); stopped = true; lock.unlock(); done.wait()
        return (samples,missing)
    }
}

@MainActor final class FakeInstallerSystem: InstallerSystem {
    var currentID = "com.apple.keylayout.ABC"
    var events:[String] = []
    var registerFailure = false
    var prepareFailure = false
    var launchFailure = false
    var stopFailure = false
    var hadRunningProcesses = false
    var launchShowsSettings:[Bool] = []
    var restoreRelaunches:[Bool] = []
    var selectFailure = false
    var pendingAttempts = 0
    var enableCount = 0
    func prepareUpdate(previousID:String) async throws {
        events.append("prepare")
        if prepareFailure { throw InstallFailure(message:"模拟切换备用键盘未确认") }
    }
    func stop(at url:URL?) async throws -> Bool {
        events.append("stop")
        if stopFailure { throw InstallFailure(message:"模拟旧进程无法退出") }
        return hadRunningProcesses
    }
    func register(at url:URL,payload:URL) async throws {
        events.append("register")
        if registerFailure { throw InstallFailure(message:"模拟注册失败") }
    }
    func enable(at url:URL) throws {
        events.append("enable"); enableCount += 1
        if enableCount <= pendingAttempts { throw InputSourceStatus.RegistrationError(message:"模拟新会话尚未发现",requiresRelogin:true) }
    }
    func launch(at url:URL,showSettings:Bool) async throws {
        events.append("launch"); launchShowsSettings.append(showSettings)
        if launchFailure { throw InstallFailure(message:"模拟启动失败") }
    }
    func restore(at url:URL?,previousID:String,relaunch:Bool) async throws { events.append("restore"); restoreRelaunches.append(relaunch) }
    func select() throws {
        events.append("select")
        if selectFailure { throw InstallFailure(message:"模拟输入源未能恢复") }
        currentID = InputSourceStatus.modeID
    }
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
            let notarized = CommandLine.arguments.last == "--notarized"
            for upgrade in notarized ? [false,true] : [false] {
                let transaction = try InstallTransaction(locations:f.locations)
                try transaction.stage(payload:payload) { try InstallerService.verify($0,team:team) }
                check(f.fm.fileExists(atPath:transaction.staging.path),"真实签名 payload 在临时安装目录复制后仍通过严格验证")
                if notarized {
                    try transaction.replace()
                    _ = try InstallerService.command("/usr/bin/xcrun",["stapler","validate",transaction.destination.path])
                    let assessment = try InstallerService.command("/usr/sbin/spctl",["--assess","--type","execute","--verbose=4",transaction.destination.path])
                    check(assessment.contains("Notarized Developer ID"),upgrade ? "原子覆盖升级后签名、公证票据及 Gatekeeper 验证仍有效" : "首次安装复制后签名、公证票据及 Gatekeeper 验证仍有效")
                    if upgrade {
                        try transaction.rollback()
                        try InstallerService.verify(transaction.destination,team:team)
                        _ = try InstallerService.command("/usr/bin/xcrun",["stapler","validate",transaction.destination.path])
                        check(true,"真实签名应用原子回滚后仍通过严格验证及公证票据检查")
                    }
                }
            }
            return
        }
        do {
            let f = try InstallerFixture()
            try f.writeApp(at:f.destination,marker:"old")
            let transaction = try InstallTransaction(locations:f.locations)
            let observer = InstalledPathObserver(f.destination)
            for _ in 0..<100 {
                if f.fm.fileExists(atPath:transaction.staging.path) { try f.fm.removeItem(at:transaction.staging) }
                try transaction.stage(payload:f.payload,verify:{_ in})
                try transaction.replace()
                try transaction.rollback()
            }
            let result = observer.finish()
            print("Installed path observations:",result.samples,"missing:",result.missing)
            if result.samples == 0 || result.missing != 0 {
                print("FAIL: 升级和回滚期间已安装路径不能消失"); exit(1)
            }
            check(true,"独立线程观测 100 次真实替换及回滚，安装路径始终存在")
        }
        do {
            let f = try InstallerFixture()
            try f.writeApp(at:f.destination,marker:"old")
            let transaction = try InstallTransaction(locations:f.locations)
            try transaction.stage(payload:f.payload,verify:{_ in})
            let oldInode = try f.fm.attributesOfItem(atPath:f.destination.path)[.systemFileNumber] as! NSNumber
            let newInode = try f.fm.attributesOfItem(atPath:transaction.staging.path)[.systemFileNumber] as! NSNumber
            try transaction.replace()
            check(try f.fm.attributesOfItem(atPath:f.destination.path)[.systemFileNumber] as? NSNumber == newInode && f.marker(transaction.staging) == "old", "交换后新版目录原子就位，旧版目录保留供回滚")
            try transaction.rollback()
            check(try f.fm.attributesOfItem(atPath:f.destination.path)[.systemFileNumber] as? NSNumber == oldInode && f.marker(f.destination) == "old", "回滚恢复原目录对象，不删除并重新复制注册路径")
        }
        do {
            let f = try InstallerFixture()
            let transaction = try InstallTransaction(locations:f.locations)
            try transaction.stage(payload:f.payload,verify:{_ in})
            try f.writeApp(at:f.destination,marker:"unexpected")
            do { try transaction.replace(); check(false,"首次安装不能覆盖检查后出现的文件") }
            catch { check(try f.marker(f.destination) == "unexpected", "首次安装以排他重命名拒绝覆盖新出现的目标") }
            try transaction.rollback()
            check(try f.marker(f.destination) == "unexpected", "未提交安装的回滚也不删除新出现的目标")
        }
        do {
            let f = try InstallerFixture()
            try f.writeApp(at:f.destination,marker:"old")
            let transaction = try InstallTransaction(locations:f.locations)
            try transaction.stage(payload:f.payload,verify:{_ in})
            try Data("block backup directory".utf8).write(to:f.locations.support.appendingPathComponent("Backups"))
            do { try transaction.replace(); check(false,"备份未完成不能交换应用") }
            catch { check(try f.marker(f.destination) == "old", "旧版备份失败时原安装目录保持完整") }
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem(); s.prepareFailure = true
            try f.writeApp(at:f.destination,marker:"old")
            do { _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}; check(false,"备用输入源未确认不能继续升级") }
            catch { check(try f.marker(f.destination) == "old" && s.restoreRelaunches == [false] && !s.events.contains("stop"), "切换失败只恢复输入源，不退出或重启旧进程") }
        }
        for failure in ["launch","select"] {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            s.currentID = InputSourceStatus.modeID
            s.launchFailure = failure == "launch"; s.selectFailure = failure == "select"
            try f.writeApp(at:f.destination,marker:"old")
            do { _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}; check(false,"交接未完成不能报告成功") }
            catch { check(try f.marker(f.destination) == "old" && s.restoreRelaunches == [true], "新版\(failure)失败后交换回旧版，并恢复原服务") }
        }
        func process(_ pid:pid_t,_ path:String,_ id:String = InputSourceStatus.bundleID) -> InstallerProcess {
            let url = URL(fileURLWithPath:path)
            return InstallerProcess(pid:pid,bundleID:id,bundleURL:url,executableURL:url.appendingPathComponent("Contents/MacOS/TranslateType"))
        }
        do {
            var live = [process(101,"/Downloads/TranslateType.app",InputSourceStatus.legacyBundleIDs[0]),process(102,"/Library/Input Methods/FangCun.app"),
                        process(103,"/Applications/Installer.app","com.translatetype.installer.FangCun"),
                        process(104,"/Applications/Other.app","org.example.other")]
            var requests:[pid_t] = []
            let processes = InstallerProcesses(inventory:{live},requestStop:{ pid in
                requests.append(pid); live.removeAll {$0.pid == pid}; return true
            },delay:0)
            _ = try await MacInstallerSystem(processes:processes).stop(at:nil)
            check(Set(requests) == [101,102],"首次安装也退出下载目录与安装目录里的全部方寸进程")
            check(Set(live.map(\.pid)) == [103,104],"退出方寸副本不影响安装器及其他产品")
        }
        do {
            var reads = 0
            var live = [process(201,"/Downloads/Old.app")]
            let processes = InstallerProcesses(inventory:{
                reads += 1
                if reads == 2 { live.append(process(202,"/Volumes/Old/FangCun.app")) }
                return live
            },requestStop:{ pid in live.removeAll {$0.pid == pid}; return true },delay:0)
            let stopped = try await processes.stopAll()
            check(stopped == [201,202] && live.isEmpty,"退出期间重新出现的旧副本也被重新枚举并停止")
        }
        do {
            let live = [process(301,"/Downloads/Old.app")]
            var requests = 0
            let processes = InstallerProcesses(inventory:{live},requestStop:{ _ in requests += 1; return false },delay:0)
            do { _ = try await processes.stopAll(); check(false,"拒绝正常退出时必须停止升级") }
            catch { check(requests == 1 && live.count == 1,"拒绝正常退出时保留旧进程，不强制杀进程") }
        }
        do {
            let processes = InstallerProcesses(inventory:{[process(401,"/Downloads/Old.app")]},requestStop:{_ in true},delay:0)
            do { _ = try await processes.stopAll(); check(false,"旧副本仍存活不能继续安装") }
            catch { check(true,"正常退出超时后停止更新，不强制结束旧进程") }
        }
        do {
            let destination = URL(fileURLWithPath:"/Users/test/Library/Input Methods/FangCun.app")
            let installed = process(501,destination.path)
            var live = [installed]
            let processes = InstallerProcesses(inventory:{live},requestStop:{_ in true},delay:0)
            try await processes.verifyLaunch(at:destination,pid:501,stopped:[500])
            check(true,"仅新 PID 且位于准确安装路径的单一进程通过启动验证")
            live.append(process(502,"/Downloads/Old.app"))
            do { try await processes.verifyLaunch(at:destination,pid:501,stopped:[]); check(false,"两个进程不能报告安装成功") }
            catch { check(true,"新旧两份进程同时运行时拒绝报告成功") }
            live = [process(501,"/Downloads/Old.app")]
            do { try await processes.verifyLaunch(at:destination,pid:501,stopped:[]); check(false,"其他目录中的旧副本不能冒充已更新") }
            catch { check(true,"启动返回其他目录的副本时拒绝报告成功") }
            live = [installed]
            do { try await processes.verifyLaunch(at:destination,pid:501,stopped:[501]); check(false,"旧 PID 不能冒充新进程") }
            catch { check(true,"即使路径相同也不能复用已要求退出的旧 PID") }
        }
        do {
            let f = try InstallerFixture()
            let foreign = f.root.appendingPathComponent("Other.app")
            try f.writeApp(at:foreign,marker:"foreign",id:"org.example.other")
            var live = [InstallerProcess(pid:601,bundleID:nil,bundleURL:f.payload,executableURL:f.payload.appendingPathComponent("Contents/MacOS/TranslateType")),
                        InstallerProcess(pid:602,bundleID:nil,bundleURL:foreign,executableURL:foreign.appendingPathComponent("Contents/MacOS/TranslateType"))]
            let processes = InstallerProcesses(inventory:{live},requestStop:{ pid in live.removeAll {$0.pid == pid}; return true },delay:0)
            let stopped = try await processes.stopAll()
            check(stopped == [601] && live.map(\.pid) == [602],"系统缺少 bundle ID 时只按已验证的方寸应用元数据退出，不按同名程序误杀其他产品")
        }
        do {
            let destination = URL(fileURLWithPath:"/Users/test/Library/Input Methods/FangCun.app")
            var reads = 0
            let processes = InstallerProcesses(inventory:{
                reads += 1
                if reads == 1 { return [] }
                if reads == 2 { return [InstallerProcess(pid:701,bundleID:InputSourceStatus.bundleID,bundleURL:nil,executableURL:nil)] }
                return [process(701,destination.path)]
            },requestStop:{_ in true},delay:0)
            try await processes.verifyLaunch(at:destination,pid:701,stopped:[])
            check(reads == 3,"等待新进程出现在系统清单并补齐路径后再确认启动成功")
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
        for state in 0..<5 {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            if state == 0 { try f.writeApp(at:f.destination,marker:"old") }
            if state == 1 { s.hadRunningProcesses = true }
            if state == 2 { s.currentID = InputSourceStatus.modeID }
            if state == 3 { s.currentID = InputSourceStatus.retiredEnglishModeID }
            if state == 4 { s.currentID = InputSourceStatus.legacyBundleIDs[0] + ".Hans" }
            let result = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            if case .ready = result { check(true,"覆盖升级启动并恢复输入源，不一律要求注销：\(state)") }
            else { check(false,"升级应尝试正常完成交接") }
            check(s.launchShowsSettings == [false],"升级后台启动已有输入法，不弹设置或强制创建实例：\(state)")
            check(s.events.contains("select") == (state >= 2),"仅恢复升级前已选中的方寸输入源：\(state)")
        }
        do {
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            let legacy = f.locations.inputMethods.appendingPathComponent("方寸输入法.app")
            try f.writeApp(at:legacy,marker:"legacy")
            _ = try await service(f,s).install(payload:f.payload,installer:f.payload) {_ in}
            check(try f.marker(legacy) == "new" && !f.fm.fileExists(atPath:f.destination.path),"升级旧安装名时沿用原路径，只保留一个安装副本")
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
            catch { check(try f.marker(f.destination) == "old" && !s.events.contains("register"),"旧进程无法退出时不替换、不注册")
                check(s.restoreRelaunches == [false],"退出未完成时不额外启动旧进程") }
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
            let f = try InstallerFixture(), s = FakeInstallerSystem()
            try f.writeApp(at:f.destination,marker:"old")
            let (delegate,window,views) = ui(f,s)
            let button = views.compactMap {$0 as? NSButton}.first {$0.title == "安装方寸输入法"}!
            button.performClick(nil)
            try await wait { button.title == "开始使用" }
            check(button.isEnabled && views.compactMap {$0 as? NSTextField}.contains {$0.stringValue.contains("安装完成") && !$0.stringValue.contains("设置窗口已打开")},"覆盖升级界面完成交接后可开始使用，不宣称已打开设置")
            check(s.launchShowsSettings == [false],"覆盖升级后台启动，不强制拉起额外实例")
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
