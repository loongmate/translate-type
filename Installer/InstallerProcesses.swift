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
    private let requestStop:@MainActor (pid_t)->Bool
    private let delay:UInt64
    init(inventory:@escaping @MainActor ()->[InstallerProcess] = {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
            InstallerProcess(pid:$0.processIdentifier,bundleID:$0.bundleIdentifier,bundleURL:$0.bundleURL,executableURL:$0.executableURL)
        }
    },requestStop:@escaping @MainActor (pid_t)->Bool = { pid in
        guard let app = NSRunningApplication(processIdentifier:pid) else { return true }
        return app.terminate()
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
        var stopped:Set<pid_t> = []
        var quiet = 0
        for _ in 0..<100 {
            let processes = inputMethods()
            if processes.isEmpty {
                quiet += 1
                if quiet == 2 { return stopped }
            } else {
                quiet = 0
                for process in processes {
                    if stopped.insert(process.pid).inserted, !requestStop(process.pid) {
                        throw InstallFailure(message:"方寸暂时无法正常退出，应用未替换。请结束当前输入或关闭方寸设置后重试。")
                    }
                }
            }
            try await Task.sleep(nanoseconds:delay)
        }
        throw InstallFailure(message:"方寸退出超时，应用未替换。请结束当前输入或关闭方寸设置后重试。")
    }
    func verifyLaunch(at url:URL,pid:pid_t,stopped:Set<pid_t>) async throws {
        for _ in 0..<50 {
            let processes = inputMethods()
            if processes.count > 1 {
                throw InstallFailure(message:"检测到多个方寸进程，更新尚未生效。请切换到 ABC 后重试安装。")
            }
            if let process = processes.first {
                guard process.pid == pid, !stopped.contains(pid) else {
                    throw InstallFailure(message:"系统仍在运行其他位置或旧的方寸进程，更新尚未生效。请重试安装。")
                }
                if process.bundleURL != nil && process.executableURL != nil {
                    guard process.matchesInstallation(url) else {
                        throw InstallFailure(message:"系统启动的方寸不在本次安装目录，更新尚未生效。请重试安装。")
                    }
                    return
                }
            }
            try await Task.sleep(nanoseconds:delay)
        }
        throw InstallFailure(message:"未能确认新版方寸进程已启动，请重试安装。")
    }
}
