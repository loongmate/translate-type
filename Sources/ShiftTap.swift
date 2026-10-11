import Foundation

// Only a short press/release of the same physical Shift key switches language.
struct ShiftTap {
    private var pressedKey: UInt16?
    private var pressedAt: TimeInterval = 0
    private var eligible = false
    mutating func keyDown() { eligible = false }
    mutating func reset() { pressedKey = nil; eligible = false }
    mutating func flagsChanged(shift: Bool, otherModifier: Bool, keyCode: UInt16 = 56,
                               timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard keyCode == 56 || keyCode == 60 else {
            // A modifier chord can be intercepted by macOS before its keyDown
            // reaches the input method. Its flagsChanged still cancels the tap.
            eligible = false
            return false
        }
        if shift {
            if pressedKey == nil {
                pressedKey = keyCode; pressedAt = timestamp; eligible = !otherModifier
            } else { eligible = false }
            return false
        }
        let duration = timestamp - pressedAt
        let toggle = pressedKey == keyCode && eligible && !otherModifier && duration >= 0 && duration <= 0.5
        reset()
        return toggle
    }
}
