import AppKit
import CoreText

@MainActor
final class InputLanguageIndicator: NSObject {
    let item: NSStatusItem
    private let language = NSMenuItem(title:"中文输入 · Shift 切换",action:nil,keyEquivalent:"")
    private let chineseIcon: NSImage
    private let englishIcon: NSImage
    private let onAskAI: () -> Void
    private let onScratchpad: () -> Void

    init(onAskAI:@escaping () -> Void,onScratchpad:@escaping () -> Void = {}) {
        self.onAskAI = onAskAI
        self.onScratchpad = onScratchpad
        chineseIcon = Self.icon(glyph:"中")
        englishIcon = Self.icon(glyph:"英")
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "FangCunLanguageIndicator"
        item.button?.setAccessibilityIdentifier("fangcun-language-indicator")
        let menu = NSMenu()
        language.isEnabled = false
        menu.addItem(language)
        menu.addItem(.separator())
        let ask = NSMenuItem(title:"问问 AI…",action:#selector(askAI),keyEquivalent:"")
        ask.target = self
        menu.addItem(ask)
        let editor = NSMenuItem(title:"临时编辑器…",action:#selector(openScratchpad),keyEquivalent:"")
        editor.target = self; menu.addItem(editor)
        item.menu = menu
        update(asciiMode:false,isSelected:false)
    }

    func update(asciiMode:Bool,isSelected:Bool) {
        let name = asciiMode ? "英文" : "中文"
        item.button?.image = asciiMode ? englishIcon : chineseIcon
        item.button?.toolTip = "方寸输入法 · \(name) · 轻按 Shift 切换"
        item.button?.setAccessibilityLabel("方寸语言状态 · \(name)")
        language.title = "方寸输入法 · \(asciiMode ? "英文直输" : "中文输入") · Shift 切换"
        item.isVisible = isSelected
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
    @objc private func askAI() { onAskAI() }
    @objc private func openScratchpad() { onScratchpad() }

    private static func icon(glyph:String) -> NSImage {
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString,100,nil)
        var character = glyph.utf16.first!, value:CGGlyph = 0
        let available = CTFontGetGlyphsForCharacters(font,&character,&value,1)
        let path = available ? CTFontCreatePathForGlyph(font,value,nil) : nil
        let image = NSImage(size:NSSize(width:18,height:18),flipped:false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            let tile = CGPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),cornerWidth:4,cornerHeight:4,transform:nil)
            context.setFillColor(CGColor(red:0.47,green:0.34,blue:0.76,alpha:1))
            context.addPath(tile); context.fillPath()
            context.setStrokeColor(CGColor(gray:1,alpha:0.4)); context.setLineWidth(0.5)
            context.addPath(tile); context.strokePath()
            if let path {
                let box = path.boundingBoxOfPath
                let target = CGRect(x:3.2,y:4,width:11.6,height:11.4)
                let scale = min(target.width/box.width,target.height/box.height)
                var transform = CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:target.midX-box.midX*scale,ty:target.midY-box.midY*scale)
                context.setFillColor(CGColor(gray:1,alpha:1))
                context.addPath(path.copy(using:&transform)!); context.fillPath()
            } else {
                let text = NSAttributedString(string:glyph,attributes:[.font:NSFont.boldSystemFont(ofSize:13),.foregroundColor:NSColor.white])
                let size = text.size()
                text.draw(at:NSPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2))
            }
            // A small measuring corner echoes 方寸 without replacing the language glyph.
            context.setStrokeColor(CGColor(gray:1,alpha:0.8)); context.setLineWidth(1)
            context.move(to:CGPoint(x:12.8,y:2.5)); context.addLine(to:CGPoint(x:15.4,y:2.5))
            context.addLine(to:CGPoint(x:15.4,y:5.1)); context.strokePath()
            return true
        }
        // Preserve the brand purple instead of allowing macOS to tint it monochrome.
        image.isTemplate = false
        return image
    }
}
