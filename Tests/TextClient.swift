import AppKit
import InputMethodKit
import Carbon

// Real NSTextView editing, with the same protocol boundary an IMK client uses.
final class TextClient: NSObject, IMKTextInput {
    var identity: String
    var bundleID: String
    var generatesIdentity = false
    var reportsMarkedSelection = false
    var selectionOverride: NSRange?
    var lengthOverride: Int?
    var markedOverride: NSRange?
    var substringUnavailable = false
    var stringHandler: ((NSRange,inout NSRange)->String?)?
    var contextReadHook: (() -> Void)?
    var lengthQueries = 0
    var deferEmptyChanges = false
    var canDeliverInsertion: (() -> Bool)?
    private var pendingChanges: [() -> Void] = []
    var pendingChangeCount: Int { pendingChanges.count }
    var insertedRanges: [NSRange] = []
    var selectedModes: [String] = []
    let text: NSTextView
    init(text:NSTextView = NSTextView(frame:NSRect(x:0,y:0,width:600,height:200)),identity:String = UUID().uuidString,bundleID:String = "com.fangcun.ControllerTests") {
        self.text = text; self.identity = identity; self.bundleID = bundleID; super.init()
    }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        let change = { self.insertedRanges.append(replacementRange); self.text.insertText(string as Any,replacementRange:replacementRange) }
        if (deferEmptyChanges && (string as? String) == "") || canDeliverInsertion?() == false { pendingChanges.append(change) }
        else { change() }
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let change = { self.text.setMarkedText(string as Any,selectedRange:selectionRange,replacementRange:replacementRange) }
        if deferEmptyChanges && (string as? String) == "" { pendingChanges.append(change) }
        else { change() }
    }
    func deliverPendingChanges() {
        let changes = pendingChanges; pendingChanges.removeAll()
        changes.forEach { $0() }
    }
    func selectedRange() -> NSRange { selectionOverride ?? (reportsMarkedSelection && text.hasMarkedText() ? text.markedRange() : text.selectedRange()) }
    func markedRange() -> NSRange { markedOverride ?? text.markedRange() }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { substringUnavailable ? nil : text.attributedSubstring(forProposedRange:range,actualRange:nil) }
    func length() -> Int { lengthQueries += 1; return lengthOverride ?? text.string.utf16.count }
    func characterIndex(for point:NSPoint, tracking:IMKLocationToOffsetMappingMode, inMarkedRange:UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index:Int, lineHeightRectangle rect:UnsafeMutablePointer<NSRect>!) -> [AnyHashable:Any]! { rect.pointee = NSRect(x:100,y:300,width:1,height:20); return [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed name:String!) {}
    func selectMode(_ identifier:String!) { if let identifier { selectedModes.append(identifier) } }
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { bundleID }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property:TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { generatesIdentity ? ProcessInfo.processInfo.globallyUniqueString : identity }
    func string(from range:NSRange, actualRange:UnsafeMutablePointer<NSRange>!) -> String! {
        defer { contextReadHook?() }
        if let stringHandler { return stringHandler(range,&actualRange.pointee) }
        guard !substringUnavailable else { return nil }
        return text.attributedSubstring(forProposedRange:range,actualRange:actualRange)?.string
    }
    func firstRect(forCharacterRange range:NSRange, actualRange:UnsafeMutablePointer<NSRange>!) -> NSRect { .zero }
}
