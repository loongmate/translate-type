import Foundation
struct PinyinSnapshot: Decodable {
    var preedit: String
    var input: String
    var preview: String
    var caret: Int
    var selectionStart: Int
    var selectionEnd: Int
    var candidates: [String]
    var highlighted: Int
    var page: Int
    var lastPage: Bool
    var commit: String
    static let empty = PinyinSnapshot(preedit:"", input:"", preview:"", caret:0, selectionStart:0, selectionEnd:0, candidates:[], highlighted:0, page:0, lastPage:true, commit:"")
}
final class PinyinEngine {
    private var id: UInt
    private var lastInput = ""
    let layout: PinyinLayout
    init(layout: PinyinLayout = .fullPinyin) throws {
        self.layout = layout
        id = TTCreateSession(layout.rawValue)
        guard id != 0 else { throw AppError.message("\(layout.name)词库尚未准备好，请重新启动方寸输入法。") }
    }
    deinit { TTDestroySession(id) }
    func process(_ key: Int, modifiers: Int = 0) -> (Bool, PinyinSnapshot) {
        let handled = TTProcessKey(id, Int32(key), Int32(modifiers))
        return (handled, snapshot())
    }
    func select(_ index: Int) -> PinyinSnapshot { _ = TTSelectCandidate(id, Int32(index)); return snapshot() }
    func commit() -> PinyinSnapshot { TTCommitComposition(id); return snapshot() }
    func clear() { TTClearComposition(id); lastInput = "" }
    func snapshot() -> PinyinSnapshot {
        guard let pointer = TTSnapshot(id) else { return .empty }
        defer { TTFreeString(pointer) }
        guard var state = try? JSONDecoder().decode(PinyinSnapshot.self, from:Data(String(cString:pointer).utf8)) else { return .empty }
        if state.input.rangeOfCharacter(from:.uppercaseLetters) != nil {
            state.candidates = state.candidates.map { Self.preservingLatinCase($0,input:state.input) }
            state.preview = Self.preservingLatinCase(state.preview,input:state.input)
        }
        if lastInput.rangeOfCharacter(from:.uppercaseLetters) != nil {
            state.commit = Self.preservingLatinCase(state.commit,input:lastInput)
        }
        lastInput = state.input
        return state
    }
    private static let latinWord = try! NSRegularExpression(pattern:"[A-Za-z]+")
    private static func preservingLatinCase(_ text:String,input:String)->String {
        let result = NSMutableString(string:text)
        var search = input.startIndex..<input.endIndex
        var replacements: [(NSRange,String)] = []
        for match in latinWord.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
            guard let range = Range(match.range,in:text), let raw = input.range(of:String(text[range]),options:.caseInsensitive,range:search) else { continue }
            let word = String(input[raw])
            if word.rangeOfCharacter(from:.uppercaseLetters) != nil { replacements.append((match.range,word)) }
            search = raw.upperBound..<input.endIndex
        }
        for (range,word) in replacements.reversed() { result.replaceCharacters(in:range,with:word) }
        return result as String
    }
    static func initialize(resources: URL, user: URL) throws {
        try FileManager.default.createDirectory(at:user, withIntermediateDirectories:true)
        guard TTInitializeRime(resources.path, user.path) else { throw AppError.message("拼音引擎初始化失败。") }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
