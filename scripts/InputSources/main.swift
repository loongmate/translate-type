import Foundation
import AppKit
import Carbon
_ = NSApplication.shared
func property(_ source: TISInputSource, _ key: CFString) -> String {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "current" { print(InputSourceStatus.currentID); exit(0) }
if args.first == "prepare-update" {
    let previous = InputSourceStatus.currentID
    if previous == InputSourceStatus.modeID || InputSourceStatus.isLegacy(previous) {
        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard TISSelectInputSource(ascii) == noErr else { fputs("更新前无法切换到备用键盘。\n",stderr); exit(1) }
    }
    print(previous); exit(0)
}
if args.first == "select", args.count > 1 {
    guard let source = InputSourceStatus.sources(includeDisabled:false).first(where: { InputSourceStatus.identifier($0) == args[1] }) else { exit(1) }
    exit(TISSelectInputSource(source) == noErr ? 0 : 1)
}
do {
    if args.first == "register", args.count > 1 {
        try InputSourceStatus.register(at: URL(fileURLWithPath: args[1]))
    } else if args.first == "enable", args.count > 1 {
        try InputSourceStatus.enable(at: URL(fileURLWithPath: args[1]), replacingCurrentID: args.count > 2 ? args[2] : nil)
    }
} catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
var found = false
for source in InputSourceStatus.sources() {
    let id = InputSourceStatus.identifier(source)
    guard id == InputSourceStatus.bundleID || id == InputSourceStatus.modeID || InputSourceStatus.isLegacy(id) else { continue }
    if id == InputSourceStatus.modeID { found = true }
    print("Source: \(id), name=\(property(source, kTISPropertyLocalizedName)), enabled=\(InputSourceStatus.flag(source, kTISPropertyInputSourceIsEnabled)), selectable=\(InputSourceStatus.flag(source, kTISPropertyInputSourceIsSelectCapable))")
}
print("Current: \(InputSourceStatus.currentID)")
if !found { fputs("方寸输入源尚未出现在系统列表中。\n", stderr); exit(2) }
