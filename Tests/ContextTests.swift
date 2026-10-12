import AppKit
import InputMethodKit

@main struct ContextTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let client = TextClient()
        var count = 0
        func check(_ expected:String?,_ label:String,composition:Bool = false,limit:Int = 64) {
            let result = SurroundingContext.read(client,hasComposition:composition,limit:limit)
            precondition(result.prefix == expected,"\(label): \(result.status), got \(String(describing:result.prefix))")
            count += 1; print("PASS:",label)
        }
        func put(_ text:String,_ selection:NSRange? = nil) {
            client.text.unmarkText(); client.text.string = text
            client.text.setSelectedRange(selection ?? NSRange(location:text.utf16.count,length:0))
        }
        put("上"); check("上","已上屏单字")
        put("我要去上海",NSRange(location:4,length:0)); check("我要去上","光标中间，只取光标前文")
        put("墙上"); check("墙上","保留多字语境，不能只记最后一个上字")
        put(""); check("","删除所有内容，不沿用旧前文")
        put("海"); check("海","同一位置改成另一字")
        put("甲上尾巴",NSRange(location:2,length:2)); check("甲上","选区替换以选区起点为边界")
        put("🙂上"); check("🙂上","UTF-16 emoji")
        put("第一行\n上"); check("第一行\n上","粘贴、多行文本")
        put(String(repeating:"甲",count:200)+"上"); check(String(repeating:"甲",count:63)+"上","长文只查询64个UTF-16单元")
        put("上"); client.lengthOverride = 0; check("上","宿主报告长度0仍能局部读取")
        client.lengthOverride = NSNotFound; check("上","文档长度不可用仍可读取"); client.lengthOverride = nil
        client.text.setMarkedText("hai",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        check("上","排除未上屏拼音",composition:true)
        client.text.setSelectedRange(NSRange(location:2,length:0)); check("上","在拼音内部移动仍以预编辑起点为准",composition:true)
        client.markedOverride = NSRange(location:NSNotFound,length:NSNotFound); check(nil,"未上屏范围未知时放弃",composition:true)
        client.markedOverride = nil; put("上")
        client.selectionOverride = NSRange(location:NSNotFound,length:NSNotFound); check(nil,"未知光标不猜上下文")
        client.selectionOverride = NSRange(location:Int.max-1,length:10); check(nil,"范围溢出不查询")
        client.selectionOverride = nil
        client.substringUnavailable = true; check(nil,"不可读时不回用上次内容"); client.substringUnavailable = false
        client.stringHandler = { _,_ in nil }; check("上","折叠光标兼容无actualRange的属性查询")
        put("上尾",NSRange(location:1,length:1)); check(nil,"选区查询可能退回选中文本时不能把尾字误当前文")
        client.stringHandler = nil; put("上")
        client.contextReadHook = { client.text.setSelectedRange(NSRange(location:0,length:0)) }
        check(nil,"读取过程中光标变化会丢弃结果"); client.contextReadHook = nil
        put("上"); client.markedOverride = NSRange(location:0,length:1)
        client.selectionOverride = NSRange(location:2,length:0); check(nil,"选区和预编辑互相矛盾")
        client.markedOverride = nil; client.selectionOverride = nil
        let other = TextClient(); other.text.string = "下"; other.text.setSelectedRange(NSRange(location:1,length:0))
        precondition(SurroundingContext.read(other).prefix == "下"); count += 1
        print("PASS: 同应用另一输入框不串用前文")
        precondition(client.lengthQueries == 0); count += 1; print("PASS: 不读取整篇文档长度")
        put("上"); client.stringHandler = { _, actual in actual = NSRange(location:0,length:2); return "上" }
        client.substringUnavailable = true; check(nil,"实际范围与返回长度冲突时放弃")
        client.stringHandler = nil; client.substringUnavailable = false
        print("CONTEXT TESTS PASSED:",count)
    }
}
