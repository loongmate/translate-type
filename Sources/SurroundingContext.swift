import Foundation
import InputMethodKit

/// A fresh, bounded view of text before this client's insertion point. It never
/// treats our commit history or an application ID as the document's contents.
@MainActor
enum SurroundingContext {
    struct Snapshot {
        let prefix: String?
        let range: NSRange?
        let status: String
        let selection: NSRange
        let marked: NSRange
    }
    static func valid(_ range:NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length >= 0
            && range.length != NSNotFound && range.length <= Int.max-range.location
    }
    static func read(_ client:any IMKTextInput, hasComposition:Bool = false, limit:Int = 64) -> Snapshot {
        let selection = client.selectedRange(), marked = client.markedRange()
        func result(_ status:String,_ text:String? = nil,_ range:NSRange? = nil) -> Snapshot {
            Snapshot(prefix:text,range:range,status:status,selection:selection,marked:marked)
        }
        guard valid(selection) else { return result("selection-unavailable") }
        let anchor:Int
        if valid(marked), marked.length > 0 {
            guard selection.location >= marked.location, NSMaxRange(selection) <= NSMaxRange(marked) else {
                return result("selection-outside-composition")
            }
            anchor = marked.location // Exclude all uncommitted text, including its pinyin.
        } else {
            guard !hasComposition else { return result("composition-range-unavailable") }
            anchor = selection.location // A selection will be replaced at its start.
        }
        let budget = min(max(limit,1),256)
        let request = NSRange(location:max(0,anchor-budget),length:min(anchor,budget))
        var actual = NSRange(location:NSNotFound,length:NSNotFound)
        var prefix:String?
        var usedRange = request
        var method = "empty-prefix"
        if request.length == 0 { prefix = "" }
        else if let value = client.string(from:request,actualRange:&actual), valid(actual),
                actual.length == (value as NSString).length,
                actual.location <= request.location, NSMaxRange(actual) >= anchor,
                actual.length <= budget+2 {
            // Some clients expand a query at a UTF-16 surrogate boundary.
            // Retain that expanded start so an emoji is never cut in half.
            usedRange = NSRange(location:actual.location,length:anchor-actual.location)
            prefix = (value as NSString).substring(with:NSRange(location:0,length:usedRange.length))
            method = "string-range"
        } else if selection.length == 0, let value = client.attributedSubstring(from:request), value.length == request.length {
            prefix = value.string; method = "attributed-range"
        }
        guard let prefix else { return result("text-unavailable-or-unanchored") }
        // Detect a caret/composition change during the cross-process reads.
        guard client.selectedRange() == selection, client.markedRange() == marked else {
            return result("changed-during-read")
        }
        return result(method,prefix,usedRange)
    }
}
