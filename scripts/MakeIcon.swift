import AppKit
import CoreText

func glyph(_ text:String = "方",in target:CGRect)->CGPath {
    let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString,100,nil)
    var character = Array(text.utf16)[0], value:CGGlyph = 0
    precondition(CTFontGetGlyphsForCharacters(font,&character,&value,1))
    let path = CTFontCreatePathForGlyph(font,value,nil)!
    let box = path.boundingBoxOfPath
    let scale = min(target.width/box.width,target.height/box.height)
    var transform = CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:target.midX-box.midX*scale,ty:target.midY-box.midY*scale)
    return path.copy(using:&transform)!
}
func menu(_ context:CGContext,letter:String = "方") {
    let path = CGMutablePath()
    path.addRoundedRect(in:CGRect(x:0,y:0,width:16,height:16),cornerWidth:3,cornerHeight:3)
    path.addPath(glyph(letter,in:CGRect(x:2.4,y:2.1,width:11.2,height:11.8)))
    context.setFillColor(CGColor(gray:0,alpha:1))
    context.addPath(path); context.drawPath(using:.eoFill)
}
func bitmap(_ pixels:Int,logicalSize:CGFloat,draw:(CGContext)->Void)->NSBitmapImageRep {
    let result = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    result.size = NSSize(width:logicalSize,height:logicalSize)
    let context = NSGraphicsContext(bitmapImageRep:result)!.cgContext
    // NSGraphicsContext already applies the bitmap's pixels-to-points scale.
    draw(context)
    return result
}
let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
var englishMedia = CGRect(x:0,y:0,width:16,height:16)
let englishPDF = CGContext(resources.appendingPathComponent("InputMenuEnglish-v1.pdf") as CFURL,mediaBox:&englishMedia,nil)!
englishPDF.beginPDFPage(nil); menu(englishPDF,letter:"英"); englishPDF.endPDFPage(); englishPDF.closePDF()
let englishBitmap = bitmap(64,logicalSize:16) { menu($0,letter:"英") }
try englishBitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(".build/english-menu-icon-preview.png"))
if CommandLine.arguments.contains("--english-menu-only") { exit(0) }
let menuBitmap = bitmap(32,logicalSize:16) { menu($0) }
try menuBitmap.representation(using:.tiff,properties:[:])!.write(to:resources.appendingPathComponent("InputMenuIcon.tiff"))
try menuBitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(".build/menu-icon-preview.png"))
var media = CGRect(x:0,y:0,width:16,height:16)
let pdf = CGContext(resources.appendingPathComponent("InputMenuIcon-v6.pdf") as CFURL,mediaBox:&media,nil)!
pdf.beginPDFPage(nil); menu(pdf); pdf.endPDFPage(); pdf.closePDF()
let iconset = root.appendingPathComponent(".build/TranslateType.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for factor in [1,2] {
        let icon = bitmap(size*factor,logicalSize:1024) { context in
            let tile = CGPath(roundedRect:CGRect(x:72,y:72,width:880,height:880),cornerWidth:196,cornerHeight:196,transform:nil)
            context.saveGState(); context.addPath(tile); context.clip()
            let colors = [CGColor(red:0.45,green:0.31,blue:0.73,alpha:1),CGColor(red:0.62,green:0.45,blue:0.88,alpha:1)] as CFArray
            let gradient = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,1])!
            context.drawLinearGradient(gradient,start:CGPoint(x:512,y:72),end:CGPoint(x:512,y:952),options:[])
            context.restoreGState()
            context.setStrokeColor(CGColor(gray:1,alpha:0.24)); context.setLineWidth(12); context.addPath(tile); context.strokePath()
            context.setFillColor(CGColor(gray:1,alpha:1)); context.addPath(glyph(in:CGRect(x:232,y:235,width:560,height:570))); context.fillPath()
        }
        let name = "icon_\(size)x\(size)"+(factor == 2 ? "@2x" : "")+".png"
        try icon.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent(name))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil")
process.arguments = ["-c","icns","-o",resources.appendingPathComponent("AppIcon.icns").path,iconset.path]
try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
print("已生成方寸输入法应用图标及系统输入图标。")
