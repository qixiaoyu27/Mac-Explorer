import AppKit
import ExplorerCore

@MainActor
enum NativeQuitChecks {
  private static let prefix = "local.macexplorer.native-quit."
  static func fixture(root: String, suite: String?) -> UserDefaults? {
    guard let suite, suite.hasPrefix(prefix), UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil,
          URL(fileURLWithPath: root).lastPathComponent.hasPrefix("native-quit-") else { return nil }
    return UserDefaults(suiteName: suite)
  }
  private static func until(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Quit fixture timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
  }
  static func run(output: URL) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-quit-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = prefix + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set("computer", forKey: NativeStartLocation.preferenceKey); defaults.set(false, forKey: "versionControl")
    defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize(); try? fm.removeItem(at: root) }
    var checks: [String] = []
    for mode in ["command-q", "settings-q", "standard-quit", "keep"] {
      try NativeSessions.save([NativeSavedWindow(locations: [root.absoluteString, "explorer://network"], frame: "")], to: defaults)
      defaults.synchronize()
      try await launch(mode, root: root, suite: suite, output: output)
      defaults.synchronize()
      let saved = NativeSessions.load(defaults)
      guard (mode == "keep" ? saved.first?.locations.count == 3 : saved.isEmpty) else { throw NativeSmoke.Failure(description: "Wrong saved state after " + mode) }
      if mode != "keep" { try await launch("fresh", root: root, suite: suite, output: output) }
      checks.append(mode == "keep" ? "Explicit Keep Windows preserves the complete session" : "\(mode) exits and relaunches with one configured startup tab")
    }
    try await launch("enable-q", root: root, suite: suite, output: output)
    defaults.synchronize()
    guard defaults.bool(forKey: NativeSessions.restoreAfterQuitKey), NativeSessions.load(defaults).first?.locations.count == 3 else { throw NativeSmoke.Failure(description: "Enabling session restore did not persist the preference and tabs") }
    try await launch("restored", root: root, suite: suite, output: output)
    checks.append("Enabling restore in General settings makes Command+Q preserve tabs across a real restart")
    try await launch("disable-q", root: root, suite: suite, output: output)
    defaults.synchronize()
    guard !defaults.bool(forKey: NativeSessions.restoreAfterQuitKey), NativeSessions.load(defaults).isEmpty else { throw NativeSmoke.Failure(description: "Disabling session restore did not clear the next saved session") }
    try await launch("fresh", root: root, suite: suite, output: output)
    checks.append("Disabling restore in General settings returns Command+Q to the single startup page")
    return checks
  }
  private static func launch(_ mode: String, root: URL, suite: String, output: URL) async throws {
    let process = Process(); process.executableURL = Bundle.main.executableURL
    let report = output.appendingPathComponent("quit-\(mode).json"), log = output.appendingPathComponent("quit-\(mode).log")
    try? FileManager.default.removeItem(at: report)
    process.arguments = ["--smoke-test", root.path, "--report", report.path, "--quit-session-suite", suite, "--quit-mode", mode]
    FileManager.default.createFile(atPath: log.path, contents: nil); let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    process.standardOutput = handle; process.standardError = handle; try process.run(); defer { if process.isRunning { process.terminate() } }
    try await until { !process.isRunning }
    guard process.terminationStatus == 0, let data = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any], data["passed"] as? Bool == true else { throw NativeSmoke.Failure(description: "Quit subprocess failed: " + mode) }
  }
  static func child(browser: BrowserController, window: NSWindow, root: URL, suite: String, report: URL) async throws {
    guard fixture(root: root.path, suite: suite) != nil, let index = CommandLine.arguments.firstIndex(of: "--quit-mode"), CommandLine.arguments.indices.contains(index + 1),
          let delegate = NSApp.delegate as? ApplicationDelegate else { throw NativeSmoke.Failure(description: "Invalid quit fixture") }
    let mode = CommandLine.arguments[index + 1]
    try await until { !browser.loading }
    if mode == "fresh" {
      guard browser.tabs.count == 1, browser.directory.absoluteString == "explorer://computer" else { throw NativeSmoke.Failure(description: "Quit restored stale tabs instead of the configured startup page") }
    } else {
      guard browser.tabs.count == 3 else { throw NativeSmoke.Failure(description: "Quit fixture did not exercise real window restoration") }
    }
    if ["settings-q", "enable-q", "disable-q"].contains(mode) {
      browser.executeAction("settings"); try await until { ExplorerDialogs.isPresenting(in: window) }
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      func childViews(_ owner: NSWindow) -> [NSView] { (owner.childWindows ?? []).flatMap { ($0.contentView.map(descendants) ?? []) + childViews($0) } }
      guard let toggle = childViews(window).compactMap({ $0 as? EDButton }).first(where: { $0.title == NL("退出后恢复窗口和标签页") }) else { throw NativeSmoke.Failure(description: "Missing session restoration checkbox") }
      if mode == "enable-q" || mode == "disable-q" {
        let enabled = mode == "enable-q"
        guard toggle.checked != enabled else { throw NativeSmoke.Failure(description: "Session restoration checkbox did not load its persisted value") }
        toggle.performClick(nil)
        guard toggle.checked == enabled, browser.defaults.bool(forKey: NativeSessions.restoreAfterQuitKey) == enabled else { throw NativeSmoke.Failure(description: "Session restoration checkbox did not save") }
      } else if toggle.checked { throw NativeSmoke.Failure(description: "Session restoration should default to disabled") }
      if mode == "enable-q", let view = toggle.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let image = bitmap.representation(using: .png, properties: [:]) { try image.write(to: report.deletingLastPathComponent().appendingPathComponent("session-restore-settings-fixture.png")) }
      }
    }
    // Write first: successful menu dispatch terminates the real child application synchronously.
    try JSONSerialization.data(withJSONObject: ["passed": true, "mode": mode]).write(to: report)
    if mode == "standard-quit" || mode == "fresh" || mode == "restored" { NSApp.terminate(nil) }
    else if mode == "keep" {
      guard let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.title == NL("退出并保留窗口") }) else { throw NativeSmoke.Failure(description: "Missing explicit preserve-session action") }
      menu.performActionForItem(at: index)
    } else {
      guard let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "q" }), delegate.validateMenuItem(item),
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12),
            NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw NativeSmoke.Failure(description: "Command+Q did not dispatch the quit menu action") }
    }
  }
}
