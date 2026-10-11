import Foundation
struct TranslationClient {
    static let maximumCharacters = 20_000
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        return URLSession(configuration:config,delegate:NoRedirects(),delegateQueue:nil)
    }()
    private struct Request: Encodable {
        struct Thinking: Encodable { var type = "disabled" }
        var model:String; var messages:[AIMessage]; var stream = false
        var thinking: Thinking?
    }
    // DeepSeek's OpenAI-compatible endpoint enables thinking by default.
    // Keep its extension out of requests to unrelated compatible servers.
    static func requestBody(_ text:String,configuration:ModelConfiguration) throws -> Data {
        try requestBody(messages:[AIMessage(role:"system",content:configuration.effectiveInstruction),AIMessage(role:"user",content:text)],configuration:configuration)
    }
    static func requestBody(messages:[AIMessage],configuration:ModelConfiguration) throws -> Data {
        let deepSeek = configuration.requestURL?.host?.lowercased() == "api.deepseek.com"
        return try JSONEncoder().encode(Request(model:configuration.model,messages:messages,thinking:deepSeek ? Request.Thinking() : nil))
    }
    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { var content:String?; var reasoning_content:String? }; var message:Message }
        var choices:[Choice]
    }
    struct Outcome { var text:String; var hasReasoning:Bool }
    func translate(_ text: String, configuration: ModelConfiguration, apiKey: String) async throws -> String {
        try await perform(text,configuration:configuration,apiKey:apiKey).text
    }
    func perform(_ text: String, configuration: ModelConfiguration, apiKey: String) async throws -> Outcome {
        guard text.count <= Self.maximumCharacters else { throw AppError.message("整段翻译最多支持 20,000 字，请分段翻译。原文仍保留。") }
        return try await generate(messages:[AIMessage(role:"system",content:configuration.effectiveInstruction),AIMessage(role:"user",content:text)],configuration:configuration,apiKey:apiKey)
    }
    func generate(messages:[AIMessage],configuration:ModelConfiguration,apiKey:String) async throws -> Outcome {
        guard let url = configuration.requestURL else { throw AppError.message("服务地址无效；远程服务须使用 HTTPS，本机服务可使用 HTTP。") }
        guard !configuration.model.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AppError.message("请在模型设置中填写模型名称。") }
        guard let last = messages.last, last.role == "user", !last.content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw AppError.message("请先输入内容。") }
        let size = messages.reduce(0) { $0 + $1.content.count }
        guard size <= 60_000 else { throw AppError.message("本次会话已超过 60,000 字，请精简资料或重新提问。草稿与回答仍保留。") }
        var request = URLRequest(url:url)
        request.httpMethod = "POST"
        request.timeoutInterval = size > 4000 ? 90 : 25
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey,forHTTPHeaderField:"Authorization") }
        request.httpBody = try Self.requestBody(messages:messages,configuration:configuration)
        let (data,response) = try await Self.session.data(for:request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AppError.message("服务未返回有效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let reason: String
            switch http.statusCode {
            case 401,403: reason = "认证失败，请检查 API Key。"
            case 429: reason = "服务限流或余额不足，请稍后手动重试。"
            case 300..<400: reason = "接口返回重定向，请填写最终 API 地址。"
            default: reason = "模型服务返回 HTTP \(http.statusCode)，内容已保留，可手动重试。"
            }
            throw AppError.message(reason)
        }
        guard data.count <= 1_000_000 else { throw AppError.message("服务返回内容过大。") }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self,from:data) }
        catch { throw AppError.message("服务响应格式不兼容 OpenAI Chat Completions。") }
        let translation = decoded.choices.first?.message.content?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !translation.isEmpty else { throw AppError.message("模型未返回结果，内容已保留，可手动重试。") }
        return Outcome(text:translation,hasReasoning:!(decoded.choices.first?.message.reasoning_content ?? "").isEmpty)
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler:@escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
