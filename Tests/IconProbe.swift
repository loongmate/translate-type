import AppKit
import Carbon
_ = NSApplication.shared
let sources = TISCreateInputSourceList(nil,true).takeRetainedValue() as! [TISInputSource]
let prefix = "com.translatetype.inputmethod.TranslateType"
var found = 0
for source in sources {
    guard let pointer = TISGetInputSourceProperty(source,kTISPropertyInputSourceID) else { continue }
    let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    guard id.hasPrefix(prefix) else { continue }
    guard let imagePointer = TISGetInputSourceProperty(source,kTISPropertyIconImageURL) else { fatalError("System icon missing") }
    let url = Unmanaged<CFURL>.fromOpaque(imagePointer).takeUnretainedValue() as URL
    let english = id == prefix + ".English"
    if id == prefix + ".Hans" || english {
        // The icon URL alone is insufficient: a hidden mode may change in TIS
        // while the system menu keeps the previous visible mode's icon.
        let installed = url.deletingLastPathComponent().deletingLastPathComponent()
        let data = try! Data(contentsOf:installed.appendingPathComponent("Info.plist"))
        let info = try! PropertyListSerialization.propertyList(from:data,format:nil) as! [String:Any]
        let modes = info["ComponentInputModeDict"] as! [String:Any]
        let mode = (modes["tsInputModeListKey"] as! [String:[String:Any]])[id]!
        precondition(mode["tsInputModeIsVisibleKey"] as? Bool == true,"The icon mode must be visible in system UI")
        precondition((modes["tsVisibleInputModeOrderedArrayKey"] as! [String]).contains(id),"The mode must appear in system UI order")
        print("PASS: installed mode is visible in system UI:",id)
    }
    precondition(url.lastPathComponent == (english ? "InputMenuEnglish-v1.pdf" : "InputMenuIcon-v6.pdf"),"System must load the corresponding vector icon")
    guard let image = NSImage(contentsOf:url), image.isValid, image.size == NSSize(width:16,height:16) else { fatalError("System image cannot load") }
    guard let namePointer = TISGetInputSourceProperty(source,kTISPropertyLocalizedName) else { fatalError("Name missing") }
    let name = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
    precondition(name == (english ? "方寸输入法 · 英文" : "方寸输入法"),"System name must match installed product")
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
    try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:english ? ".build/system-menu-english.png" : ".build/system-menu-icon.png"))
    print("PASS:",name,id,"native icon:",url.lastPathComponent,"coverage:",coverage)
    found += 1
}
precondition(found == 3,"The stable input method and its Chinese/English modes must be registered")
