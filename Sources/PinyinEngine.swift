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
    private var literalInput: String?
    private var literalCaret = 0
    var isLiteralInput: Bool { literalInput != nil }
    private var periodSuffix: String?
    var hasPendingPeriod: Bool { periodSuffix != nil }
    private static let domainSuffixes = ["com", "cn", "net", "org"]
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
        guard !isLiteralInput, !hasPendingPeriod else { return }
        manualHighlight = false; contextSuppressed = true
        _ = TTHighlightCandidate(id,0)
    }
    func setContext(_ prefix:String?,preserveHighlight:Bool = false) {
        guard contextPrefix != prefix else { return }
        contextPrefix = prefix
        if prefix == nil {
            contextActive = false
            if !manualHighlight && !preserveHighlight && !hasPendingPeriod { _ = TTHighlightCandidate(id,0) }
            mapping = []
        }
    }
    func process(_ key: Int, modifiers: Int = 0) -> (Bool, PinyinSnapshot) {
        if isLiteralInput { return processLiteral(key) }
        if let suffix = periodSuffix { return processPendingPeriod(key, modifiers:modifiers, suffix:suffix) }
        if key == 46 && modifiers == 0 && lastState.selectionStart == 0 &&
            lastState.caret == lastState.preedit.utf16.count && !lastState.input.isEmpty &&
            lastState.input.utf8.allSatisfy(Self.isASCIILetter) {
            let domain = lastState.input + "."
            if domain.lowercased() == "www." { return (true,beginDomain(domain)) }
            // Keep Rime's composition intact until we know whether this is a sentence boundary.
            _ = snapshot()
            periodSuffix = ""
            contextActive = false
            return (true,snapshot())
        }
        return processPinyin(key, modifiers:modifiers)
    }
    private func processPinyin(_ key: Int, modifiers: Int) -> (Bool, PinyinSnapshot) {
        if startsLiteralFragment(key), !lastState.input.isEmpty {
            // Symbols without a Chinese punctuation mapping start a literal
            // fragment. Chinese punctuation must reach Rime so it confirms the
            // selected candidate instead of turning the pinyin back into Latin.
            let rawLength = lastState.input.utf16.count
            let rawCaret = Int(TTMoveCaretToEnd(id))
            _ = TTProcessKey(id, 0xff0d, 0)
            let text = snapshot().commit
            clear()
            literalInput = text
            literalCaret = min(max(0,rawCaret + text.utf16.count - rawLength),text.utf16.count)
            return processLiteral(key)
        }
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
    private static func isASCIILetter(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }
    private func beginDomain(_ text: String) -> PinyinSnapshot {
        clear()
        literalInput = text
        literalCaret = text.utf16.count
        return snapshot()
    }
    private func processPendingPeriod(_ key: Int, modifiers: Int, suffix: String) -> (Bool, PinyinSnapshot) {
        if key == 0xff08 {
            periodSuffix = suffix.isEmpty ? nil : String(suffix.dropLast())
            return (true,snapshot())
        }
        if let byte = UInt8(exactly:key), Self.isASCIILetter(byte) {
            let extended = suffix + String(UnicodeScalar(byte))
            let lowercase = extended.lowercased()
            if Self.domainSuffixes.contains(lowercase) {
                return (true,beginDomain(lastState.input + "." + extended))
            }
            if Self.domainSuffixes.contains(where:{ $0.hasPrefix(lowercase) }) {
                periodSuffix = extended
                return (true,snapshot())
            }
        }
        let resolved = resolvePeriod()
        if key == 32 && resolved.input.isEmpty { return (true,resolved) }
        let (handled,next) = process(key, modifiers:modifiers)
        var state = next
        state.commit = resolved.commit + state.commit
        return (handled,state)
    }
    private func resolvePeriod(preserveSuffix: Bool = false) -> PinyinSnapshot {
        guard let suffix = periodSuffix else { return snapshot() }
        periodSuffix = nil
        var state = processPinyin(46, modifiers:0).1
        // Replay in the new sentence, before the host can supply a fresh prefix.
        setContext(nil)
        if preserveSuffix {
            state.commit += suffix
            return state
        }
        var committed = state.commit
        for byte in suffix.utf8 {
            state = processPinyin(Int(byte), modifiers:(65...90).contains(byte) ? 1 : 0).1
            committed += state.commit
        }
        state.commit = committed
        return state
    }
    private func startsLiteralFragment(_ key:Int) -> Bool {
        let symbol = (33...47).contains(key) || (58...64).contains(key) ||
            (91...96).contains(key) || (123...126).contains(key)
        // These keys have explicit input-method roles. Once a literal fragment
        // has begun, processLiteral accepts them as ordinary text instead.
        guard symbol, ![39,43,45,61].contains(key) else { return false }
        if key == 59 && [.sogou,.microsoft,.ziguang].contains(layout) { return false }
        if Self.chinesePunctuationKeys.contains(key) { return false }
        return true
    }
    // Keep in sync with punctuator.half_shape in the generated Rime schemas.
    // Apostrophe remains a syllable separator while composing pinyin.
    private static let chinesePunctuationKeys = Set("!\"(),./:;<>?[\\]".unicodeScalars.map { Int($0.value) })
    func select(_ index: Int) -> PinyinSnapshot {
        if isLiteralInput { return index == 0 ? commit() : snapshot() }
        if hasPendingPeriod { return index == 0 ? commit(preservePeriodSuffix:true) : snapshot() }
        let native = mapping.indices.contains(index) ? mapping[index] : index
        _ = TTSelectCandidate(id,Int32(native)); return snapshot()
    }
    func commit(preservePeriodSuffix: Bool = false) -> PinyinSnapshot {
        if let text = literalInput {
            clear()
            var state = PinyinSnapshot.empty; state.commit = text
            return state
        }
        let prefix = hasPendingPeriod ? resolvePeriod(preserveSuffix:preservePeriodSuffix).commit : ""
        TTCommitComposition(id)
        var state = snapshot()
        state.commit = prefix + state.commit
        return state
    }
    func clear() { TTClearComposition(id); literalInput = nil; literalCaret = 0; periodSuffix = nil; lastInput = ""; mapping = []; lastState = .empty; contextActive = false }
    private func processLiteral(_ key:Int) -> (Bool,PinyinSnapshot) {
        guard let text = literalInput else { return (false,snapshot()) }
        let value = text as NSString
        switch key {
        case 32,0xff0d,0xff09: return (true,commit())
        case 0xff08:
            if literalCaret > 0 {
                let range = value.rangeOfComposedCharacterSequence(at:literalCaret-1)
                literalInput = value.replacingCharacters(in:range,with:"")
                literalCaret = range.location
            }
        case 0xffff:
            if literalCaret < value.length {
                literalInput = value.replacingCharacters(in:value.rangeOfComposedCharacterSequence(at:literalCaret),with:"")
            }
        case 0xff51:
            if literalCaret > 0 { literalCaret = value.rangeOfComposedCharacterSequence(at:literalCaret-1).location }
        case 0xff53:
            if literalCaret < value.length { literalCaret = NSMaxRange(value.rangeOfComposedCharacterSequence(at:literalCaret)) }
        case 0xff50: literalCaret = 0
        case 0xff57: literalCaret = value.length
        case 0xff52,0xff54,0xff55,0xff56: break
        case 0xff1b: clear(); return (true,snapshot())
        case 33...126:
            literalInput = value.replacingCharacters(in:NSRange(location:literalCaret,length:0),with:String(UnicodeScalar(key)!))
            literalCaret += 1
        default: return (false,snapshot())
        }
        if literalInput?.isEmpty == true { clear() }
        return (true,snapshot())
    }
    func snapshot() -> PinyinSnapshot {
        if let suffix = periodSuffix {
            let text = lastState.preview + "。" + suffix
            let length = text.utf16.count
            return PinyinSnapshot(preedit:text,input:lastState.input + "." + suffix,preview:text,caret:length,
                                  selectionStart:0,selectionEnd:length,candidates:[text],highlighted:0,page:0,lastPage:true,commit:"")
        }
        if let text = literalInput {
            contextActive = false; mapping = [0]
            let state = PinyinSnapshot(preedit:text,input:text,preview:text,caret:literalCaret,selectionStart:0,selectionEnd:text.utf16.count,candidates:[text],highlighted:0,page:0,lastPage:true,commit:"")
            lastState = state
            return state
        }
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
