import Foundation

struct AgentToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
    var wire: [String:Any] { ["id":id,"type":"function","function":["name":name,"arguments":arguments]] }
}
struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var role: String
    var content: String = ""
    var calls: [AgentToolCall] = []
    var callID: String? = nil
    var name: String? = nil
    var state = "complete"
    var wire: [String:Any] {
        var value: [String:Any] = ["role":role,"content":content]
        if !calls.isEmpty { value["tool_calls"] = calls.map(\.wire) }
        if let callID { value["tool_call_id"] = callID }
        return value
    }
}
struct AgentToolSpec {
    var name: String
    var description: String
    var properties: [String:Any]
    var required: [String]
    var wire: [String:Any] {
        ["type":"function","function":["name":name,"description":description,"parameters":["type":"object","properties":properties,"required":required,"additionalProperties":false]]]
    }
}
struct AgentFailure: LocalizedError {
    var message: String
    init(_ message:String) { self.message = message }
    var errorDescription: String? { message }
}
