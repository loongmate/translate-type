import AppKit

struct InstallerProcess {
    let pid:pid_t
    let bundleID:String?
    let bundleURL:URL?
    let executableURL:URL?

    func matchesInstallation(_ url:URL) -> Bool {
        bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
            && executableURL?.standardizedFileURL.resolvingSymlinksInPath() == url.appendingPathComponent("Contents/MacOS/TranslateType").standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Coordinate all copies of this input method, including copies outside the
/// installation directory. The installer itself has a different bundle ID.
@MainActor final class InstallerProcesses {
    private let inventory:@MainActor ()->[InstallerProcess]
    private let requestStop:@MainActor (pid_t,Bool)->Void
    private let delay:UInt64
    init(inventory:@escaping @MainActor ()->[InstallerProcess] = {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
            InstallerProcess(pid:$0.processIdentifier,bundleID:$0.bundleIdentifier,bundleURL:$0.bundleURL,executableURL:$0.executableURL)
        }
    },requestStop:@escaping @MainActor (pid_t,Bool)->Void = { pid,force in
        guard let app = NSRunningApplication(processIdentifier:pid) else { return }
        if force { _ = app.forceTerminate() } else { _ = app.terminate() }
    },delay:UInt64 = 100_000_000) {
        self.inventory = inventory; self.requestStop = requestStop; self.delay = delay
    }
    func inputMethods() -> [InstallerProcess] {
        inventory().filter { process in
            if let id = process.bundleID {
                return id == InputSourceStatus.bundleID || InputSourceStatus.legacyBundleIDs.contains(id)
            }
            // Launch Services can temporarily omit metadata. Fall back only
            // when both the executable name and on-disk product ID match.
            guard process.executableURL?.lastPathComponent == "TranslateType", let url = process.bundleURL else { return false }
            return InstallTransaction.isOurApplication(at:url)
        }
    }
    func stopAll() async throws -> Set<pid_t> {
        var stopped:Set<pid_t> = [], forced:Set<pid_t> = []
        var quiet = 0
        for attempt in 0..<50 {
            let processes = inputMethods()
            if processes.isEmpty {
                quiet += 1
                if quiet == 2 { return stopped }
            } else {
                quiet = 0
                for process in processes {
                    if stopped.insert(process.pid).inserted { requestStop(process.pid,false) }
                    if attempt >= 30 && forced.insert(process.pid).inserted { requestStop(process.pid,true) }
                }
            }
            try await Task.sleep(nanoseconds:delay)
        }
        throw InstallFailure(message:"仍有方寸进程未退出，应用未替换。请保存文字、切换到 ABC，再退出登录后重试。")
    }
    func verifyLaunch(at url:URL,pid:pid_t,stopped:Set<pid_t>) async throws {
        for _ in 0..<50 {
            let processes = inputMethods()
            if processes.count > 1 {
                throw InstallFailure(message:"检测到多个方寸进程，更新尚未生效。请切换到 ABC，退出登录后重新安装。")
            }
            if let process = processes.first {
                guard process.pid == pid, !stopped.contains(pid) else {
                    throw InstallFailure(message:"系统仍在运行其他位置或旧的方寸进程，更新尚未生效。请退出登录后重新安装。")
                }
                if process.bundleURL != nil && process.executableURL != nil {
                    guard process.matchesInstallation(url) else {
                        throw InstallFailure(message:"系统启动的方寸不在本次安装目录，更新尚未生效。请退出登录后重新安装。")
                    }
                    return
                }
            }
            try await Task.sleep(nanoseconds:delay)
        }
        throw InstallFailure(message:"未能确认新版方寸进程已启动，请退出登录后重新安装。")
    }
}
