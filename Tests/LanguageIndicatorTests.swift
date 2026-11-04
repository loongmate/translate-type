import AppKit
import Carbon

@main struct LanguageIndicatorTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        func enabledSources() -> Set<String> {
            Set(InputSourceStatus.sources(includeDisabled:false).map { InputSourceStatus.identifier($0) })
        }
        let sources = enabledSources()
        let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var askCount = 0, editorCount = 0
        let indicator = InputLanguageIndicator(onAskAI:{ askCount += 1 },onScratchpad:{ editorCount += 1 })
        defer { indicator.remove() }
        let item = indicator.item
        precondition(!item.isVisible,"启动时不应出现未选中输入法的状态图标")
        indicator.update(asciiMode:false,isSelected:true)
        let chinese = item.button!.image!
        precondition(item.isVisible && !chinese.isTemplate && chinese.size == NSSize(width:18,height:18))
        precondition(item.button?.accessibilityLabel() == "方寸语言状态 · 中文")
        precondition(item.menu?.items.first?.title == "方寸输入法 · 中文输入 · Shift 切换")
        let ask = item.menu!.items.first { $0.title == "问问 AI…" }!
        precondition(NSApp.sendAction(ask.action!,to:ask.target,from:ask) && askCount == 1,"菜单中的问问 AI 必须接通打开动作")
        let next = item.menu!.items[item.menu!.items.firstIndex(of:ask)!+1]
        precondition(next.title == "临时编辑器…" && NSApp.sendAction(next.action!,to:next.target,from:next) && editorCount == 1,"临时编辑器入口位于问问 AI 下方且回调独立")
        indicator.update(asciiMode:true,isSelected:true)
        let english = item.button!.image!
        precondition(indicator.item === item && item.isVisible && !english.isTemplate)
        precondition(chinese.tiffRepresentation != english.tiffRepresentation,"中英文必须使用不同的实际图像")
        precondition(item.button?.accessibilityLabel() == "方寸语言状态 · 英文")
        precondition(item.menu?.items.first?.title == "方寸输入法 · 英文直输 · Shift 切换")
        indicator.update(asciiMode:false,isSelected:true)
        precondition(item.button?.image === chinese,"切回中文应恢复中字图像")
        indicator.update(asciiMode:true,isSelected:false)
        precondition(!item.isVisible,"切到其他输入法后必须隐藏附加图标")
        precondition(enabledSources() == sources,"状态图标不能增加或修改系统输入源")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontApp,"更新状态不能抢输入焦点")
        let preview = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:480,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context = NSGraphicsContext(bitmapImageRep:preview)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(x:0,y:100,width:480,height:100).fill()
        NSColor(calibratedWhite:0.12,alpha:1).setFill(); NSRect(x:0,y:0,width:480,height:100).fill()
        for y:CGFloat in [18,118] {
            for (index,image) in [chinese,english,chinese].enumerated() {
                image.draw(in:NSRect(x:CGFloat(index)*160+48,y:y,width:64,height:64))
            }
        }
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        let purple = preview.colorAt(x:55,y:145)!.usingColorSpace(.deviceRGB)!
        precondition(purple.blueComponent > purple.redComponent && purple.redComponent > purple.greenComponent,"图标必须保留品牌紫色")
        try! preview.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/language-indicator-preview.png"))
        print("PASS: 同一个紫色状态图标 中 → 英 → 中；外部输入法时隐藏；图像、菜单、辅助功能状态一致；不改变输入源或焦点")
    }
}
