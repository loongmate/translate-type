import Foundation
import Darwin

struct InstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Only replaces this product's application bundle. User data lives elsewhere.
final class InstallTransaction {
    struct Locations {
        let inputMethods: URL
        let support: URL
        let systemInputMethods: URL
        static var currentUser: Locations {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Locations(inputMethods:home.appendingPathComponent("Library/Input Methods"),
                support:home.appendingPathComponent("Library/Application Support/FangCun/Installer"),
                systemInputMethods:URL(fileURLWithPath:"/Library/Input Methods"))
        }
    }
    static let bundleID = "com.translatetype.inputmethod.TranslateType"
    private static let acceptedIDs = [bundleID,"com.fangcun.inputmethod.FangCun","com.apple.inputmethod.translatetype"]
    private static let names = ["FangCun.app","方寸输入法.app","TranslateType.app"]
    private(set) var destination: URL
    private(set) var previous: URL?
    let backup: URL
    let staging: URL
    private let fileManager: FileManager
    private var lock: Int32 = -1
    private var backedUp = false
    private var replaced = false

    static func info(at url:URL) throws -> [String:Any] {
        let data = try Data(contentsOf:url.appendingPathComponent("Contents/Info.plist"))
        guard let value = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else {
            throw InstallFailure(message:"无法读取应用信息。请重新下载完整安装包。")
        }
        return value
    }
    static func isOurApplication(at url:URL) -> Bool {
        guard let info = try? info(at:url), let id = info["CFBundleIdentifier"] as? String else { return false }
        return acceptedIDs.contains(id)
    }
    init(locations:Locations = .currentUser,fileManager:FileManager = .default) throws {
        self.fileManager = fileManager
        destination = locations.inputMethods.appendingPathComponent("FangCun.app")
        let token = UUID().uuidString
        backup = locations.support.appendingPathComponent("Backups/\(token).snapshot")
        staging = locations.inputMethods.appendingPathComponent(".FangCun-\(token).installing")
        try fileManager.createDirectory(at:locations.support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let descriptor = Darwin.open(locations.support.appendingPathComponent("install.lock").path,O_CREAT|O_RDWR,0o600)
        guard descriptor >= 0 else { throw InstallFailure(message:"无法创建安装锁，请检查当前账户的文件权限。") }
        guard flock(descriptor,LOCK_EX|LOCK_NB) == 0 else {
            close(descriptor)
            throw InstallFailure(message:"另一个方寸安装程序正在运行，请完成后再试。")
        }
        lock = descriptor
        do {
            let systemCopies = Self.names.map { locations.systemInputMethods.appendingPathComponent($0) }
                .filter { Self.isOurApplication(at:$0) }
            guard systemCopies.isEmpty else {
                throw InstallFailure(message:"检测到为所有用户安装的方寸输入法。为避免产生两个副本，请先移除原系统级应用，再运行此安装器。现有安装未改动。")
            }
            let candidates = Self.names.map { locations.inputMethods.appendingPathComponent($0) }
                .filter { fileManager.fileExists(atPath:$0.path) }
            for candidate in candidates {
                let values = try candidate.resourceValues(forKeys:[.isSymbolicLinkKey])
                guard values.isSymbolicLink != true, Self.isOurApplication(at:candidate) else {
                    throw InstallFailure(message:"输入法目录中已有同名文件或非方寸应用，安装已停止。请先检查 \(candidate.path)。")
                }
            }
            guard candidates.count <= 1 else {
                throw InstallFailure(message:"输入法目录中有多个方寸副本，请先保留一个，再重新安装。现有副本未改动。")
            }
            previous = candidates.first
            // Retain an existing installation's path, including legacy names:
            // moving it away can invalidate the system's input-source cache.
            if let previous { destination = previous }
        } catch {
            flock(lock,LOCK_UN); close(lock); lock = -1
            throw error
        }
    }
    deinit {
        try? fileManager.removeItem(at:staging)
        if lock >= 0 { flock(lock,LOCK_UN); close(lock) }
    }
    func stage(payload:URL,verify:(URL)throws->Void) throws {
        let info = try Self.info(at:payload)
        guard info["CFBundleIdentifier"] as? String == Self.bundleID,
              info["CFBundleExecutable"] as? String == "TranslateType",
              fileManager.isExecutableFile(atPath:payload.appendingPathComponent("Contents/MacOS/TranslateType").path) else {
            throw InstallFailure(message:"安装包中的应用不完整，请重新下载。")
        }
        try verify(payload)
        try fileManager.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fileManager.copyItem(at:payload,to:staging)
        try verify(staging)
    }
    private static func rename(_ source:URL,_ target:URL,flags:UInt32) throws {
        guard renameatx_np(AT_FDCWD,source.path,AT_FDCWD,target.path,flags) == 0 else {
            let reason = String(cString:strerror(errno))
            throw InstallFailure(message:"无法原子替换输入法应用：\(reason)。现有安装保留，请重试。")
        }
    }
    func replace() throws {
        guard !replaced, fileManager.fileExists(atPath:staging.path) else { throw InstallFailure(message:"安装文件尚未准备好。") }
        if let previous {
            try fileManager.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            // Copy the backup while the installed path remains present. After
            // the swap, staging retains the old directory for atomic rollback.
            try fileManager.copyItem(at:previous,to:backup)
            backedUp = true
            do { try Self.rename(staging,destination,flags:UInt32(RENAME_SWAP)) }
            catch {
                try? fileManager.removeItem(at:backup); backedUp = false
                throw error
            }
        } else {
            // Do not overwrite an installation created after the initial check.
            try Self.rename(staging,destination,flags:UInt32(RENAME_EXCL))
        }
        replaced = true
    }
    func rollback() throws {
        if replaced {
            if previous != nil {
                // Keep the registered path continuously present on failure too.
                do { try Self.rename(staging,destination,flags:UInt32(RENAME_SWAP)) }
                catch { throw InstallFailure(message:"旧版备份保留在 \(backup.path)，但无法自动恢复：\(error.localizedDescription)") }
            } else { try fileManager.removeItem(at:destination) }
            replaced = false
        }
        if backedUp {
            try fileManager.removeItem(at:backup)
            backedUp = false
        }
    }
}
