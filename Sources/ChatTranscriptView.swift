import AppKit

/// Selectable native transcript. Tool text is kept distinct from assistant answers for insertion.
@MainActor
final class ChatTranscriptView: NSScrollView {
    let textView = NSTextView()
    private var previous: [AgentMessage]?
    private var answerRanges: [NSRange] = []
    override init(frame:NSRect) {
        super.init(frame:frame)
        hasVerticalScroller = true; autohidesScrollers = true; borderType = .noBorder
        wantsLayer = true; layer?.cornerRadius = 10; layer?.borderWidth = 1; layer?.borderColor = NSColor(calibratedWhite:0.88,alpha:1).cgColor
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
        textView.backgroundColor = .white; textView.textContainerInset = NSSize(width:18,height:14)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("问问 AI 消息流")
        documentView = textView
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ messages:[AgentMessage]) {
        guard messages != previous else { return }; previous = messages
        let selection = textView.selectedRange(), origin = contentView.bounds.origin
        let follows = selection.length == 0 && textView.bounds.maxY - contentView.bounds.maxY < 60
        let result = NSMutableAttributedString(); answerRanges = []
        let purple = NSColor(calibratedRed:0.48,green:0.34,blue:0.77,alpha:1)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 12
        func append(_ text:String,_ attributes:[NSAttributedString.Key:Any]) { result.append(NSAttributedString(string:text,attributes:attributes)) }
        if messages.isEmpty {
            append("问问 AI\n",[.font:NSFont.systemFont(ofSize:22,weight:.semibold),.foregroundColor:purple,.paragraphStyle:paragraph])
            append("可以问问题，也可以让我整理文件、修改代码或运行命令。\n输入任务后发送，工具执行过程会显示在这里。",[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
        }
        for message in messages {
            let label = message.role == "user" ? "你" : message.role == "tool" ? "↳ \(message.name ?? "工具")" : "方寸 · 问问 AI"
            let suffix = message.state == "running" ? "  ·  进行中" : message.state == "queued" ? "  ·  等待执行" : message.state == "stopped" ? "  ·  已停止" : message.state == "failed" ? "  ·  失败" : ""
            append(label + suffix + "\n",[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:message.role == "assistant" ? purple : NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
            let start = result.length
            let body = message.content.isEmpty && message.state == "running" ? "正在接收消息…" : message.content
            append(message.role == "tool" ? String(body.prefix(4000)) + (body.count > 4000 ? "\n…显示前 4000 字；完整结果已发送给模型。" : "") : body,[.font:message.role == "tool" ? NSFont.monospacedSystemFont(ofSize:12,weight:.regular) : NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
            if message.role == "assistant", message.calls.isEmpty, message.state == "complete", !body.isEmpty { answerRanges.append(NSRange(location:start,length:result.length-start)) }
            append("\n\n",[.font:NSFont.systemFont(ofSize:8)])
            for call in message.calls {
                append("调用 \(call.name)  \(String(call.arguments.prefix(1200)))\n",[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
            }
        }
        textView.textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { textView.setSelectedRange(selection) }
        if follows { textView.scrollRangeToVisible(NSRange(location:result.length,length:0)) }
        else { contentView.scroll(to:origin); reflectScrolledClipView(contentView) }
    }
    func answerSelection(or latest:String?) -> String? {
        let selection = textView.selectedRange()
        if selection.length == 0 { return latest }
        guard answerRanges.contains(where: { NSIntersectionRange($0,selection) == selection }) else { return nil }
        return (textView.string as NSString).substring(with:selection)
    }
}
