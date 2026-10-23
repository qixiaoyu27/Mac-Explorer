import AppKit
import ExplorerCore

struct ExplorerShortcut {
  let id: String
  let title: String
  let defaults: [String]
}

enum ExplorerShortcuts {
  static var actions: [ExplorerShortcut] { [
    .init(id: "rename", title: NL("重命名"), defaults: ["Enter", "F2"]),
    .init(id: "open", title: NL("打开项目"), defaults: ["Command+O", "Command+Down"]),
    .init(id: "copy", title: NL("复制"), defaults: ["Command+C", "Control+C"]),
    .init(id: "cut", title: NL("剪切"), defaults: ["Command+X", "Control+X"]),
    .init(id: "paste", title: NL("粘贴"), defaults: ["Command+V", "Control+V"]),
    .init(id: "undo", title: NL("撤销"), defaults: ["Command+Z", "Control+Z"]),
    .init(id: "redo", title: NL("重做"), defaults: ["Command+Shift+Z", "Control+Y"]),
    .init(id: "move-here", title: NL("移动已复制的文件"), defaults: ["Command+Alt+V"]),
    .init(id: "duplicate", title: NL("创建副本"), defaults: ["Command+D"]),
    .init(id: "select-all", title: NL("全选"), defaults: ["Command+A", "Control+A"]),
    .init(id: "new-folder", title: NL("新建文件夹"), defaults: ["Command+Shift+N", "Control+Shift+N"]),
    .init(id: "trash", title: NL("移到回收站"), defaults: ["Command+Backspace", "Command+Delete"]),
    .init(id: "quick-look", title: NL("快速查看"), defaults: ["Space", "Command+Y"]),
    .init(id: "back", title: NL("后退"), defaults: ["Command+[", "Alt+Left"]),
    .init(id: "forward", title: NL("前进"), defaults: ["Command+]", "Alt+Right"]),
    .init(id: "parent", title: NL("上一级"), defaults: ["Command+Up", "Alt+Up", "Backspace"]),
    .init(id: "address", title: NL("前往文件夹"), defaults: ["Command+Shift+G", "Control+L", "Alt+D"]),
    .init(id: "search", title: NL("搜索文件"), defaults: ["Command+F", "Control+F", "Control+E"]),
    .init(id: "new-tab", title: NL("新建标签页"), defaults: ["Command+T", "Control+T"]),
    .init(id: "close-tab", title: NL("关闭标签页"), defaults: ["Command+W", "Control+W"]),
    .init(id: "next-tab", title: NL("下一个标签页"), defaults: ["Control+Tab"]),
    .init(id: "previous-tab", title: NL("上一个标签页"), defaults: ["Control+Shift+Tab"]),
  ] + (1...8).map { .init(id: "tab-\($0)", title: NL("切换到第 {0} 个标签页", $0), defaults: ["Command+\($0)"]) } + [
    .init(id: "last-tab", title: NL("切换到最后一个标签页"), defaults: ["Command+9"]),
    .init(id: "extra-large-icons", title: NL("超大图标视图"), defaults: ["Control+Shift+1"]),
    .init(id: "icons", title: NL("大图标视图"), defaults: ["Control+Shift+2"]),
    .init(id: "medium-icons", title: NL("中图标视图"), defaults: ["Control+Shift+3"]),
    .init(id: "small-icons", title: NL("小图标视图"), defaults: ["Control+Shift+4"]),
    .init(id: "list", title: NL("列表视图"), defaults: ["Control+Shift+5"]),
    .init(id: "details", title: NL("详细信息视图"), defaults: ["Control+Shift+6"]),
    .init(id: "tiles", title: NL("平铺视图"), defaults: ["Control+Shift+7"]),
    .init(id: "content", title: NL("内容视图"), defaults: ["Control+Shift+8"]),
    .init(id: "preview", title: NL("预览窗格"), defaults: ["Command+Shift+P"]),
    .init(id: "hidden", title: NL("隐藏的项目"), defaults: ["Command+Shift+."]),
    .init(id: "details-pane", title: NL("详细信息窗格"), defaults: ["Command+I", "Control+I", "Alt+Enter"]),
    .init(id: "refresh", title: NL("刷新"), defaults: ["F5", "Control+R"]),
  ] }
  static func bindings(_ id: String, overrides: [String: String]) -> [String] {
    if let value = overrides[id] { return value.isEmpty ? [] : [normalize(value)] }
    let used = Set(overrides.values.map(normalize))
    return (actions.first { $0.id == id }?.defaults ?? []).filter { !used.contains($0) }
  }
  static func key(_ event: NSEvent) -> String { accelerator(event) ?? "" }
  static func canRecordOperation(_ binding: String) -> Bool {
    let parts = binding.components(separatedBy: "+"), key = parts.last ?? ""
    return parts.dropLast().contains(where: { ["Command", "Control", "Alt"].contains($0) }) || ["Enter", "Space", "Backspace", "Delete"].contains(key) || key.range(of: "^F([1-9]|1[0-9]|2[0-4])$", options: .regularExpression) != nil
  }
  static func accelerator(_ event: NSEvent) -> String? {
    let physical: [UInt16: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
      12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
      24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
      36: "Enter", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
      48: "Tab", 49: "Space", 50: "`", 51: "Backspace", 53: "Escape", 65: ".", 67: "*", 69: "Plus", 75: "/", 76: "Enter", 78: "-",
      81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
      64: "F17", 79: "F18", 80: "F19", 90: "F20", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "PageUp", 117: "Delete", 118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up"
    ]
    let key: String
    if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value, scalar >= UInt32(NSF1FunctionKey), scalar <= UInt32(NSF24FunctionKey) { key = "F\(scalar - UInt32(NSF1FunctionKey) + 1)" }
    else if let physical = physical[event.keyCode], physical != "*", physical != "Help" { key = physical }
    else { return nil }
    let flags = event.modifierFlags
    var modifiers: [String] = []
    if flags.contains(.command) { modifiers.append("Command") }
    if flags.contains(.control) { modifiers.append("Control") }
    if flags.contains(.option) { modifiers.append("Alt") }
    if flags.contains(.shift) { modifiers.append("Shift") }
    return normalize((modifiers + [key]).joined(separator: "+"))
  }
  static func match(_ event: NSEvent, overrides: [String: String]) -> String? {
    let binding = key(event)
    return actions.first { bindings($0.id, overrides: overrides).contains(binding) }?.id
  }
  static func normalize(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    for (symbol, name) in [("⌘", "Command+"), ("⌃", "Control+"), ("⌥", "Alt+"), ("⇧", "Shift+")] { text = text.replacingOccurrences(of: symbol, with: name) }
    if text.hasSuffix("++") { text.removeLast(); text += "Plus" }
    var parts = text.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    guard var key = parts.popLast(), !key.isEmpty else { return text }
    let aliases = ["Cmd": "Command", "Meta": "Command", "Ctrl": "Control", "Option": "Alt"]
    parts = parts.map { aliases[$0] ?? $0 }
    let keyAliases = ["Return": "Enter", "↑": "Up", "↓": "Down", "←": "Left", "→": "Right", "⌫": "Backspace", "⌦": "Delete", "␣": "Space"]
    key = keyAliases[key] ?? (key.count == 1 ? key.uppercased() : key)
    if key == "=" && parts.contains("Shift") { key = "Plus" }
    if key == "Plus" { parts.removeAll { $0 == "Shift" } }
    return (["Command", "Control", "Alt", "Shift"].filter { parts.contains($0) } + [key]).joined(separator: "+")
  }
  static func display(_ value: String) -> String {
    let parts = normalize(value).split(separator: "+").map(String.init)
    let modifier = [("Control", "⌃"), ("Alt", "⌥"), ("Shift", "⇧"), ("Command", "⌘")].filter { parts.contains($0.0) }.map(\.1).joined()
    let last = parts.last ?? ""
    let key = ["Enter": "Return", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Backspace": "⌫", "Delete": "⌦", "Plus": "+"][last] ?? last
    return modifier + key
  }
  static func validation(_ value: String, action: String, overrides: [String: String]) -> String? {
    let value = normalize(value); if value.isEmpty { return nil }
    let reserved = ["Command+Shift+H", "Command+Shift+D", "Command+Shift+O", "Command+Alt+L", "Command+Shift+C", "Command+Alt+S", "Command+,", "Command+Q", "Command+H", "Command+Alt+H", "Command+M", "Command+Shift+W", "Command+Control+F", "Command+Space", "Command+Alt+Space", "Control+Space", "Control+Shift+Space", "Command+Tab", "Command+Shift+Tab", "Command+Alt+Escape", "Control+Up", "Control+Down", "Control+Left", "Control+Right", "Command+Shift+3", "Command+Shift+4", "Command+Shift+5"]
    if reserved.contains(value) { return NL("此组合由系统保留") }
    for other in actions where other.id != action {
      if bindings(other.id, overrides: overrides).contains(value) { return NL("已用于“{0}”", other.title) }
    }
    return nil
  }
}
