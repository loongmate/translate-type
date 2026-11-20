import Foundation
import JavaScriptCore

enum ScratchpadFormat: String, Codable, CaseIterable, Sendable {
    case automatic, markdown, html, json, text
    var title: String {
        switch self { case .automatic:return "自动识别"; case .markdown:return "Markdown"; case .html:return "HTML"; case .json:return "JSON"; case .text:return "纯文本" }
    }
    static func detect(_ text:String,filename:String?) -> Self {
        switch (filename.map { ($0 as NSString).pathExtension.lowercased() } ?? "") {
        case "md","markdown":return .markdown
        case "html","htm":return .html
        case "json":return .json
        case "txt":return .text
        default:break
        }
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        // A fenced HTML example is Markdown; an actual HTML document/fragment is HTML.
        if value.hasPrefix("```") || value.hasPrefix("~~~") { return .markdown }
        if value.range(of:"(?is)^(?:<!--.*?-->\\s*)*(?:<!doctype\\s+html|<(?:html|head|body|div|section|article|main|h[1-6]|p|style|table|ul|ol|span|svg|a|img|form|button|details)(?:\\s|>|/))",options:.regularExpression) != nil { return .html }
        if (value.hasPrefix("{") || value.hasPrefix("[")), let data = value.data(using:.utf8), (try? JSONSerialization.jsonObject(with:data)) != nil { return .json }
        if value.range(of:"(?m)^(?: {0,3}(?:#{1,6}\\s|[-*+]\\s|[0-9]+[.)]\\s|>\\s|```|~~~)|\\|.*\\|$)|\\*\\*[^*]+\\*\\*|`[^`]+`|!?\\[[^\\]]+\\]\\([^\\)]+\\)|(?m)^.+\\n(?:===+|---+)\\s*$",options:.regularExpression) != nil { return .markdown }
        if value.range(of:"(?m)^(?: {0,3}[-*_](?:[ \t]*[-*_]){2,})[ \t]*$|(?<!\\w)[*_][^*_\\n]+[*_](?!\\w)|__[^_\\n]+__|~~[^~\\n]+~~",options:.regularExpression) != nil { return .markdown }
        return .text
    }
}
struct ScratchpadPreview: Sendable {
    var html: String
    var format: ScratchpadFormat
    var note: String?
}
actor ScratchpadRenderer {
    private var context: JSContext?
    private let library: URL?
    init(library:URL? = Bundle.main.url(forResource:"marked-18.1.1.umd",withExtension:"js",subdirectory:"Preview")) { self.library = library }
    func render(_ text:String,format:ScratchpadFormat,filename:String? = nil,dark:Bool = false) throws -> ScratchpadPreview {
        try Task.checkCancellation()
        let kind = format == .automatic ? ScratchpadFormat.detect(text,filename:filename) : format
        let limit = 200_000, content = String(text.prefix(limit))
        var note = text.count > limit ? "内容较长，仅预览前 200,000 字；编辑和保存仍保留全文。" : nil
        let body: String
        switch kind {
        case .markdown:
            if context == nil {
                guard let library, let script = try? String(contentsOf:library,encoding:.utf8), let vm = JSContext() else { throw AgentFailure("Markdown 预览组件未安装，原文仍可编辑和保存。") }
                vm.evaluateScript(script)
                guard vm.exception == nil else { throw AgentFailure("Markdown 预览组件无法载入。") }
                context = vm
            }
            context?.exception = nil
            guard let result = context?.objectForKeyedSubscript("marked")?.invokeMethod("parse",withArguments:[content,["gfm":true,"async":false]]), context?.exception == nil, result.isString else { throw AgentFailure("Markdown 预览失败，原文仍保留。") }
            body = result.toString()
        case .html: body = content
        case .json:
            if let data = content.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data), let formatted = try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]), let json = String(data:formatted,encoding:.utf8) { body = "<pre><code>" + Self.escape(json) + "</code></pre>" }
            else { body = "<pre>" + Self.escape(content) + "</pre>"; note = note ?? "JSON 格式尚未完整，暂按原文显示。" }
        case .text,.automatic: body = "<pre class=plain>" + Self.escape(content) + "</pre>"
        }
        try Task.checkCancellation()
        // CSP is first in the document, so pasted HTML cannot relax it with its own meta tags.
        let document = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:light;accent-color:#7857c2}*{box-sizing:border-box}body{margin:0;padding:28px;color:#272330;background:#fff;font:15px/1.7 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;overflow-wrap:anywhere}h1,h2,h3{line-height:1.3;margin:1.4em 0 .65em}h1{font-size:28px}h2{font-size:22px;border-bottom:1px solid #e9e4ef;padding-bottom:8px}h3{font-size:18px}body>:first-child{margin-top:0}a{color:#7857c2}pre{padding:16px;background:#f7f5fa;border-radius:8px;overflow:auto;white-space:pre-wrap;word-break:normal}pre.plain{padding:0;background:transparent;font:inherit;white-space:pre-wrap}code{font:13px/1.6 ui-monospace,Menlo,monospace;background:#f3f0f7;border-radius:4px;padding:2px 4px}pre code{padding:0;background:none}blockquote{margin-left:0;padding-left:16px;border-left:3px solid #ab96d1;color:#6b6278}table{border-collapse:collapse;width:100%;margin:16px 0}td,th{border:1px solid #e3ddea;padding:8px 12px;text-align:left}th{background:#f8f5fc}img,svg,video{max-width:100%;height:auto}hr{border:0;border-top:1px solid #e3ddea}input[type=checkbox]{margin-right:8px}
        :root{color-scheme:\(dark ? "dark" : "light");accent-color:\(dark ? "#b09bd8" : "#7960bb")}
        body{padding:8px 36px 36px;background:\(dark ? "#2c2933" : "#fff");color:\(dark ? "#e0dbe9" : "#2d2935");font-size:14px;line-height:1.95}
        h1{font-size:26px;letter-spacing:.2px}h2{font-size:17px;border:0;padding:0}h3{font-size:15px}h1,h2,h3{font-weight:600;line-height:1.5}
        p,li{color:\(dark ? "#c1b8cd" : "#716a7e")}li{margin:4px 0}
        pre,th{background:\(dark ? "#29262f" : "#faf9fc")}code{background:\(dark ? "#3b324c" : "#eee9f7");color:\(dark ? "#b09bd8" : "#7960bb")}
        blockquote{border-left:2px solid #b7a0d3;background:\(dark ? "#29262f" : "#faf9fc");padding:8px 14px;color:\(dark ? "#afa6ba" : "#807b8c")}
        td,th,hr{border-color:\(dark ? "#3a3443" : "#eeecf2")}a{color:\(dark ? "#b09bd8" : "#7960bb")}
        li:has(>input[type=checkbox]){list-style:none;margin-left:-20px}
        </style></head><body>\(body)</body></html>
        """
        return ScratchpadPreview(html:document,format:kind,note:note)
    }
    static func escape(_ value:String) -> String {
        value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
    }
}
