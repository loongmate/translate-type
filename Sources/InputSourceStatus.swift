import Foundation
import Carbon

enum InputSourceStatus {
    // Keep the already-enabled system identity stable across branding changes.
    static let bundleID = "com.translatetype.inputmethod.TranslateType"
    static let modeID = bundleID + ".Hans"
    static let legacyBundleIDs = ["com.fangcun.inputmethod.FangCun", "com.apple.inputmethod.translatetype"]

    struct RegistrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func identifier(_ source: TISInputSource) -> String {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
    static func sources(includeDisabled: Bool = true) -> [TISInputSource] {
        TISCreateInputSourceList(nil, includeDisabled).takeRetainedValue() as! [TISInputSource]
    }
    static var currentID: String { identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) }
    static func isLegacy(_ id: String) -> Bool {
        legacyBundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
    static var isAvailable: Bool {
        let enabled = sources(includeDisabled: false)
        return enabled.contains { identifier($0) == bundleID && flag($0, kTISPropertyInputSourceIsEnabled) }
            && enabled.contains {
            identifier($0) == modeID && flag($0, kTISPropertyInputSourceIsEnabled)
                && flag($0, kTISPropertyInputSourceIsSelectCapable)
        }
    }
    static func register(at url: URL) throws {
        let status = TISRegisterInputSource(url as CFURL)
        guard status == noErr else { throw RegistrationError(message: "注册失败（\(status)），请先安装应用到输入法目录。") }
    }
    /// Retire old identities only after the replacement is enabled and selectable.
    static func enable(at url: URL = Bundle.main.bundleURL, replacingCurrentID: String? = nil) throws {
        let previousID = replacingCurrentID ?? currentID
        try register(at: url)
        for id in [bundleID, modeID] {
            guard let source = sources().first(where: { identifier($0) == id }) else {
                throw RegistrationError(message: "系统尚未识别方寸输入法，请重新登录后再添加。")
            }
            if !flag(source, kTISPropertyInputSourceIsEnabled) {
                let status = TISEnableInputSource(source)
                guard status == noErr else { throw RegistrationError(message: "系统未能启用方寸输入法（\(status)）。") }
            }
        }
        guard isAvailable else {
            throw RegistrationError(message: "macOS 未自动启用方寸输入法。请打开系统键盘设置，在「编辑 → ＋ → 简体中文」添加「方寸输入法」。旧输入法仍保留。")
        }
        try finishMigration(replacingCurrentID: previousID)
    }
    static func finishMigration(replacingCurrentID: String? = nil) throws {
        guard isAvailable else { return }
        let previousID = replacingCurrentID ?? currentID
        if isLegacy(previousID) {
            let replacement = sources(includeDisabled: false).first { identifier($0) == modeID }!
            let status = TISSelectInputSource(replacement)
            guard status == noErr else { throw RegistrationError(message: "切换到方寸输入法失败（\(status)），旧输入源暂时保留。") }
        }
        // Disable modes before their parents. Never modify other vendors' sources.
        let legacy = sources().filter { isLegacy(identifier($0)) }
            .sorted { identifier($0).count > identifier($1).count }
        for source in legacy where flag(source, kTISPropertyInputSourceIsEnabled) {
            let status = TISDisableInputSource(source)
            guard status == noErr else { throw RegistrationError(message: "方寸已启用，但移除旧输入源失败（\(status)）。") }
        }
        guard !sources(includeDisabled: false).contains(where: { isLegacy(identifier($0)) }) else {
            throw RegistrationError(message: "方寸已启用，系统尚未移除旧输入源。")
        }
    }
}
