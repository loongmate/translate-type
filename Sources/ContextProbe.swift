#if CONTEXT_PROBE
import AppKit
import CryptoKit
import InputMethodKit

/// Development-only, explicit sampling. Release builds contain no listener.
/// Reports hashes/ranges, never document text, credentials or clipboard data.
@MainActor
enum ContextProbe {
    static let notification = Notification.Name("com.fangcun.context-probe.sample")
    static var reportURL:URL? {
        guard let i = CommandLine.arguments.firstIndex(of:"--context-probe"), CommandLine.arguments.count > i+1 else { return nil }
        return URL(fileURLWithPath:CommandLine.arguments[i+1])
    }
    static func sample(_ notice:Notification,client:any IMKTextInput,hasComposition:Bool,session:UUID) {
        guard let file = reportURL, let request = notice.userInfo,
              let token = request["token"] as? String, token.count < 100,
              let expectedBundle = request["bundle"] as? String,
              client.bundleIdentifier() == expectedBundle,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundle else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = SurroundingContext.read(client,hasComposition:hasComposition)
        var row:[String:Any] = ["token":token,"bundle":expectedBundle,"session":session.uuidString,
            "status":snapshot.status,"hasComposition":hasComposition,"selection":[snapshot.selection.location,snapshot.selection.length],
            "marked":[snapshot.marked.location,snapshot.marked.length],
            "milliseconds":(ProcessInfo.processInfo.systemUptime-start)*1000]
        if let text = snapshot.prefix {
            row["sha256"] = SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
            row["utf16Length"] = text.utf16.count
        }
        if let range = snapshot.range { row["range"] = [range.location,range.length] }
        guard var data = try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath:file.path) {
            FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600])
        }
        guard let handle = try? FileHandle(forWritingTo:file) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf:data) } catch { }
    }
}
#endif
