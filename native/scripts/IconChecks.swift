import AppKit
import ExplorerCore

@main enum IconChecks {
  struct Failure: Error { let message: String }
  @MainActor static func main() async {
    do { try await run() }
    catch { fputs("IconChecks FAILED: \(error)\n", stderr); exit(1) }
  }
  @MainActor static func run() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    NativeLanguage.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-icon-check-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "local.macexplorer.icon-check." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let browser = BrowserController(initial: root, defaults: defaults)
    defer { browser.stopObserving(); window.close(); browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    for index in 0..<100 { try Data("# Fixture\n".utf8).write(to: root.appendingPathComponent(String(format: "%03d.md", index))) }
    let url = root.appendingPathComponent("000.md"), textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    let original = NSWorkspace.shared.urlForApplication(toOpen: url)
    guard let other = original != textEdit ? original : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { throw Failure(message: "A second document application is required") }
    func handler(_ application: URL) async throws {
      try await NSWorkspace.shared.setDefaultApplication(at: application, toOpenFileAt: url)
      precondition(NSWorkspace.shared.urlForApplication(toOpen: url) == application)
    }
    func until(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while !condition() {
        guard Date() < deadline else { throw Failure(message: "Icon check timed out") }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
    }
    var checks = 0
    func check(_ value: Bool, _ message: String) throws { guard value else { throw Failure(message: message) }; checks += 1; print("PASS icons: " + message) }
    try await handler(textEdit)
    let entry = try DirectoryReader.read(root).entries.first { $0.url == url }!, loader = IconLoader()
    _ = loader.request(entry, pixels: 128) { _ in }; try await until { loader.isIdle }
    let initialLoads = loader.loads
    _ = loader.request(entry, pixels: 128) { _ in }
    try check(loader.loads == initialLoads && loader.isIdle, "Unchanged file and application reuse the cached icon")
    try await handler(other)
    let unchanged = try DirectoryReader.read(root).entries.first { $0.url == url }!
    try check(unchanged.modified == entry.modified && unchanged.size == entry.size, "Changing only the fixture's default application preserves its content metadata")
    _ = loader.request(entry, pixels: 128) { _ in }; try await until { loader.isIdle }
    try check(loader.loads == initialLoads + 1, "A default application change bypasses the previous icon cache")
    try await handler(textEdit)
    defaults.set(false, forKey: "versionControl"); browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite)); window.contentViewController = browser
    browser.reload(); try await until { !browser.loading && browser.entries.count == 100 }
    for mode in [ExplorerLayoutMode.details, .icons, .list, .tiles, .content] {
      IconLoader.shared.clear(); browser.mode = mode; browser.iconSize = 64; browser.updateMode(persist: false)
      window.contentView?.layoutSubtreeIfNeeded(); browser.collection.layoutSubtreeIfNeeded()
      if mode == .details { _ = browser.table.view(atColumn: 0, row: 0, makeIfNecessary: true) }
      try await until { IconLoader.shared.isIdle }
      let scroll = browser.fileScroll
      browser.selectedPaths = [url.path]
      let origin = scroll.contentView.bounds.origin, loads = IconLoader.shared.loads, snapshot = browser.snapshot
      try await handler(NSWorkspace.shared.urlForApplication(toOpen: url) == textEdit ? other : textEdit)
      NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
      try await until { IconLoader.shared.isIdle }
      try check(IconLoader.shared.loads == loads + 1, "\(mode.rawValue): returning to the window refreshes the changed visible icon only (loads \(loads) -> \(IconLoader.shared.loads))")
      try check(browser.selectedPaths == [url.path] && scroll.contentView.bounds.origin == origin && browser.snapshot?.elapsedMilliseconds == snapshot?.elapsedMilliseconds, "\(mode.rawValue): icon refresh preserves selection, scrolling and the directory snapshot")
      let cachedLoads = IconLoader.shared.loads
      NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
      try await until { IconLoader.shared.isIdle }
      try check(IconLoader.shared.loads == cachedLoads, "\(mode.rawValue): returning without an association change retains cached icons")
    }
    browser.stopObserving()
    let stoppedLoads = IconLoader.shared.loads
    try await handler(NSWorkspace.shared.urlForApplication(toOpen: url) == textEdit ? other : textEdit)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    try await until { IconLoader.shared.isIdle }
    try check(IconLoader.shared.loads == stoppedLoads, "A closed browser stops observing focus changes")
    try check(!NSApp.windows.contains { $0.isVisible }, "No test windows were displayed")
    try check(try Data(contentsOf: url) == Data("# Fixture\n".utf8), "The fixture content is unchanged")
    print("Icons: \(checks) checks passed; only temporary files' per-file associations changed.")
  }
}
