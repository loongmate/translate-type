import Foundation

@main struct CredentialTests {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FangCunCredentials-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("private/api-keys.json")
        let store = APIKeyStore(file:file)
        let endpoint = "https://a.example/v1"
        try await store.save("synthetic-a",endpoint:endpoint+"/ ")
        check(try await store.read(endpoint:endpoint) == "synthetic-a","地址空白和尾斜杠归一化")
        try await store.save("synthetic-b",endpoint:"https://b.example/v1")
        let keyA = try await store.read(endpoint:endpoint), keyB = try await store.read(endpoint:"https://b.example/v1")
        check(keyA == "synthetic-a" && keyB == "synthetic-b","不同服务的 Key 独立保存")
        check(try await store.read(endpoint:"http://localhost:11434/v1") == "","无 Key 的本地服务可留空")
        let reopened = APIKeyStore(file:file)
        check(try await reopened.read(endpoint:endpoint) == "synthetic-a","重启或更新应用后直接读取本机保存值")
        try await store.save("",endpoint:endpoint)
        check(try await reopened.read(endpoint:endpoint) == "","清空 Key 后重启仍保持为空")
        let attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        let parent = try FileManager.default.attributesOfItem(atPath:file.deletingLastPathComponent().path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 && (parent[.posixPermissions] as? NSNumber)?.intValue == 0o700,"文件 0600，目录 0700")
        async let saveA: Void = store.save("parallel-a",endpoint:endpoint)
        async let saveB: Void = store.save("parallel-b",endpoint:"https://b.example/v1")
        _ = try await (saveA,saveB)
        let parallelA = try await store.read(endpoint:endpoint), parallelB = try await store.read(endpoint:"https://b.example/v1")
        check(parallelA == "parallel-a" && parallelB == "parallel-b","并发保存不同服务不会丢失其中一个 Key")

        let missing = APIKeyStore(file:directory.appendingPathComponent("missing/keys.json"),readFile:{ _ in fatalError("不存在的文件不应访问其他存储") })
        check(try await missing.read(endpoint:endpoint) == "","本机没有 Key 时直接返回空值，没有迁移或其他读取路径")

        let invalid = directory.appendingPathComponent("invalid/keys.json")
        try FileManager.default.createDirectory(at:invalid.deletingLastPathComponent(),withIntermediateDirectories:true)
        let invalidData = Data("invalid-json".utf8); try invalidData.write(to:invalid)
        let corrupt = APIKeyStore(file:invalid)
        do { _ = try await corrupt.read(endpoint:endpoint); fatalError("损坏文件不应视为空密钥") } catch { check(true,"损坏文件显示读取错误") }
        do { try await corrupt.save("replacement",endpoint:endpoint); fatalError("不应覆盖损坏文件") } catch { check(try Data(contentsOf:invalid) == invalidData,"保存失败保留原始文件") }

        let started = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        let slow = APIKeyStore(file:directory.appendingPathComponent("slow/keys.json")) { url in
            precondition(!Thread.isMainThread)
            started.signal(); _ = release.wait(timeout:.now()+3)
            return try Data(contentsOf:url)
        }
        try await APIKeyStore(file:slow.file).save("synthetic-slow",endpoint:endpoint)
        let task = Task { try await slow.read(endpoint:endpoint) }
        var entered = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds:10_000_000)
            if started.wait(timeout:.now()) == .success { entered = true; break }
        }
        check(entered,"模拟密钥读取正在后台阻塞")
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        try await Task.sleep(nanoseconds:30_000_000)
        check(heartbeat,"密钥读取被阻塞时主线程仍处理事件")
        task.cancel(); release.signal()
        do { _ = try await task.value; fatalError("已取消的读取不应返回凭据给调用方") }
        catch is CancellationError { check(true,"取消后迟到的密钥结果不会继续使用") }
        print("ALL CREDENTIAL TESTS PASSED")
    }
    static func check(_ value:Bool,_ label:String) { precondition(value,label); print("PASS:",label) }
}
