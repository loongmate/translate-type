import AppKit

// Shared, appearance-aware chrome for the two native writing windows.
@MainActor
enum WorkspaceStyle {
    static func color(_ light:UInt32,_ dark:UInt32) -> NSColor {
        NSColor(name:nil) { appearance in
            let value = appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed:CGFloat((value >> 16) & 255)/255,green:CGFloat((value >> 8) & 255)/255,blue:CGFloat(value & 255)/255,alpha:1)
        }
    }
    static let surface = color(0xffffff,0x2c2933)
    static let soft = color(0xfaf9fc,0x29262f)
    static let sidebar = color(0xf7f6f9,0x26232c)
    static let ink = color(0x2d2935,0xe0dbe9)
    static let muted = color(0x807b8c,0xafa6ba)
    static let subtle = color(0xa09aaa,0x91879e)
    static let line = color(0xeeecf2,0x3a3443)
    static let accent = color(0x7960bb,0xb09bd8)
    static let tint = color(0xeee9f7,0x3b324c)
    static let green = color(0x6f927c,0x91b59b)
    static let themeChanged = Notification.Name("FangCunWorkspaceThemeChanged")
    static var appearance: NSAppearance? {
        switch UserDefaults.standard.string(forKey:"WorkspaceAppearance") {
        case "dark":return NSAppearance(named:.darkAqua)
        case "light":return NSAppearance(named:.aqua)
        default:return nil
        }
    }
    static func toggleAppearance(for window:NSWindow) {
        let dark = window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua
        UserDefaults.standard.set(dark ? "light" : "dark",forKey:"WorkspaceAppearance")
        NotificationCenter.default.post(name:themeChanged,object:nil)
    }
    static func label(_ text:String,size:CGFloat = 12,weight:NSFont.Weight = .regular,color:NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString:text)
        label.font = .systemFont(ofSize:size,weight:weight); label.textColor = color ?? muted
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func row(spacing:CGFloat = 8) -> NSStackView {
        let view = NSStackView(); view.orientation = .horizontal; view.alignment = .centerY; view.spacing = spacing
        return view
    }
    static func column(spacing:CGFloat = 0) -> NSStackView {
        let view = NSStackView(); view.orientation = .vertical; view.alignment = .leading; view.spacing = spacing
        return view
    }
    static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow,for:.horizontal)
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); return view
    }
    static func pin(_ view:NSView,to parent:NSView,insets:NSEdgeInsets = NSEdgeInsetsZero) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:insets.left),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-insets.right),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:insets.top),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-insets.bottom)])
    }
    static func fillWidth(_ view:NSView,in stack:NSStackView,inset:CGFloat = 0) {
        stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-inset).isActive = true
    }
    static func symbol(_ name:String) -> NSImage? { NSImage(systemSymbolName:name,accessibilityDescription:nil) }
}

@MainActor
final class WorkspaceSurface: NSView {
    var onAppearanceChange: (() -> Void)?
    var fill: NSColor { didSet { needsDisplay = true } }
    var stroke: NSColor?
    var radius: CGFloat
    init(_ fill:NSColor? = nil,stroke:NSColor? = nil,radius:CGFloat = 0) {
        self.fill = fill ?? WorkspaceStyle.surface; self.stroke = stroke; self.radius = radius; super.init(frame:.zero)
        wantsLayer = true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; onAppearanceChange?() }
    override func draw(_ dirtyRect:NSRect) {
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:radius,yRadius:radius)
        fill.setFill(); path.fill()
        if let stroke { stroke.setStroke(); path.lineWidth = 1; path.stroke() }
    }
}

@MainActor
final class WorkspaceButton: NSButton {
    enum Kind { case quiet, soft, primary }
    var kind: Kind = .quiet { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    convenience init(_ title:String,symbol:String? = nil,target:AnyObject?,action:Selector?,kind:Kind = .quiet) {
        self.init(frame:.zero); self.title = title; self.target = target; self.action = action; self.kind = kind
        isBordered = false; bezelStyle = .inline; font = .systemFont(ofSize:12)
        if let symbol { image = WorkspaceStyle.symbol(symbol); imagePosition = title.isEmpty ? .imageOnly : .imageLeading; imageScaling = .scaleProportionallyDown }
        heightAnchor.constraint(equalToConstant:30).isActive = true
        if title.isEmpty { widthAnchor.constraint(equalToConstant:30).isActive = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.mouseEnteredAndExited,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event:NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var intrinsicContentSize: NSSize { let size = super.intrinsicContentSize; return NSSize(width:max(title.isEmpty ? 30 : 46,size.width+18),height:30) }
    override func draw(_ dirtyRect:NSRect) {
        if kind != .quiet || state == .on || hovered {
            let fill = kind == .primary ? WorkspaceStyle.accent : WorkspaceStyle.tint
            fill.withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:6,yRadius:6).fill()
        }
        let tint: NSColor = kind == .primary ? (effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? NSColor(srgbRed:0.16,green:0.12,blue:0.21,alpha:1) : .white) : state == .on || kind == .soft ? WorkspaceStyle.accent : WorkspaceStyle.muted
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key:Any] = [.font:font ?? NSFont.systemFont(ofSize:12),.foregroundColor:tint.withAlphaComponent(isEnabled ? 1 : 0.45),.paragraphStyle:paragraph]
        let titleSize = (title as NSString).size(withAttributes:attributes)
        let iconWidth:CGFloat = image == nil ? 0 : 14, gap:CGFloat = image == nil || title.isEmpty ? 0 : 6
        let total = min(bounds.width-16,titleSize.width+iconWidth+gap)
        let x = alignment == .left ? 9 : max(8,(bounds.width-total)/2)
        if let image {
            let colored = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[tint])) ?? image
            colored.draw(in:NSRect(x:x,y:(bounds.height-14)/2,width:14,height:14),from:.zero,operation:.sourceOver,fraction:isEnabled ? 1 : 0.45,respectFlipped:true,hints:nil)
        }
        if !title.isEmpty { (title as NSString).draw(in:NSRect(x:x+iconWidth+gap,y:(bounds.height-titleSize.height)/2,width:max(0,bounds.width-x-iconWidth-gap-8),height:titleSize.height),withAttributes:attributes) }
        if window?.firstResponder === self { WorkspaceStyle.accent.withAlphaComponent(0.6).setStroke(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6).stroke() }
    }
}

