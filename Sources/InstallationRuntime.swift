import AppKit

/// Metadata-only readiness exchange. Started after Rime and IMKServer are ready;
/// it never reads text, configuration, credentials or the clipboard.
@MainActor final class InstallationRuntime: NSObject {
    static let shared = InstallationRuntime()
    private static let request = Notification.Name("com.translatetype.inputmethod.runtime-request")
    private static let reply = Notification.Name("com.translatetype.inputmethod.runtime-reply")
    private var started = false
    @MainActor private final class Response { var ready = false }
    private struct Unavailable: LocalizedError {
        var errorDescription:String? { "新版进程已启动，但未能确认输入服务就绪。" }
    }
    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(receive(_:)),name:Self.request,object:nil)
    }
    @objc nonisolated private func receive(_ notice:Notification) {
        guard let token = notice.userInfo?["token"] as? String, token.count == 36,
              let pid = notice.userInfo?["pid"] as? Int32, pid == getpid() else { return }
        Task { @MainActor in
            guard let id = Bundle.main.bundleIdentifier,
                  let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String,
                  let executable = Bundle.main.executableURL else { return }
            DistributedNotificationCenter.default().postNotificationName(Self.reply,object:nil,userInfo:[
                "token":token,"pid":getpid(),"bundleID":id,"build":build,
                "executable":executable.standardizedFileURL.resolvingSymlinksInPath().path
            ],deliverImmediately:true)
        }
    }
    static func verify(at url:URL,pid:pid_t,attempts:Int = 300,delay:UInt64 = 100_000_000) async throws {
        let data = try Data(contentsOf:url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              let id = info["CFBundleIdentifier"] as? String,
              let build = info["CFBundleVersion"] as? String,
              let binary = info["CFBundleExecutable"] as? String else { throw Unavailable() }
        let executable = url.appendingPathComponent("Contents/MacOS/"+binary).standardizedFileURL.resolvingSymlinksInPath().path
        let token = UUID().uuidString, response = Response(), center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName:reply,object:nil,queue:.main) { notice in
            MainActor.assumeIsolated {
                guard let reply = notice.userInfo,
                      reply["token"] as? String == token, reply["pid"] as? Int32 == pid,
                      reply["bundleID"] as? String == id, reply["build"] as? String == build,
                      reply["executable"] as? String == executable else { return }
                response.ready = true
            }
        }
        defer { center.removeObserver(observer) }
        for _ in 0..<attempts {
            center.postNotificationName(request,object:nil,userInfo:["token":token,"pid":pid],deliverImmediately:true)
            try await Task.sleep(nanoseconds:delay)
            if response.ready { return }
        }
        throw Unavailable()
    }
}
