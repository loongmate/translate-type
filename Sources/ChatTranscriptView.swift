import AppKit

/// Selectable native transcript. Completed answers remain separate from tool logs.
@MainActor
final class ChatTranscriptView: NSScrollView, NSTextViewDelegate {
    let textView = ChatTranscriptTextView()
    var onCopyAnswer: ((String) -> Void)?
    var onInsertAnswer: ((String) -> Void)?
    var onSelectionChanged: (() -> Void)?
    private var previous: [AgentMessage]?
    private var answerRanges: [NSRange] = []
    private var expandedTools = Set<String>()
    override init(frame:NSRect) {
        super.init(frame:frame)
        hasVerticalScroller = true; autohidesScrollers = true; borderType = .noBorder
        drawsBackground = true; backgroundColor = WorkspaceStyle.surface
        textView.delegate = self; textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
        textView.backgroundColor = WorkspaceStyle.surface; textView.textContainerInset = NSSize(width:36,height:22)
        textView.selectedTextAttributes = [.backgroundColor:WorkspaceStyle.tint,.foregroundColor:WorkspaceStyle.ink]
        textView.linkTextAttributes = [.foregroundColor:WorkspaceStyle.accent,.cursor:NSCursor.pointingHand]
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("问问 AI 消息流"); documentView = textView
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let previous { self.previous = nil; update(previous) }
    }
    func update(_ messages:[AgentMessage]) {
        guard messages != previous else { return }; previous = messages
        let selection = textView.selectedRange(), origin = contentView.bounds.origin
        let follows = selection.length == 0 && textView.bounds.maxY-contentView.bounds.maxY < 80
        let result = NSMutableAttributedString(); answerRanges = []; textView.userRanges = []
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4; paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:14),.foregroundColor:WorkspaceStyle.ink,.paragraphStyle:paragraph]
        func append(_ text:String,_ attributes:[NSAttributedString.Key:Any]) { result.append(NSAttributedString(string:text,attributes:attributes)) }
        func gap() { append("\n",[.font:NSFont.systemFont(ofSize:7)]) }
        if messages.isEmpty {
            let center = NSMutableParagraphStyle(); center.alignment = .center; center.paragraphSpacing = 14; center.paragraphSpacingBefore = 45
            append("今天，想一起做点什么？\n",[.font:NSFont.systemFont(ofSize:24,weight:.medium),.foregroundColor:WorkspaceStyle.ink,.paragraphStyle:center])
            center.paragraphSpacingBefore = 0; center.lineSpacing = 6
            append("问一个问题，理清一些想法，或处理手边的小事。\n从你需要的地方开始。",[.font:NSFont.systemFont(ofSize:13),.foregroundColor:WorkspaceStyle.muted,.paragraphStyle:center])
        }
        var index = 0
        while index < messages.count {
            let message = messages[index]
            if message.role == "user" {
                let user = paragraph.mutableCopy() as! NSMutableParagraphStyle
                user.headIndent = 60; user.firstLineHeadIndent = 60; user.tailIndent = -12
                let start = result.length
                append(message.content,[.font:NSFont.systemFont(ofSize:14),.foregroundColor:WorkspaceStyle.ink,.paragraphStyle:user])
                textView.userRanges.append(NSRange(location:start,length:result.length-start)); append("\n",body); gap(); gap()
            } else if message.role == "assistant", !message.calls.isEmpty {
                if !message.content.isEmpty { append(message.content+"\n",body) }
                var end = index+1, tools: [AgentMessage] = []
                let callIDs = Set(message.calls.map(\.id))
                while end < messages.count, messages[end].role == "tool", callIDs.contains(messages[end].callID ?? "") { tools.append(messages[end]); end += 1 }
                let working = message.state == "running" || tools.contains { ["running","queued"].contains($0.state) }
                let failed = ["failed","stopped"].contains(message.state) || tools.contains { ["failed","stopped"].contains($0.state) }
                let summary = (working ? "正在执行" : failed ? "执行已结束 · 请查看详情" : "已完成")+" · \(message.calls.count) 个工具步骤"
                append((expandedTools.contains(message.id) ? "▾  " : "▸  ")+summary+"\n",[.font:NSFont.systemFont(ofSize:11),.foregroundColor:WorkspaceStyle.muted,.link:"fangcun-tool:"+message.id,.paragraphStyle:paragraph])
                if expandedTools.contains(message.id) {
                    for call in message.calls {
                        append(call.name+"  "+String(call.arguments.prefix(1200))+"\n",[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.medium),.foregroundColor:WorkspaceStyle.accent,.paragraphStyle:paragraph])
                        if let tool = tools.first(where:{$0.callID == call.id}) { append(String(tool.content.prefix(4000))+(tool.content.count > 4000 ? "\n…显示前 4000 字；完整结果已发送给模型。" : "")+"\n",[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:WorkspaceStyle.muted,.paragraphStyle:paragraph]) }
                    }
                }
                gap(); index = end; continue
            } else if message.role == "tool" {
                append("工具 · \(message.name ?? "执行记录")\n"+String(message.content.prefix(4000))+"\n",[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:WorkspaceStyle.muted,.paragraphStyle:paragraph]); gap()
            } else {
                append("方寸"+(message.state == "running" ? " · 正在回答" : message.state == "stopped" ? " · 已停止" : "")+"\n",[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:WorkspaceStyle.accent,.paragraphStyle:paragraph])
                let start = result.length, content = message.content.isEmpty && message.state == "running" ? "正在接收消息…" : message.content
                result.append(Self.markdown(content,base:body))
                if message.role == "assistant", message.state == "complete", !content.isEmpty { answerRanges.append(NSRange(location:start,length:result.length-start)) }
                append("\n",body)
                if message.state == "complete", !content.isEmpty {
                    append("复制",[.font:NSFont.systemFont(ofSize:10),.foregroundColor:WorkspaceStyle.muted,.link:"fangcun-copy:"+message.id]); append("    ",[.font:NSFont.systemFont(ofSize:10)])
                    append("插入\n",[.font:NSFont.systemFont(ofSize:10),.foregroundColor:WorkspaceStyle.muted,.link:"fangcun-insert:"+message.id])
                }
                gap(); gap()
            }
            index += 1
        }
        textView.textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { textView.setSelectedRange(selection) }
        if follows { textView.scrollRangeToVisible(NSRange(location:result.length,length:0)) }
        else { contentView.scroll(to:origin); reflectScrolledClipView(contentView) }
        textView.needsDisplay = true
    }
    private static func markdown(_ text:String,base:[NSAttributedString.Key:Any]) -> NSAttributedString {
        let output = NSMutableAttributedString(); var fenced = false
        let lines = text.components(separatedBy:"\n")
        for (index,line) in lines.enumerated() {
            if line.hasPrefix("```") { fenced.toggle(); continue }
            if line.isEmpty, !fenced {
                let space = NSMutableParagraphStyle(); space.paragraphSpacing = 0
                output.append(NSAttributedString(string:"\n",attributes:[.font:NSFont.systemFont(ofSize:5),.paragraphStyle:space])); continue
            }
            var value = line, attributes = base
            if fenced { attributes[.font] = NSFont.monospacedSystemFont(ofSize:12,weight:.regular); attributes[.backgroundColor] = WorkspaceStyle.soft }
            else if let range = value.range(of:"^#{1,6} ",options:.regularExpression) { value.removeSubrange(range); attributes[.font] = NSFont.systemFont(ofSize:16,weight:.semibold) }
            else if value.hasPrefix("- ") || value.hasPrefix("* ") { value = "•  "+value.dropFirst(2) }
            let content = NSMutableAttributedString(string:value,attributes:attributes)
            if !fenced {
                for pattern in ["\\*\\*([^*]+)\\*\\*","`([^`]+)`"] {
                    guard let regex = try? NSRegularExpression(pattern:pattern) else { continue }
                    let source = content.string as NSString
                    for match in regex.matches(in:content.string,range:NSRange(location:0,length:content.length)).reversed() {
                        let replacement = NSMutableAttributedString(string:source.substring(with:match.range(at:1)),attributes:attributes)
                        replacement.addAttribute(.font,value:pattern.hasPrefix("`") ? NSFont.monospacedSystemFont(ofSize:12,weight:.regular) : NSFont.systemFont(ofSize:14,weight:.semibold),range:NSRange(location:0,length:replacement.length))
                        content.replaceCharacters(in:match.range,with:replacement)
                    }
                }
            }
            output.append(content); if index < lines.count-1 { output.append(NSAttributedString(string:"\n",attributes:base)) }
        }
        return output
    }
    func toggleToolDetails(_ id:String) {
        if !expandedTools.insert(id).inserted { expandedTools.remove(id) }
        textView.setSelectedRange(NSRange(location:0,length:0))
        if let previous { self.previous = nil; update(previous) }
    }
    func resetConversation() {
        previous = nil; expandedTools.removeAll(); textView.userRanges = []
        textView.textStorage?.setAttributedString(NSAttributedString(string:""))
        textView.setSelectedRange(NSRange(location:0,length:0)); contentView.scroll(to:.zero)
    }
    func textView(_ textView:NSTextView,clickedOnLink link:Any,at charIndex:Int) -> Bool {
        let value = (link as? URL)?.absoluteString ?? (link as? String ?? "")
        if value.hasPrefix("fangcun-tool:") { toggleToolDetails(String(value.dropFirst("fangcun-tool:".count))); return true }
        guard let message = previous?.first(where:{value.hasSuffix($0.id)}), message.role == "assistant", message.calls.isEmpty, message.state == "complete" else { return true }
        if value.hasPrefix("fangcun-copy:") { onCopyAnswer?(message.content) }
        else if value.hasPrefix("fangcun-insert:") { onInsertAnswer?(message.content) }
        return true
    }
    func textViewDidChangeSelection(_ notification:Notification) { onSelectionChanged?() }
    func answerSelection(or latest:String?) -> String? {
        let selection = textView.selectedRange()
        if selection.length == 0 { return latest }
        guard answerRanges.contains(where:{NSIntersectionRange($0,selection) == selection}) else { return nil }
        return (textView.string as NSString).substring(with:selection)
    }
}

@MainActor
final class ChatTranscriptTextView: NSTextView {
    var userRanges: [NSRange] = []
    override func drawBackground(in rect:NSRect) {
        super.drawBackground(in:rect)
        guard let layoutManager, let textContainer else { return }
        for range in userRanges where NSMaxRange(range) <= (string as NSString).length && range.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
            var bubble = layoutManager.boundingRect(forGlyphRange:glyphs,in:textContainer).offsetBy(dx:textContainerOrigin.x,dy:textContainerOrigin.y).insetBy(dx:-12,dy:-7)
            bubble.size.width = min(bubble.width,bounds.width-bubble.minX-20)
            if bubble.intersects(rect) { WorkspaceStyle.tint.setFill(); NSBezierPath(roundedRect:bubble,xRadius:10,yRadius:10).fill() }
        }
    }
}
