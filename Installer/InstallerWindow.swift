import AppKit

@MainActor
final class InstallerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window:NSWindow!
    private let status = NSTextField(wrappingLabelWithString:"自动安装到当前账户并添加到系统输入法。\n保留现有配置、词库、API Key 和临时编辑器恢复稿。\n\n更新前，请先保存方寸中尚未提交的文字。")
    private let primary = NSButton(title:"安装方寸输入法",target:nil,action:nil)
    private let secondary = NSButton(title:"取消",target:nil,action:nil)
    private let spinner = NSProgressIndicator()
    private var installing = false
    private var complete = false
    private let service:InstallerService
    private let payloadOverride:URL?
    private let installerOverride:URL?
    init(service:InstallerService? = nil,payload:URL? = nil,installer:URL? = nil) {
        self.service = service ?? InstallerService(); payloadOverride = payload; installerOverride = installer
        super.init()
    }

    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = NSImage(named:NSImage.Name("AppIcon")) { NSApp.applicationIconImage = icon }
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:365),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "安装方寸输入法"; window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.appearance = NSAppearance(named:.aqua)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:28),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-28),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-24)])
        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 14
        let icon = NSImageView(image:NSApp.applicationIconImage); icon.widthAnchor.constraint(equalToConstant:60).isActive = true; icon.heightAnchor.constraint(equalToConstant:60).isActive = true
        header.addArrangedSubview(icon)
        let heading = NSStackView(); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 5
        let title = NSTextField(labelWithString:"方寸输入法"); title.font = .systemFont(ofSize:24,weight:.semibold)
        let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""
        let detail = NSTextField(labelWithString:"\(version) · build \(build) · 当前账户安装"); detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize:12)
        heading.addArrangedSubview(title); heading.addArrangedSubview(detail); header.addArrangedSubview(heading); root.addArrangedSubview(header)
        status.font = .systemFont(ofSize:13); status.setContentHuggingPriority(.defaultLow,for:.vertical)
        root.addArrangedSubview(status); status.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.vertical); root.addArrangedSubview(spacer)
        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 10
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false; actions.addArrangedSubview(spinner)
        let flexible = NSView(); flexible.setContentHuggingPriority(.defaultLow,for:.horizontal); actions.addArrangedSubview(flexible)
        secondary.target = self; secondary.action = #selector(close); secondary.bezelStyle = .rounded; secondary.keyEquivalent = "\u{1b}"; actions.addArrangedSubview(secondary)
        primary.target = self; primary.action = #selector(install); primary.bezelStyle = .rounded; primary.keyEquivalent = "\r"; actions.addArrangedSubview(primary)
        root.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true
        let menu = NSMenu(), app = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle:"退出安装器",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        app.submenu = submenu; menu.addItem(app); NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if let index = CommandLine.arguments.firstIndex(of:"--capture"), CommandLine.arguments.count > index+1 {
            let path = CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in
                let view = window.contentView!; view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                if let image = NSImage(data:view.dataWithPDF(inside:view.bounds)),
                   let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width*2),pixelsHigh:Int(view.bounds.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
                   let context = NSGraphicsContext(bitmapImageRep:bitmap) {
                    bitmap.size = view.bounds.size
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                    context.cgContext.scaleBy(x:2,y:2); NSColor.windowBackgroundColor.setFill(); view.bounds.fill()
                    image.draw(in:view.bounds,from:.zero,operation:.sourceOver,fraction:1)
                    NSGraphicsContext.restoreGraphicsState()
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply { installing ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { !installing }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !installing }
    @objc private func close() { if !installing { NSApp.terminate(nil) } }
    @objc private func install() {
        guard !installing else { return }
        if complete {
            do { try service.select(); NSApp.terminate(nil) }
            catch { status.stringValue = error.localizedDescription }
            return
        }
        guard let payload = payloadOverride ?? Bundle.main.resourceURL?.appendingPathComponent("FangCun.app") else { return }
        installing = true; primary.isEnabled = false; secondary.isEnabled = false; spinner.startAnimation(nil)
        status.stringValue = "正在验证并准备安装文件…"
        Task { @MainActor in
            defer { installing = false; spinner.stopAnimation(nil); secondary.isEnabled = true; secondary.title = "关闭" }
            do {
                let outcome = try await service.install(payload:payload,installer:installerOverride ?? Bundle.main.bundleURL) { [weak self] message in self?.status.stringValue = message }
                switch outcome {
                case .ready:
                    status.stringValue = "安装完成，方寸已添加到系统输入法。\n\n点击「开始使用」切换到方寸，或稍后从系统输入菜单选择「方寸输入法」。设置窗口已打开，可以配置 AI 和拼音方案。"
                    complete = true; primary.title = "开始使用"; primary.isEnabled = true
                case .needsLogin:
                    status.stringValue = "应用已安装，macOS 尚未识别新的输入法。\n\n请保存工作，退出登录后重新登录，再在系统输入菜单选择方寸。若仍未出现，请打开方寸设置，点击「添加到系统输入法」。"
                    primary.title = "需要重新登录"; primary.isEnabled = false
                }
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            } catch {
                status.stringValue = error.localizedDescription
                primary.title = "重试安装"; primary.isEnabled = true
            }
        }
    }
}
