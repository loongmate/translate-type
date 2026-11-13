import AppKit
import Carbon
import Darwin

@MainActor protocol InstallerSystem {
    var currentID:String { get }
    func prepareUpdate(previousID:String) async throws
    func stop(at url:URL?) async throws -> Bool
    func register(at url:URL,payload:URL) async throws
    func enable(at url:URL) throws
    func launch(at url:URL,showSettings:Bool) async throws
    func restore(at url:URL?,previousID:String,relaunch:Bool) async throws
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
        var filesReplaced = false
        do {
            try await system.prepareUpdate(previousID:previousID)
            let stoppedOldProcess = try await system.stop(at:transaction.previous)
            try await Task.detached { try transaction.replace() }.value
            filesReplaced = true
            try await system.register(at:transaction.destination,payload:payload)
            progress("正在添加到系统输入法…")
            var pending: Error?
            for attempt in 0..<10 {
                do { try system.enable(at:transaction.destination); pending = nil; break }
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
                return .needsLogin(pending.localizedDescription)
            }
            progress("正在启动新版并恢复输入源…")
            let firstInstall = transaction.previous == nil && !stoppedOldProcess && !InputSourceStatus.isOurMode(previousID) && !InputSourceStatus.isLegacy(previousID)
            try await system.launch(at:transaction.destination,showSettings:firstInstall)
            if InputSourceStatus.isOurMode(previousID) || InputSourceStatus.isLegacy(previousID) { try system.select() }
            return .ready
        } catch {
            do {
                if filesReplaced { _ = try await system.stop(at:transaction.destination) }
                try await Task.detached { try transaction.rollback() }.value
                try await system.restore(at:transaction.previous,previousID:previousID,relaunch:filesReplaced)
            } catch { throw InstallFailure(message:"安装未完成，自动恢复也遇到问题：\(error.localizedDescription)") }
            throw InstallFailure(message:"安装未完成\(transaction.previous == nil ? "" : "，已恢复原应用")：\(error.localizedDescription)")
        }
    }
    func select() throws { try system.select() }
}

@MainActor final class MacInstallerSystem: InstallerSystem {
    private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private let processes:InstallerProcesses
    private var stoppedPIDs:Set<pid_t> = []
    init(processes:InstallerProcesses? = nil) { self.processes = processes ?? InstallerProcesses() }
    var currentID:String { InputSourceStatus.currentID }
    func prepareUpdate(previousID:String) async throws {
        if InputSourceStatus.isOurMode(previousID) || InputSourceStatus.isLegacy(previousID) {
            let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
            guard TISSelectInputSource(fallback) == noErr else { throw InstallFailure(message:"暂时无法切换到备用键盘，旧应用未改动。请先切换到 ABC 再试。") }
            let fallbackID = InputSourceStatus.identifier(fallback)
            for _ in 0..<20 {
                if InputSourceStatus.currentID == fallbackID {
                    // Let client deactivation/commit notifications run before
                    // requesting normal termination of the old input method.
                    try await Task.sleep(nanoseconds:200_000_000)
                    return
                }
                try await Task.sleep(nanoseconds:50_000_000)
            }
            throw InstallFailure(message:"未能确认备用键盘已选中，旧应用未改动，请重试。")
        }
    }
    func register(at url:URL,payload:URL) async throws {
        let registrar = lsregister
        _ = try? await Task.detached { try InstallerService.command(registrar,["-u",payload.path]) }.value
        _ = try await Task.detached { try InstallerService.command(registrar,["-f",url.path]) }.value
    }
    func enable(at url:URL) throws {
        // prepareUpdate has already selected an ASCII fallback. Use that
        // current source when retiring legacy modes so migration cannot select
        // FangCun again while old host applications still hold IMK contexts.
        try InputSourceStatus.enable(at:url)
    }
    func restore(at url:URL?,previousID:String,relaunch:Bool) async throws {
        if relaunch, let url {
            let registrar = lsregister
            _ = try await Task.detached { try InstallerService.command(registrar,["-f",url.path]) }.value
            try InputSourceStatus.enable(at:url)
            try await launchProcess(at:url,showSettings:false,requireRuntime:false)
        } else if relaunch {
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
    func stop(at url:URL?) async throws -> Bool {
        // Even a first install may have an older copy running from Downloads
        // or a disk image. Stopping just `url` leaves that copy serving IMK.
        let stopped = try await processes.stopAll()
        stoppedPIDs.formUnion(stopped)
        return !stopped.isEmpty
    }
    func launch(at url:URL,showSettings:Bool) async throws {
        try await launchProcess(at:url,showSettings:showSettings,requireRuntime:true)
    }
    private func launchProcess(at url:URL,showSettings:Bool,requireRuntime:Bool) async throws {
        let running = processes.inputMethods()
        if running.count > 1 || running.contains(where:{ !$0.matchesInstallation(url) || stoppedPIDs.contains($0.pid) }) {
            stoppedPIDs.formUnion(try await processes.stopAll())
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = showSettings
        let launched:NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let completion:@Sendable (NSRunningApplication?,Error?)->Void = { app,error in
                if let app { continuation.resume(returning:app) }
                else { continuation.resume(throwing:error ?? InstallFailure(message:"无法打开已安装的方寸输入法。")) }
            }
            if showSettings {
                NSWorkspace.shared.open([URL(string:"fangcun://settings")!],withApplicationAt:url,configuration:config,completionHandler:completion)
            } else {
                NSWorkspace.shared.openApplication(at:url,configuration:config,completionHandler:completion)
            }
        }
        try await processes.verifyLaunch(at:url,pid:launched.processIdentifier,stopped:stoppedPIDs)
        // A restored older build predates the readiness exchange. It must
        // still be launchable when recovering from a failed upgrade.
        if requireRuntime { try await InstallationRuntime.verify(at:url,pid:launched.processIdentifier) }
    }
    func select() throws {
        guard let source = InputSourceStatus.sources(includeDisabled:false).first(where:{ InputSourceStatus.identifier($0) == InputSourceStatus.modeID }),
              TISSelectInputSource(source) == noErr,
              InputSourceStatus.isOurMode(InputSourceStatus.currentID) else {
            throw InstallFailure(message:"暂未确认方寸已被选中，请从系统输入菜单选择「方寸输入法」。")
        }
    }
}
