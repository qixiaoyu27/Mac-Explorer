import AppKit
import Carbon
import ExplorerCore

final class NativeSystemIntegration {
  private let defaults: UserDefaults
  private let onWake: () -> Void
  private var handler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?
  private var nextID: UInt32 = 1
  private(set) var wakeShortcut = ""
  private(set) var wakeError = ""
  let fileViewer: NativeFileViewer
  let desktop: NativeDesktop
  init(defaults: UserDefaults, onWake: @escaping () -> Void, onOpenDesktopFolder: @escaping (URL) -> Void = { _ in }) {
    self.defaults = defaults; self.onWake = onWake
    let home = ProcessInfo.processInfo.environment["EXPLORER_NATIVE_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    desktop = NativeDesktop(defaults: defaults, directory: home.appendingPathComponent("Desktop"), openFolder: onOpenDesktopFolder)
    let fixtureRoot = ProcessInfo.processInfo.environment["MAC_EXPLORER_NATIVE_SYSTEM_FIXTURE"].map { URL(fileURLWithPath: $0) }
    let folder = fixtureRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mac Explorer Native")
    fileViewer = NativeFileViewer(backupURL: folder.appendingPathComponent("native-file-viewer-backup.plist"), fixture: fixtureRoot?.appendingPathComponent("native-file-viewer-system.plist"), appExists: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    desktop.integration = self
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context -> OSStatus in
      guard let context else { return OSStatus(eventNotHandledErr) }
      Unmanaged<NativeSystemIntegration>.fromOpaque(context).takeUnretainedValue().onWake()
      return noErr
    }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    if result != noErr { wakeError = NL("无法注册全局快捷键。") }
    let saved = defaults.string(forKey: "wakeShortcut") ?? ""
    if !saved.isEmpty { do { try setWakeShortcut(saved) } catch { wakeShortcut = saved; wakeError = error.localizedDescription } }
  }
  deinit { close() }
  func suppressFileViewerPrompt() { defaults.set(true, forKey: NativeFileViewer.promptSuppressedKey) }
  var shouldPromptForFileViewer: Bool {
    fileViewer.shouldPromptAtLaunch(suppressed: defaults.bool(forKey: NativeFileViewer.promptSuppressedKey), bundleID: Bundle.main.bundleIdentifier)
  }
  func close() {
    desktop.close()
    if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    if let handler { RemoveEventHandler(handler); self.handler = nil }
  }
  private var captureDepth = 0
  func captureShortcut(_ active: Bool) {
    if active {
      captureDepth += 1
      if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    } else {
      captureDepth = max(0, captureDepth - 1)
      if captureDepth == 0, !wakeShortcut.isEmpty { do { try setWakeShortcut(wakeShortcut) } catch { wakeError = error.localizedDescription } }
    }
  }
  static func keyBinding(_ value: String) throws -> (UInt32, UInt32)? {
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    let normalized = ExplorerShortcuts.normalize(value), parts = normalized.split(separator: "+").map(String.init)
    var canonicalInput = value.trimmingCharacters(in: .whitespacesAndNewlines)
    for (symbol, modifier) in [("⌘", "Command+"), ("⌃", "Control+"), ("⌥", "Alt+"), ("⇧", "Shift+")] { canonicalInput = canonicalInput.replacingOccurrences(of: symbol, with: modifier) }
    let rawParts = canonicalInput.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard !rawParts.isEmpty, rawParts.count == parts.count, rawParts.dropLast().allSatisfy({ ["Command", "Control", "Alt", "Option", "Shift"].contains($0) }), Set(rawParts).count == rawParts.count, let key = parts.last, parts.dropLast().allSatisfy({ ["Command", "Control", "Alt", "Shift"].contains($0) }) else { throw NativeUpdateValidation.failure("无效的快捷键设置。") }
    let codes: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"O":31,"U":32,"[":33,"I":34,"P":35,"Enter":36,"L":37,"J":38,"'":39,"K":40,";":41,"\\":42,",":43,"/":44,"N":45,"M":46,".":47,"Tab":48,"Space":49,"`":50,"Backspace":51,"Escape":53,"F17":64,"F18":79,"F19":80,"F20":90,"F5":96,"F6":97,"F7":98,"F3":99,"F8":100,"F9":101,"F11":103,"F13":105,"F16":106,"F14":107,"F10":109,"F12":111,"F15":113,"Home":115,"PageUp":116,"Delete":117,"F4":118,"End":119,"F2":120,"PageDown":121,"F1":122,"Left":123,"Right":124,"Down":125,"Up":126]
    guard let code = codes[key], parts.contains(where: { ["Command", "Control", "Alt"].contains($0) }) || key.range(of: "^F[0-9]+$", options: .regularExpression) != nil else { throw NativeUpdateValidation.failure("唤醒快捷键需要包含修饰键。") }
    let reserved = ["Command+Q","Command+H","Command+Alt+H","Command+M","Command+,","Command+Shift+W","Command+Control+F","Command+Shift+C","Command+Shift+H","Command+Shift+D","Command+Shift+O","Command+Alt+L","Command+Alt+S","Command+Space","Command+Alt+Space","Control+Space","Control+Shift+Space","Command+Tab","Command+Shift+Tab","Command+Alt+Escape","Control+Up","Control+Down","Control+Left","Control+Right","Command+Shift+3","Command+Shift+4","Command+Shift+5"]
    guard !reserved.contains(normalized) else { throw NativeUpdateValidation.failure("此组合由系统保留") }
    var modifiers: UInt32 = 0
    for (name, flag) in [("Command", cmdKey), ("Control", controlKey), ("Alt", optionKey), ("Shift", shiftKey)] where parts.contains(name) { modifiers |= UInt32(flag) }
    return (code, modifiers)
  }
  func setWakeShortcut(_ input: String) throws {
    let value = ExplorerShortcuts.normalize(input)
    let binding = try Self.keyBinding(input)
    let overrides = defaults.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
    if !value.isEmpty, let conflict = ExplorerShortcuts.actions.first(where: { ExplorerShortcuts.bindings($0.id, overrides: overrides).contains(value) }) { throw NativeUpdateValidation.failure(NL("已用于“{0}”", conflict.title)) }
    if value == wakeShortcut, hotKey != nil { wakeError = ""; return }
    var registered: EventHotKeyRef?
    if let (code, modifiers) = binding {
      guard handler != nil else { throw NativeUpdateValidation.failure("无法注册全局快捷键。") }
      nextID &+= 1
      let id = EventHotKeyID(signature: 0x4d454e41, id: nextID)
      guard RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &registered) == noErr else { throw NativeUpdateValidation.failure("快捷键已被占用，请使用其他组合。") }
    }
    let previous = defaults.object(forKey: "wakeShortcut")
    defaults.set(value, forKey: "wakeShortcut")
    guard defaults.synchronize() else {
      if let registered { UnregisterEventHotKey(registered) }; defaults.set(previous, forKey: "wakeShortcut")
      throw NativeUpdateValidation.failure("无法保存快捷键设置。")
    }
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = registered; wakeShortcut = value; wakeError = ""
  }
}
