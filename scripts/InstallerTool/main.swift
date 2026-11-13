import AppKit

@MainActor final class CommandLineInstallerSystem: InstallerSystem {
    private let system = MacInstallerSystem()
    private let showSettings = ProcessInfo.processInfo.environment["FANGCUN_OPEN_SETTINGS"] != "0"
    var currentID:String { system.currentID }
    func prepareUpdate(previousID:String) async throws { try await system.prepareUpdate(previousID:previousID) }
    func stop(at url:URL?) async throws -> Bool { try await system.stop(at:url) }
    func register(at url:URL,payload:URL) async throws { try await system.register(at:url,payload:payload) }
    func enable(at url:URL) throws { try system.enable(at:url) }
    func launch(at url:URL,showSettings:Bool) async throws { try await system.launch(at:url,showSettings:showSettings && self.showSettings) }
    func restore(at url:URL?,previousID:String,relaunch:Bool) async throws { try await system.restore(at:url,previousID:previousID,relaunch:relaunch) }
    func select() throws { try system.select() }
}

@main struct InstallerTool {
    @MainActor static func main() async {
        setbuf(stdout,nil)
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("用法：scripts/install.sh [--help]\n安装本机构建；与 DMG 共用原子替换、正常退出和失败回滚流程。\nFANGCUN_OPEN_SETTINGS=0 可关闭首次安装时自动打开设置。")
            return
        }
        guard args.count == 1 else { fputs("需要一个本机构建的输入法路径。\n",stderr); exit(64) }
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let payload = URL(fileURLWithPath:args[0])
        do {
            // This development entry point accepts the user's local build as
            // the trust anchor. The distributed DMG uses its signed installer.
            let outcome = try await InstallerService(system:CommandLineInstallerSystem()).install(payload:payload,installer:payload) { print($0) }
            switch outcome {
            case .ready: print("已安装方寸，完成新版进程就绪及输入源检查。请在原应用中验证输入。")
            case .needsLogin(let reason): fputs("应用已安装，但输入源尚未立即可用：\(reason)\n",stderr); exit(2)
            }
        } catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
    }
}
