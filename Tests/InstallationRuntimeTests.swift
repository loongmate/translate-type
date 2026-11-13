import AppKit

@main struct InstallationRuntimeTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--server") {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { InstallationRuntime.shared.start() }
            app.run(); return
        }
        let url = URL(fileURLWithPath:CommandLine.arguments[1]), plist = url.appendingPathComponent("Contents/Info.plist")
        let original = try Data(contentsOf:plist)
        let process = Process(); process.executableURL = url.appendingPathComponent("Contents/MacOS/RuntimeFixture")
        process.arguments = ["--server"]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { try? original.write(to:plist); if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var checks = 0
        func check(_ value:Bool,_ message:String) { if !value { print("FAIL:",message); exit(1) }; checks += 1; print("PASS:",message) }
        try await InstallationRuntime.verify(at:url,pid:process.processIdentifier,attempts:100,delay:20_000_000)
        check(true,"跨进程等待应用初始化后才确认就绪")
        do {
            try await InstallationRuntime.verify(at:url,pid:process.processIdentifier+500_000,attempts:3,delay:20_000_000)
            check(false,"其他 PID 不能冒充新版服务")
        } catch { check(true,"拒绝其他 PID 的就绪结果") }
        for key in ["CFBundleVersion","CFBundleIdentifier","CFBundleExecutable"] {
            var info = try PropertyListSerialization.propertyList(from:original,format:nil) as! [String:Any]
            info[key] = "unmatched"
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:plist)
            do {
                try await InstallationRuntime.verify(at:url,pid:process.processIdentifier,attempts:3,delay:20_000_000)
                check(false,"错误版本、标识或路径不能通过")
            } catch { check(true,"拒绝不匹配的 "+key) }
            try original.write(to:plist)
        }
        async let first:Void = InstallationRuntime.verify(at:url,pid:process.processIdentifier,attempts:100,delay:20_000_000)
        async let second:Void = InstallationRuntime.verify(at:url,pid:process.processIdentifier,attempts:100,delay:20_000_000)
        _ = try await (first,second)
        check(true,"并行检查各自匹配随机请求，不混用旧响应")
        process.terminate(); process.waitUntilExit()
        do {
            try await InstallationRuntime.verify(at:url,pid:process.processIdentifier,attempts:3,delay:20_000_000)
            check(false,"退出的进程不能通过就绪检查")
        } catch { check(true,"进程退出后不会复用先前的就绪结果") }
        print("Runtime readiness checks: \(checks)")
    }
}
