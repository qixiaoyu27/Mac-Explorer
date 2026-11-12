import AppKit
import ExplorerCore

@MainActor
enum NativeTerminalChecks {
  static func run(browser: BrowserController, output: URL) async throws -> [String] {
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw NativeSmoke.Failure(description: message) }; checks.append(message)
    }
    func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-terminal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let folder = root.appendingPathComponent("中文 space ' \" $(literal); &", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let file = root.appendingPathComponent("file.txt"); try Data().write(to: file)
    let key = NativeTerminal.preferenceKey, saved = browser.defaults.object(forKey: NativeTerminal.preferenceKey), previousDirectory = browser.directory
    defer {
      ExplorerMenu.dismiss(); if let window = browser.view.window { ExplorerDialogs.close(in: window) }
      if let saved { browser.defaults.set(saved, forKey: key) } else { browser.defaults.removeObject(forKey: key) }
      if browser.directory != previousDirectory { browser.navigate(to: previousDirectory) }
      try? FileManager.default.removeItem(at: root)
    }
    let warp = "dev.warp.Warp-Stable", fake = URL(fileURLWithPath: "/Fixture Warp.app")
    let lookup: (String) -> URL? = { $0 == warp ? fake : nil }
    try check(NativeTerminal.options(selected: "", lookup: lookup).map(\.1) == ["", warp], "Terminal choices include automatic and installed supported apps only")
    try check(NativeTerminal.options(selected: warp, lookup: { _ in nil }).contains { $0.0 == "Warp（未安装）" }, "Removed terminal remains identifiable in Settings")
    let request = try NativeTerminal.request(directory: folder, selected: warp, lookup: lookup)
    try check(request.directory == folder && request.application == fake, "Chinese, whitespace, quotes and shell syntax remain literal directory URLs")
    try check(rejects { _ = try NativeTerminal.request(directory: file, selected: warp, lookup: lookup) }, "Files cannot be opened as terminal directories")
    try check(rejects { _ = try NativeTerminal.request(directory: root.appendingPathComponent("missing"), selected: warp, lookup: lookup) }, "Removed directories are rejected")
    try check(rejects { _ = try NativeTerminal.request(directory: URL(string: "explorer://airdrop")!, selected: warp, lookup: lookup) }, "Virtual locations cannot launch a terminal")
    try check(rejects { _ = try NativeTerminal.request(directory: folder, selected: warp, lookup: { _ in nil }) }, "Uninstalled selected terminal reports an error instead of opening another app")
    try check(rejects { _ = try NativeTerminal.request(directory: folder, selected: "unknown.app", lookup: lookup) }, "Unknown saved terminal identifiers are rejected")
    let automatic = try NativeTerminal.request(directory: folder, selected: "")
    try check(automatic.directory == folder && automatic.application.isFileURL, "Automatic selection preserves the existing system-handler behavior")
    guard let window = browser.view.window else { throw NativeSmoke.Failure(description: "Terminal settings window missing") }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func windows(_ window: NSWindow) -> [NSWindow] { [window] + (window.childWindows ?? []).flatMap(windows) }
    func controls() -> [NSView] { windows(window).flatMap { $0.contentView.map(descendants) ?? [] } }
    func choice() throws -> NSButton {
      guard let button = controls().compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "终端应用" }) else { throw NativeSmoke.Failure(description: "Terminal choice missing") }; return button
    }
    browser.defaults.removeObject(forKey: key); browser.executeAction("settings")
    try check(try choice().title == "自动选择", "General settings defaults to automatic terminal selection")
    let button = try choice(); button.performClick(nil)
    guard let row = controls().first(where: { $0.accessibilityRole() == .menuItem && $0.accessibilityLabel() == "Terminal" }),
      let event = NSEvent.mouseEvent(with: .leftMouseUp, location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: row.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { throw NativeSmoke.Failure(description: "Installed Terminal option missing") }
    row.mouseUp(with: event)
    try check(browser.defaults.string(forKey: key) == "com.apple.Terminal", "Selecting a terminal immediately saves the ME preference")
    ExplorerDialogs.close(in: window); browser.executeAction("settings")
    try check(try choice().title == "Terminal", "Reopening Settings retains the selected terminal")
    let content = try choice().window!.contentView!
    content.layoutSubtreeIfNeeded()
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
      content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("terminal-settings-fixture.png"))
    }
    ExplorerDialogs.close(in: window)
    browser.defaults.set("unknown.app", forKey: key)
    browser.navigate(to: folder)
    let deadline = Date().addingTimeInterval(10)
    while browser.loading && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    try check(!browser.loading && browser.directory == folder, "Terminal context fixture has an accessible current directory")
    browser.selectedPaths = []
    browser.contextItems().first { $0.title == "在终端中打开" }?.action?()
    try check(browser.lastError == "所选终端未安装，请在设置中重新选择。", "Context menu uses the saved terminal selection and surfaces missing-app errors")
    return checks
  }
}
