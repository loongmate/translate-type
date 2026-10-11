import AppKit
import InputMethodKit

// Bounded, local metadata only: never record text, keystrokes, clipboard or keys.
@MainActor
enum EditorDiagnostics {
    static func record(_ event:String, _ fields:[String:Any] = [:]) {
        guard Bundle.main.bundleIdentifier == InputSourceStatus.bundleID else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FangCun")
        let file = folder.appendingPathComponent("editor-focus.jsonl")
        var row = fields
        row["event"] = event; row["time"] = ISO8601DateFormatter().string(from:Date())
        row["build"] = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "?"
        row["frontApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard var data = try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) else { return }
        data.append(10)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if let size = try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize, size > 131_072 {
                let previous = folder.appendingPathComponent("editor-focus.previous.jsonl")
                try? FileManager.default.removeItem(at:previous)
                try FileManager.default.moveItem(at:file,to:previous)
            }
            if !FileManager.default.fileExists(atPath:file.path) {
                FileManager.default.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600])
            }
            let handle = try FileHandle(forWritingTo:file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf:data)
        } catch { /* Diagnostics must never prevent typing. */ }
    }
}
