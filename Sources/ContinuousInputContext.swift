import Foundation
import InputMethodKit

/// One focus lifetime, no document history. A dirty stream stays disabled until
/// a new activation; even then it needs a new, verified Chinese confirmation.
@MainActor
final class ContinuousInputContext {
    private(set) var dirty = false
    private(set) var reason = "new-focus"
    private var client: (any IMKTextInput)?
    private var identity: String?
    private var bundle = ""
    private var prefix = ""
    private var anchor: Int?
    private var selection = NSRange(location:0,length:0)
    private var markedLength = 0
    private var confirmed = false

    func reset() {
        dirty = false; reason = "new-focus"; client = nil; identity = nil
        prefix = ""; anchor = nil; confirmed = false; markedLength = 0
    }
    func invalidate(_ why:String) {
        dirty = true; reason = why; prefix = ""; confirmed = false
        client = nil; identity = nil; bundle = ""; anchor = nil; markedLength = 0
    }
    func read(_ current:any IMKTextInput, hasComposition:Bool) -> String? {
        guard !dirty else { return nil }
        if let client {
            guard bundle == current.bundleIdentifier(),
                  (client as AnyObject) === (current as AnyObject) ||
                    (identity != nil && identity == current.uniqueClientIdentifierString()) else {
                invalidate("different-client"); return nil
            }
            if let identity, identity != current.uniqueClientIdentifierString() { invalidate("different-field"); return nil }
        }
        let value = SurroundingContext.read(current,hasComposition:hasComposition)
        guard let text = value.prefix, let range = value.range else {
            invalidate(value.prefix == nil ? value.status : "selection"); return nil
        }
        if let anchor {
            let actualMarkedLength = SurroundingContext.valid(value.marked) ? value.marked.length : 0
            // IMK's AppKit adapter can report the entire marked range as the
            // selection. Accept only our exact, still-at-end composition in
            // that representation; navigation events invalidate the stream.
            let markedSelection = markedLength > 0 && value.selection == value.marked &&
                value.marked == NSRange(location:anchor,length:markedLength) && selection.location == anchor+markedLength
            guard NSMaxRange(range) == anchor, (value.selection == selection || markedSelection),
                  actualMarkedLength == markedLength, prefix.hasSuffix(text) else {
                invalidate("caret-or-text-changed"); return nil
            }
        } else {
            guard value.selection.length == 0, !hasComposition, !(SurroundingContext.valid(value.marked) && value.marked.length > 0) else {
                invalidate("existing-composition"); return nil
            }
            anchor = NSMaxRange(range); selection = value.selection
            client = current; bundle = current.bundleIdentifier() ?? ""
            if let first = current.uniqueClientIdentifierString(), !first.isEmpty,
               first == current.uniqueClientIdentifierString() { identity = first }
        }
        prefix = text
        reason = confirmed ? "continuous-input" : "awaiting-confirmation"
        return confirmed ? text : nil
    }
    func willInsert(_ text:String) {
        guard !dirty, let anchor else { return }
        prefix += text; prefix = String(prefix.suffix(128))
        self.anchor = anchor + text.utf16.count
        selection = NSRange(location:self.anchor!,length:0); markedLength = 0
        if text.contains(where:{ ContextRanking.isChinese(String($0)) }) { confirmed = true }
    }
    func confirmedDraft(_ text:String) {
        guard !dirty, anchor != nil else { return }
        if text.contains(where:{ ContextRanking.isChinese(String($0)) }) { confirmed = true }
    }
    func expectComposition(_ text:String,caret:Int) {
        guard !dirty, let anchor else { return }
        selection = NSRange(location:anchor+caret,length:0)
        markedLength = text.utf16.count
    }
}
