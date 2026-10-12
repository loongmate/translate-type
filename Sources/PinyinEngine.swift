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
    private static var contextRanking: ContextRanking?
    private var contextPrefix: String?
    private var mapping: [Int] = []
    private var lastState = PinyinSnapshot.empty
    private var manualHighlight = false
    private var contextSuppressed = false
    private(set) var contextActive = false
    let layout: PinyinLayout
    init(layout: PinyinLayout = .fullPinyin) throws {
        self.layout = layout
        id = TTCreateSession(layout.rawValue)
        guard id != 0 else { throw AppError.message("\(layout.name)词库尚未准备好，请重新启动方寸输入法。") }
    }
    deinit { TTDestroySession(id) }
    func prepareForCaretNavigation() {
        manualHighlight = false; contextSuppressed = true
        _ = TTHighlightCandidate(id,0)
    }
    func setContext(_ prefix:String?,preserveHighlight:Bool = false) {
        guard contextPrefix != prefix else { return }
        contextPrefix = prefix
        if prefix == nil {
            contextActive = false
            if !manualHighlight && !preserveHighlight { _ = TTHighlightCandidate(id,0) }
            mapping = []
        }
    }
    func process(_ key: Int, modifiers: Int = 0) -> (Bool, PinyinSnapshot) {
        if lastState.input.isEmpty { contextSuppressed = false; manualHighlight = false }
        if mapping != Array(mapping.indices), !mapping.isEmpty, modifiers == 0 {
            if (49...57).contains(key), mapping.indices.contains(key-49) { return (true,select(key-49)) }
            if [0xff51,0xff53,0xff52,0xff54].contains(key) {
                let step = (key == 0xff51 || key == 0xff52) ? -1 : 1
                let next = lastState.highlighted + step
                manualHighlight = true
                if mapping.indices.contains(next) {
                    _ = TTHighlightCandidate(id,Int32(mapping[next])); return (true,snapshot())
                }
                if next < 0 && key == 0xff52 { return (true,lastState) }
                if next >= mapping.count {
                    if lastState.lastPage { return (true,lastState) }
                    contextSuppressed = true
                    _ = TTProcessKey(id,0xff56,0)
                    _ = TTHighlightCandidate(id,0)
                    return (true,snapshot())
                }
                // Left from the first displayed candidate enters pinyin,
                // regardless of that word's original decoder index.
                contextSuppressed = true; _ = TTHighlightCandidate(id,0)
            }
        }
        if [0xff55,0xff56].contains(key) { contextSuppressed = true }
        if (65...90).contains(key) || (97...122).contains(key) { manualHighlight = false }
        if [0xff51,0xff53,0xff52,0xff54].contains(key) { manualHighlight = true }
        let handled = TTProcessKey(id, Int32(key), Int32(modifiers))
        return (handled, snapshot())
    }
    func select(_ index: Int) -> PinyinSnapshot {
        let native = mapping.indices.contains(index) ? mapping[index] : index
        _ = TTSelectCandidate(id,Int32(native)); return snapshot()
    }
    func commit() -> PinyinSnapshot { TTCommitComposition(id); return snapshot() }
    func clear() { TTClearComposition(id); lastInput = ""; mapping = []; lastState = .empty; contextActive = false }
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
        mapping = Array(state.candidates.indices)
        contextActive = false
        if !contextSuppressed, let prefix = contextPrefix, ContextRanking.isChinese(String(prefix.suffix(1))),
           state.page == 0, state.caret == state.preedit.utf16.count,
           state.selectionStart == 0, !state.candidates.isEmpty, let ranking = Self.contextRanking {
            contextActive = true
            if let preferred = ranking.preferred(prefix:prefix,candidates:state.candidates) {
                mapping.remove(at:preferred); mapping.insert(preferred,at:0)
                if !manualHighlight {
                    _ = TTHighlightCandidate(id,Int32(preferred)); state.highlighted = preferred
                }
                state.candidates = mapping.map { state.candidates[$0] }
                state.highlighted = mapping.firstIndex(of:state.highlighted) ?? 0
            }
        }
        lastState = state
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
        if contextRanking == nil { contextRanking = ContextRanking(dictionary:resources.appendingPathComponent("pinyin_simp.dict.yaml")) }
        try FileManager.default.createDirectory(at:user, withIntermediateDirectories:true)
        guard TTInitializeRime(resources.path, user.path) else { throw AppError.message("拼音引擎初始化失败。") }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
