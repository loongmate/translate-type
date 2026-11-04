import Foundation

struct ScratchpadDraft: Codable, Equatable {
    var text = ""
    var format = ScratchpadFormat.automatic
    var preview = false
    var filename: String?
}
/// One local scratch document, separate from the AI conversation and any explicitly opened file.
final class ScratchpadStore {
    let url: URL
    private let queue = DispatchQueue(label:"com.fangcun.scratchpad.storage",qos:.utility)
    init(url:URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FangCun/Scratchpad/draft.json")) { self.url = url }
    func load() -> ScratchpadDraft {
        queue.sync {
            guard let data = try? Data(contentsOf:url), data.count <= 16_000_000, let draft = try? JSONDecoder().decode(ScratchpadDraft.self,from:data) else { return ScratchpadDraft() }
            return draft
        }
    }
    func save(_ draft:ScratchpadDraft,completion:@escaping (Bool)->Void) {
        queue.async {
            do {
                let data = try JSONEncoder().encode(draft)
                try FileManager.default.createDirectory(at:self.url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                try data.write(to:self.url,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:self.url.path)
                completion(true)
            } catch { completion(false) }
        }
    }
    func flush() { queue.sync {} }
}
