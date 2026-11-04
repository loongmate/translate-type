import Foundation
import Darwin

/// A process group per command keeps cancellation scoped to this conversation, including children.
final class AgentProcess: @unchecked Sendable {
    let id = "sh_" + UUID().uuidString.prefix(8)
    let pid: pid_t
    let command: String
    private let outputPipe = Pipe(), inputPipe = Pipe()
    private var bytes = Data(), dropped = 0
    private let lock = NSLock()
    private var eof = false
    private let readQueue = DispatchQueue(label:"com.fangcun.agent.shell-output",qos:.utility)
    private var reader: DispatchSourceRead?
    private(set) var exitCode: Int?
    private var closed = false
    init(command:String,cwd:String,login:Bool = false) throws {
        self.command = command
        var actions: posix_spawn_file_actions_t?, attrs: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attrs)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attrs) }
        posix_spawn_file_actions_adddup2(&actions,outputPipe.fileHandleForWriting.fileDescriptor,STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions,outputPipe.fileHandleForWriting.fileDescriptor,STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions,inputPipe.fileHandleForReading.fileDescriptor,STDIN_FILENO)
        for fd in [outputPipe.fileHandleForReading.fileDescriptor,outputPipe.fileHandleForWriting.fileDescriptor,inputPipe.fileHandleForReading.fileDescriptor,inputPipe.fileHandleForWriting.fileDescriptor] { posix_spawn_file_actions_addclose(&actions,fd) }
        posix_spawnattr_setflags(&attrs,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)); posix_spawnattr_setpgroup(&attrs,0)
        let args = ["/bin/zsh",login ? "-lc" : "-c","cd -- \"$1\" || exit; eval \"$2\"","fangcun-agent",cwd,command]
        let env = ProcessInfo.processInfo.environment.merging(["PATH":"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8"]) { _,new in new }
        let argv = args.map { strdup($0) } + [nil], envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let code = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in posix_spawn(&child,"/bin/zsh",&actions,&attrs,a.baseAddress!,e.baseAddress!) } }
        guard code == 0 else { throw AgentFailure("无法启动命令：\(String(cString:strerror(code)))") }
        pid = child
        outputPipe.fileHandleForWriting.closeFile(); inputPipe.fileHandleForReading.closeFile()
        let fd = inputPipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd,F_SETNOSIGPIPE,1)
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(outputFD,F_SETFL,fcntl(outputFD,F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor:outputFD,queue:readQueue)
        reader = source
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }
    private func drain() {
        lock.lock(); defer { lock.unlock() }
        var chunk = [UInt8](repeating:0,count:16_384)
        for _ in 0..<16 {
            let count = Darwin.read(outputPipe.fileHandleForReading.fileDescriptor,&chunk,chunk.count)
            if count == 0 { eof = true; reader?.cancel(); break }
            if count < 0 { break }
            bytes.append(contentsOf:chunk.prefix(count))
            if bytes.count > 64_000 { let extra = bytes.count - 64_000; bytes.removeFirst(extra); dropped += extra }
        }
    }
    func poll() {
        drain()
        guard exitCode == nil else { return }
        var status: Int32 = 0
        if waitpid(pid,&status,WNOHANG) == pid { exitCode = status & 0x7f == 0 ? Int((status >> 8) & 0xff) : 128 + Int(status & 0x7f) }
    }
    func snapshot() -> [String:Any] {
        poll(); lock.lock(); let text = String(decoding:bytes,as:UTF8.self), omitted = dropped; lock.unlock()
        var result: [String:Any] = ["shell_id":String(id),"status":exitCode == nil ? "running" : "exited","output":text,"omitted_bytes":omitted]
        if let exitCode { result["exit_code"] = exitCode }
        return result
    }
    func write(_ text:String) throws {
        poll(); guard exitCode == nil else { throw AgentFailure("命令已退出。") }
        let data = Array(text.utf8); guard data.count <= 4096 else { throw AgentFailure("每次 stdin 输入最多 4096 字节。") }
        let sent = data.withUnsafeBytes { Darwin.write(inputPipe.fileHandleForWriting.fileDescriptor,$0.baseAddress,$0.count) }
        guard sent == data.count else { throw AgentFailure("stdin 未完整写入（\(max(0,sent))/\(data.count) 字节），请先读取命令状态。") }
    }
    func stop() {
        guard !closed else { return }; closed = true
        poll()
        lock.lock(); let outputClosed = eof; lock.unlock()
        // Never signal a completed, drained command's old process-group ID after it could be reused.
        if exitCode == nil || !outputClosed { _ = kill(-pid,SIGKILL) }
        poll()
        if exitCode == nil {
            let child = pid
            DispatchQueue.global().async { var status: Int32 = 0; _ = waitpid(child,&status,0) }
            exitCode = 137
        }
        inputPipe.fileHandleForWriting.closeFile()
    }
    deinit { stop(); reader?.cancel(); outputPipe.fileHandleForReading.closeFile() }
}
