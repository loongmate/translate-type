import Foundation

/// Opt-in smoke probe. Never runs from the offline test scripts; never prints credentials or payloads.
@main struct AgentLiveProbe {
    @MainActor static func main() async throws {
        guard ProcessInfo.processInfo.environment["FANGCUN_AGENT_LIVE"] == "1" else { print("Set FANGCUN_AGENT_LIVE=1 to test the configured provider."); return }
        let store = ConfigurationStore(defaults:UserDefaults(suiteName:"com.fangcun.inputmethod.FangCun")!)
        let configuration = store.model
        guard !configuration.model.isEmpty, configuration.requestURL != nil else { throw AgentFailure("模型尚未配置。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunAgentLive-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let agent = AgentSession(); agent.setDirectory(directory.path)
        var streamed = false
        agent.onUpdate = { if agent.isRunning && agent.messages.contains(where:{$0.role == "assistant" && $0.state == "running" && !$0.content.isEmpty}) { streamed = true } }
        agent.send("这是工具链验证。只允许操作当前临时工作目录。请实际使用 write_file 创建 smoke.txt 内容 fangcun-agent-ok，再使用 read_file 读取验证，然后使用 shell_exec 执行 printf shell-ok 并验证退出码为 0。必须使用这三个工具，不能只描述步骤。最后简短回复验证结果，不做其他操作。",configuration:configuration,readKey:{ try await APIKeyStore.shared.read(endpoint:$0) })
        for _ in 0..<1200 { if !agent.isRunning { break }; try await Task.sleep(nanoseconds:100_000_000) }
        if agent.isRunning { agent.stop(); throw AgentFailure("真实模型验证超时。") }
        if let error = agent.error { throw AgentFailure(error) }
        let names = Set(agent.messages.filter { $0.role == "tool" && $0.state == "complete" }.compactMap(\.name))
        guard names.isSuperset(of:["write_file","read_file","shell_exec"]), streamed,
              try String(contentsOf:directory.appendingPathComponent("smoke.txt"),encoding:.utf8).contains("fangcun-agent-ok"), agent.latestAnswer != nil else { throw AgentFailure("真实模型未完成全部工具验证。") }
        print("PASS: configured provider streaming + write_file + read_file + shell_exec + final answer")
        print("Provider: \(configuration.requestURL!.host!) / \(configuration.model); tool calls: \(agent.messages.filter { $0.role == "tool" }.count)")
        agent.stop()
    }
}
