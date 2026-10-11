import AppKit

// Input methods run without an application menu. Forward standard editing
// shortcuts to the focused text editor in the settings window.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with:event) }
        let modifiers = event.modifierFlags.intersection([.command,.shift,.control,.option])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "z", let undo = firstResponder?.undoManager {
            if modifiers == [.command], undo.canUndo { undo.undo(); return true }
            if modifiers == [.command,.shift], undo.canRedo { undo.redo(); return true }
        }
        let action: Selector?
        if modifiers == [.command] {
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            default: action = nil
            }
        } else {
            action = nil
        }
        if let action, NSApp.sendAction(action,to:nil,from:self) { return true }
        return super.performKeyEquivalent(with:event)
    }
}
