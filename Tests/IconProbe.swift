import AppKit
import Carbon
_ = NSApplication.shared
let sources = TISCreateInputSourceList(nil,true).takeRetainedValue() as! [TISInputSource]
let prefix = "com.translatetype.inputmethod.TranslateType"
let selectable = sources.filter { source in
    guard let pointer = TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else { return false }
    let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    func flag(_ key:CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source,key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
    return id.hasPrefix(prefix) && flag(kTISPropertyInputSourceIsEnabled) && flag(kTISPropertyInputSourceIsSelectCapable)
}
precondition(selectable.count == 1,"Only one FangCun input source may be enabled and selectable")
var found = 0
for source in sources {
    guard let pointer = TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else { continue }
    let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    guard id.hasPrefix(prefix) else { continue }
    if id == prefix + ".English" {
        if let enabled = TISGetInputSourceProperty(source,kTISPropertyInputSourceIsEnabled) {
            precondition(!CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue()),"The retired English entry must be disabled")
        }
        continue
    }
    guard let imagePointer = TISGetInputSourceProperty(source,kTISPropertyIconImageURL) else { fatalError("System icon missing") }
    let url = Unmanaged<CFURL>.fromOpaque(imagePointer).takeUnretainedValue() as URL
    if id == prefix + ".Hans" {
        let installed = url.deletingLastPathComponent().deletingLastPathComponent()
        let data = try! Data(contentsOf:installed.appendingPathComponent("Info.plist"))
        let info = try! PropertyListSerialization.propertyList(from:data,format:nil) as! [String:Any]
        let modes = info["ComponentInputModeDict"] as! [String:Any]
        let list = modes["tsInputModeListKey"] as! [String:[String:Any]]
        precondition(Array(list.keys) == [id],"The installed bundle must declare exactly one native mode")
        let mode = list[id]!
        precondition(mode["tsInputModeIsVisibleKey"] as? Bool == true,"The icon mode must be visible in system UI")
        precondition((modes["tsVisibleInputModeOrderedArrayKey"] as! [String]) == [id],"The system UI must contain exactly one mode")
        print("PASS: installed mode is visible in system UI:",id)
    }
    precondition(url.lastPathComponent == "InputMenuIcon-v6.pdf","System must load the single entry's vector icon")
    guard let image = NSImage(contentsOf:url), image.isValid, image.size == NSSize(width:16,height:16) else { fatalError("System image cannot load") }
    guard let namePointer = TISGetInputSourceProperty(source,kTISPropertyLocalizedName) else { fatalError("Name missing") }
    let name = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
    precondition(name == "方寸输入法","System name must match installed product")
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:160,pixelsHigh:160,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size = NSSize(width:16,height:16)
    let context = NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSColor.white.setFill(); NSRect(x:0,y:0,width:16,height:16).fill()
    image.draw(in:NSRect(x:0,y:0,width:16,height:16))
    context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
    var dark = 0
    for y in 0..<160 { for x in 0..<160 {
        let color = rep.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        if color.redComponent < 0.3 { dark += 1 }
    }}
    let coverage = Double(dark) / 25600
    precondition(coverage > 0.3 && coverage < 0.9,"Rendered icon must contain a visible glyph, not a blank or solid tile")
    try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:".build/system-menu-icon.png"))
    print("PASS:",name,id,"native icon:",url.lastPathComponent,"coverage:",coverage)
    found += 1
}
precondition(found == 2,"The stable input method and its single Hans mode must be registered")
print("PASS: exactly one enabled, selectable FangCun input source; retired English entry absent or disabled")
