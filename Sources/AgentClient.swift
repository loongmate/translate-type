import Foundation

/// Chat Completions transport shared by compatible providers. Hidden reasoning is never shown.
struct AgentClient {
    struct Response { var content: String; var calls: [AgentToolCall] }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        return URLSession(configuration:config,delegate:AgentNoRedirects(),delegateQueue:nil)
    }()
    func stream(messages:[AgentMessage],configuration:ModelConfiguration,key:String,
                onText:@escaping @Sendable (String) async -> Void) async throws -> Response {
        guard let url = configuration.requestURL else { throw AgentFailure("请填写有效的模型服务地址。") }
        guard !configuration.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AgentFailure("请先在设置中选择模型。") }
        var body: [String:Any] = ["model":configuration.model,"messages":messages.map(\.wire),"stream":true,"tools":AgentTools.specs.map(\.wire),"tool_choice":"auto"]
        if url.host?.lowercased() == "api.deepseek.com" { body["thinking"] = ["type":"disabled"] }
        let data = try JSONSerialization.data(withJSONObject:body)
        guard data.count <= 1_500_000 else { throw AgentFailure("会话内容已超出上限，请新建对话；当前消息仍保留。") }
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        if !key.isEmpty { request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
        let (bytes,response) = try await Self.session.bytes(for:request)
        guard let http = response as? HTTPURLResponse else { throw AgentFailure("模型服务未返回有效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401,403: throw AgentFailure("认证失败，请检查 API Key。")
            case 429: throw AgentFailure("模型服务限流或余额不足，请稍后再发送。")
            case 300..<400: throw AgentFailure("模型接口返回重定向，请填写最终 API 地址。")
            default: throw AgentFailure("模型服务返回 HTTP \(http.statusCode)。请确认模型支持流式输出和工具调用。")
            }
        }
        var parser = AgentStreamParser()
        if http.mimeType?.lowercased() == "application/json" {
            var buffer = Data()
            for try await byte in bytes { try Task.checkCancellation(); buffer.append(byte); guard buffer.count <= 1_000_000 else { throw AgentFailure("模型响应过大。") } }
            let result = try parser.consumeJSON(buffer,streaming:false)
            if !result.isEmpty { await onText(result) }
        } else {
            // Decode lines ourselves so an unterminated, oversized SSE frame cannot grow without bound.
            var line = Data(), event: [String] = [], total = 0
            for try await byte in bytes {
                try Task.checkCancellation(); total += 1
                guard total <= 2_000_000, line.count < 512_000 else { throw AgentFailure("模型响应过大。") }
                if byte != 10 { line.append(byte); continue }
                guard let raw = String(data:line,encoding:.utf8) else { throw AgentFailure("模型消息不是有效 UTF-8。") }
                line.removeAll(keepingCapacity:true)
                let value = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                if value.isEmpty {
                    if !event.isEmpty {
                        let payload = event.joined(separator:"\n"); event.removeAll(keepingCapacity:true)
                        if payload == "[DONE]" { break }
                        let delta = try parser.consumeJSON(Data(payload.utf8),streaming:true)
                        if !delta.isEmpty { await onText(delta) }
                    }
                } else if value.hasPrefix("data:") { event.append(String(value.dropFirst(5)).trimmingCharacters(in:.whitespaces)) }
            }
            // Some compatible servers omit the final blank line, but must still supply finish_reason.
            if !line.isEmpty, let value = String(data:line,encoding:.utf8), value.hasPrefix("data:") { event.append(String(value.dropFirst(5)).trimmingCharacters(in:.whitespacesAndNewlines)) }
            if !event.isEmpty, event.joined(separator:"\n") != "[DONE]" {
                let delta = try parser.consumeJSON(Data(event.joined(separator:"\n").utf8),streaming:true)
                if !delta.isEmpty { await onText(delta) }
            }
        }
        try Task.checkCancellation()
        return try parser.finish()
    }
}
private final class AgentNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}
struct AgentStreamParser {
    private var content = "", calls: [Int:AgentToolCall] = [:], reason: String?
    mutating func consumeJSON(_ data:Data,streaming:Bool) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with:data) as? [String:Any], root["error"] == nil,
              let choices = root["choices"] as? [[String:Any]] else { throw AgentFailure("模型响应格式不兼容。") }
        guard let choice = choices.first else { return "" } // usage-only frame
        guard let message = choice[streaming ? "delta" : "message"] as? [String:Any] else { throw AgentFailure("模型消息缺少内容。") }
        let delta = message["content"] as? String ?? ""; content += delta
        if let parts = message["tool_calls"] as? [[String:Any]] {
            for (offset,part) in parts.enumerated() {
                let index = part["index"] as? Int ?? offset
                guard (0..<32).contains(index) else { throw AgentFailure("模型请求了过多工具。") }
                var call = calls[index] ?? AgentToolCall(id:"",name:"",arguments:"")
                if let id = part["id"] as? String { call.id += id }
                if let function = part["function"] as? [String:Any] {
                    call.name += function["name"] as? String ?? ""
                    call.arguments += function["arguments"] as? String ?? ""
                }
                guard call.arguments.utf8.count <= 256_000 else { throw AgentFailure("工具参数过大。") }
                calls[index] = call
            }
        }
        if let finish = choice["finish_reason"] as? String { reason = finish }
        if !streaming && reason == nil { reason = calls.isEmpty ? "stop" : "tool_calls" }
        return delta
    }
    func finish() throws -> AgentClient.Response {
        guard let reason else { throw AgentFailure("消息流中断，未完成的工具不会执行。可以继续发送消息。") }
        guard ["stop","tool_calls"].contains(reason) else { throw AgentFailure(reason == "length" ? "模型输出达到长度上限，未完成的工具不会执行。" : "模型未能完成回答（\(reason)）。") }
        let ordered = calls.keys.sorted().compactMap { calls[$0] }
        guard !ordered.isEmpty || !content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AgentFailure("模型返回了空消息。") }
        guard Set(ordered.map(\.id)).count == ordered.count, ordered.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }), reason != "tool_calls" || !ordered.isEmpty else { throw AgentFailure("模型返回了不完整的工具调用。") }
        return AgentClient.Response(content:content,calls:ordered)
    }
}