@MainActor
final class WorkspaceFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class WorkspaceLineNumbers: NSRulerView {
    override var isFlipped: Bool { true }
    private var starts = [0]
    private var previous = ""
    init(scrollView:NSScrollView,textView:NSTextView) {
        super.init(scrollView:scrollView,orientation:.verticalRuler)
        clientView = textView; ruleThickness = 44
    }
    required init(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ text:String) {
        if text != previous {
            previous = text; starts = [0]
            for (offset,unit) in text.utf16.enumerated() where unit == 10 { starts.append(offset+1) }
        }
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func drawHashMarksAndLabels(in rect:NSRect) {
        WorkspaceStyle.soft.setFill(); bounds.fill()
        guard let text = clientView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer, let clip = scrollView?.contentView else { return }
        let offset = text.textContainerOrigin
        let visible = layout.glyphRange(forBoundingRect:clip.bounds.offsetBy(dx:-offset.x,dy:-offset.y),in:container)
        let characters = layout.characterRange(forGlyphRange:visible,actualGlyphRange:nil)
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:WorkspaceStyle.subtle]
        // Binary search the first visible logical line; wrapped visual lines do not get duplicate numbers.
        var low = 0, high = starts.count
        while low < high { let mid = (low+high)/2; if starts[mid] <= characters.location { low = mid+1 } else { high = mid } }
        for index in max(0,low-1)..<starts.count {
            let position = starts[index]
            if position > NSMaxRange(characters) && index > max(0,low-1) { break }
            let y:CGFloat
            if position < text.string.utf16.count {
                let glyph = layout.glyphIndexForCharacter(at:position)
                y = layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil).minY+offset.y-clip.bounds.minY
            } else { y = layout.extraLineFragmentRect.minY+offset.y-clip.bounds.minY }
            let value = String(index+1) as NSString, size = value.size(withAttributes:attributes)
            value.draw(at:NSPoint(x:bounds.width-size.width-12,y:y+3),withAttributes:attributes)
        }
    }
}

@MainActor
enum WorkspaceSyntax {
    static func apply(to view:NSTextView,format:ScratchpadFormat) {
        guard let storage = view.textStorage else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 7
        let base: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:14,weight:.regular),.foregroundColor:WorkspaceStyle.ink,.paragraphStyle:paragraph]
        storage.beginEditing(); storage.setAttributes(base,range:NSRange(location:0,length:storage.length))
        let range = NSRange(location:0,length:min(storage.length,200_000)), text = view.string
        func tint(_ pattern:String,_ color:NSColor,_ font:NSFont? = nil) {
            guard let regex = try? NSRegularExpression(pattern:pattern,options:.anchorsMatchLines) else { return }
            for match in regex.matches(in:text,range:range) {
                storage.addAttribute(.foregroundColor,value:color,range:match.range)
                if let font { storage.addAttribute(.font,value:font,range:match.range) }
            }
        }
        switch format {
        case .markdown:
            tint("^ {0,3}#{1,6} .*",WorkspaceStyle.accent,.monospacedSystemFont(ofSize:14,weight:.semibold))
            tint("^ {0,3}>.*",WorkspaceStyle.muted)
            tint("^\\s*[-*+] (?:\\[[ xX]\\])?|\\*\\*[^*\\n]+\\*\\*|`[^`\\n]+`",WorkspaceStyle.accent)
        case .json: tint("\"(?:[^\"\\\\]|\\\\.)*\"\\s*:",WorkspaceStyle.accent)
        case .html: tint("</?[a-zA-Z][^>]*>",WorkspaceStyle.accent)
        default:break
        }
        storage.endEditing(); view.typingAttributes = base
    }
}
