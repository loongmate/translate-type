import Foundation

/// Small local phrase lookup, using the same licensed lexicon as the decoder.
/// It can promote an existing candidate, never invent or auto-commit a word.
final class ContextRanking {
    private var words: [String:Int] = [:]
    init(dictionary: URL) {
        guard let text = try? String(contentsOf:dictionary,encoding:.utf8) else { return }
        for line in text.split(separator:"\n") {
            let fields = line.split(separator:"\t")
            guard fields.count >= 3, (2...8).contains(fields[0].count),
                  let weight = Int(fields[2]), weight >= 100,
                  Self.isChinese(String(fields[0])) else { continue }
            let word = String(fields[0]); words[word] = max(words[word] ?? 0,weight)
        }
    }
    static func isChinese(_ text:String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value) }
    }
    func preferred(prefix:String,candidates:[String]) -> Int? {
        let tail = String(prefix.reversed().prefix(while:{ Self.isChinese(String($0)) }).reversed().suffix(7))
        guard !tail.isEmpty, !candidates.isEmpty else { return nil }
        // A known word boundary is stronger evidence than its last character:
        // 墙上 / 皇上 must not borrow the 上海 association from a trailing 上.
        var boundary = 1
        if tail.count >= 2 {
            for size in 2...tail.count where words[String(tail.suffix(size))] != nil { boundary = size }
        }
        var scores = Array(repeating:0,count:candidates.count)
        for (index,candidate) in candidates.enumerated() where Self.isChinese(candidate) {
            for size in boundary...tail.count {
                scores[index] = max(scores[index],words[String(tail.suffix(size))+candidate] ?? 0)
            }
        }
        guard let best = scores.indices.max(by:{ scores[$0] < scores[$1] }), best != 0,
              scores[best] >= 1000 else { return nil }
        let runnerUp = scores.enumerated().filter { $0.offset != best }.map(\.element).max() ?? 0
        guard scores[best] >= max(1,runnerUp)*4 else { return nil }
        return best
    }
}
