import AppKit
import Carbon
import Darwin

@MainActor protocol InstallerSystem {
    var currentID:String { get }
    func prepareUpdate(previousID:String) throws
    func stop(at url:URL?) async throws
    func register(at url:URL,payload:URL) async throws
    func enable(at url:URL,previousID:String) throws
    func launch(at url:URL) async throws
    func restore(at url:URL?,previousID:String) async throws
    func select() throws
}

@MainActor
final class InstallerService {
    enum Outcome { case ready, needsLogin(String) }
    private let system:InstallerSystem
    private let locations:InstallTransaction.Locations
    private let validator:(URL,URL)throws->Void
    private let retryDelay:UInt64
    init(system:InstallerSystem? = nil,locations:InstallTransaction.Locations = .currentUser,
         retryDelay:UInt64 = 300_000_000,validator:((URL,URL)throws->Void)? = nil) {
        self.system = system ?? MacInstallerSystem(); self.locations = locations; self.retryDelay = retryDelay
        self.validator = validator ?? { url,installer in try Self.verify(url,team:Self.team(at:installer)) }
    }

    nonisolated static func command(_ executable:String,_ arguments:[String]) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath:executable); task.arguments = arguments
        task.standardOutput = output; task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding:data,as:UTF8.self)
        guard task.terminationStatus == 0 else {
            throw InstallFailure(message:"\(URL(fileURLWithPath:executable).lastPathComponent) 检查失败：\(text.trimmingCharacters(in:.whitespacesAndNewlines))")
        }
        return text
    }
    nonisolated static func verify(_ url:URL,team:String?) throws {
        _ = try command("/usr/bin/codesign",["--verify","--deep","--strict",url.path])
        let details = try command("/usr/bin/codesign",["--display","--verbose=4",url.path])
        let actual = details.split(separator:"\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        guard (team == nil && actual == "not set") || (team != nil && actual == team) else {
            throw InstallFailure(message:"安装包与应用的签名团队不一致，请重新下载官方安装包。")
        }
    }
    nonisolated static func team(at url:URL) throws -> String? {
        let details = try command("/usr/bin/codesign",["--display","--verbose=4",url.path])
        let value = details.split(separator:"\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        return value == "not set" ? nil : value
    }
    func install(payload:URL,installer:URL,progress:(String)->Void) async throws -> Outcome {
        guard getuid() != 0 else { throw InstallFailure(message:"请以当前登录用户运行安装器，无需 sudo 或管理员权限。") }
        let previousID = system.currentID
        let locations = self.locations, validator = self.validator
        let transaction = try await Task.detached { () -> InstallTransaction in
            let transaction = try InstallTransaction(locations:locations)
            try transaction.stage(payload:payload) { try validator($0,installer) }
            return transaction
        }.value
        progress("正在更新应用，请稍候…")
        try system.prepareUpdate(previousID:previousID)
        var filesReplaced = false
        do {
            try await system.stop(at:transaction.previous)
            try await Task.detached { try transaction.replace() }.value
            filesReplaced = true
            try await system.register(at:transaction.destination,payload:payload)
            progress("正在添加到系统输入法…")
            var pending: Error?
            for attempt in 0..<10 {
                do { try system.enable(at:transaction.destination,previousID:previousID); pending = nil; break }
                catch {
                    pending = error
                    if (error as? InputSourceStatus.RegistrationError)?.requiresRelogin != true { throw error }
                    if attempt < 9 { try await Task.sleep(nanoseconds:retryDelay) }
                }
            }
            if let pending {
                // A new input method may only be discovered at the next login.
                // An update keeps the working prior installation instead.
                if transaction.previous != nil { throw pending }
                try await system.launch(at:transaction.destination)
                return .needsLogin(pending.localizedDescription)
            }
            try await system.launch(at:transaction.destination)
            if InputSourceStatus.isOurMode(previousID) || InputSourceStatus.isLegacy(previousID) { try? system.select() }
            return .ready
        } catch {
            do {
                if filesReplaced { try await system.stop(at:transaction.destination) }
                try await Task.detached { try transaction.rollback() }.value
                try await system.restore(at:transaction.previous,previousID:previousID)
            } catch { throw InstallFailure(message:"安装未完成，自动恢复也遇到问题：\(error.localizedDescription)") }
            throw InstallFailure(message:"安装未完成\(transaction.previous == nil ? "" : "，已恢复原应用")：\(error.localizedDescription)")
        }
    }
    func select() throws { try system.select() }
}

@MainActor final class MacInstallerSystem: InstallerSystem {
    private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    var currentID:String { InputSourceStatus.currentID }
    func prepareUpdate(previousID:String) throws {
        if InputSourceStatus.isOurMode(previousID) || InputSourceStatus.isLegacy(previousID) {
            let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            guard TISSelectInputSource(fallback) == noErr else { throw InstallFailure(message:"暂时无法切换到备用键盘，旧应用未改动。请先切换到 ABC 再试。") }
        }
    }
    func register(at url:URL,payload:URL) async throws {
        let registrar = lsregister
        _ = try? await Task.detached { try InstallerService.command(registrar,["-u",payload.path]) }.value
        _ = try await Task.detached { try InstallerService.command(registrar,["-f",url.path]) }.value
    }
    func enable(at url:URL,previousID:String) throws {
        try InputSourceStatus.enable(at:url,replacingCurrentID:previousID)
    }
    func restore(at url:URL?,previousID:String) async throws {
        if let url {
            let registrar = lsregister
            _ = try await Task.detached { try InstallerService.command(registrar,["-f",url.path]) }.value
            try InputSourceStatus.enable(at:url)
            try await launch(at:url)
        } else {
            // A failed fresh install must not leave a selectable missing app.
            for id in [InputSourceStatus.modeID,InputSourceStatus.bundleID] {
                if let source = InputSourceStatus.sources().first(where:{InputSourceStatus.identifier($0) == id}) {
                    _ = TISDisableInputSource(source)
                }
            }
        }
        let restoreID = InputSourceStatus.isLegacy(previousID) ? InputSourceStatus.modeID : previousID
        if let source = InputSourceStatus.sources(includeDisabled:false).first(where:{InputSourceStatus.identifier($0) == restoreID}) {
            _ = TISSelectInputSource(source)
        }
    }
    func stop(at url:URL?) async throws {
        guard let url else { return }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
                && ($0.bundleIdentifier == InputSourceStatus.bundleID || InputSourceStatus.legacyBundleIDs.contains($0.bundleIdentifier ?? ""))
        }
        for application in applications { _ = application.terminate() }
        for _ in 0..<30 {
            if applications.allSatisfy({$0.isTerminated}) { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        for application in applications where !application.isTerminated { _ = application.forceTerminate() }
        for _ in 0..<20 {
            if applications.allSatisfy({$0.isTerminated}) { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw InstallFailure(message:"旧版方寸尚未退出，应用未替换。请保存文字并退出方寸后重试。")
    }
    func launch(at url:URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let _:NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([URL(string:"fangcun://settings")!],withApplicationAt:url,configuration:config) { app,error in
                if let app { continuation.resume(returning:app) }
                else { continuation.resume(throwing:error ?? InstallFailure(message:"无法打开已安装的方寸输入法。")) }
            }
        }
    }
    func select() throws {
        guard let source = InputSourceStatus.sources(includeDisabled:false).first(where:{ InputSourceStatus.identifier($0) == InputSourceStatus.modeID }),
              TISSelectInputSource(source) == noErr else {
            throw InstallFailure(message:"方寸已安装，请在系统输入菜单选择「方寸输入法」；若仍不可选，请重新登录。")
        }
    }
}
