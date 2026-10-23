import AppKit
import ExplorerCore

@MainActor
enum NativeNetworkDeleteChecks {
  private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private static func children(_ window: NSWindow) -> [NSWindow] { (window.childWindows ?? []).flatMap { [$0] + children($0) } }
  private static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Network delete UI timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
  }
  static func run(output: URL) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-network-delete-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "native-network-delete." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl"); defaults.set(true, forKey: "skipTrashConfirmation")
    let browser = BrowserController(initial: root, defaults: defaults)
    browser.home = root; browser.filePasteboard = NSPasteboard(name: .init(suite))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1050, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; window.makeKeyAndOrderFront(nil)
    var recycleCalls = 0
    browser.deletionNetworkLocation = { $0.lastPathComponent.hasPrefix("remote") }
    browser.fileErrorNetworkLocation = browser.deletionNetworkLocation
    browser.prepareNetworkDeletion = { try NetworkDeletion($0, network: { _ in true }) }
    browser.recycleItem = { source, _, _ in
      recycleCalls += 1
      let trash = root.appendingPathComponent("simulated-trash")
      try fm.createDirectory(at: trash, withIntermediateDirectories: true)
      let destination = trash.appendingPathComponent(source.lastPathComponent)
      try fm.moveItem(at: source, to: destination); return destination
    }
    defer {
      ExplorerDialogs.close(in: window); browser.stopObserving(); window.close(); browser.filePasteboard.releaseGlobally()
      defaults.removePersistentDomain(forName: suite)
      try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("remote-denied").path)
      try? fm.removeItem(at: root)
    }
    var checks: [String] = []
    func check(_ ok: Bool, _ title: String) throws { guard ok else { throw NativeSmoke.Failure(description: title) }; checks.append(title); print("PASS network delete: " + title) }
    func file(_ name: String) throws -> URL { let url = root.appendingPathComponent(name); try Data(name.utf8).write(to: url); return url }
    func select(_ sources: [URL]) async throws {
      browser.reload(); try await until { !browser.loading && sources.allSatisfy { source in browser.entries.contains { $0.url.path == source.path } } }
      browser.selectedPaths = Set(sources.map(\.path)); browser.updateMode(persist: false)
    }
    func button(_ title: String) throws -> EDButton {
      guard let button = children(window).compactMap(\.contentView).flatMap(descendants).compactMap({ $0 as? EDButton }).first(where: { $0.title == title }) else { throw NativeSmoke.Failure(description: "Missing network delete button: " + title) }; return button
    }
    func present(_ sources: [URL]) async throws {
      try await select(sources); browser.executeAction("trash"); try await until { ExplorerDialogs.isPresenting(in: window) }
    }
    let remote = try file("remote-中文 空格.txt")
    try await select([remote]); browser.executeAction("cut")
    try check(descendants(browser.commandBar).contains { ($0 as? ExplorerButton)?.toolTip?.hasPrefix(NL("删除")) == true }, "Network selection labels the toolbar action Delete instead of Move to Trash")
    let version = browser.filePasteboard.changeCount
    try await present([remote])
    let confirm = try button(NL("永久删除")), cancel = try button(NL("取消"))
    try check(fm.fileExists(atPath: remote.path) && recycleCalls == 0, "Network delete always confirms before mutation despite skipped Trash confirmation")
    try check(cancel.window?.firstResponder === cancel, "Permanent deletion initially focuses Cancel")
    let labels = children(window).compactMap(\.contentView).flatMap(descendants).compactMap { ($0 as? NSTextField)?.stringValue }
    try check(labels.contains { $0.contains(NL("永久删除网络驱动器上的 {0} 个项目？这些项目不会进入回收站，此操作无法撤销。", 1)) }, "Network confirmation states item count, no Recycle Bin and no undo")
    try check(!children(window).compactMap(\.contentView).flatMap(descendants).contains { ($0 as? NSButton)?.title == NL("不再询问") }, "Permanent confirmation has no suppression checkbox")
    if let view = confirm.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent("native-network-delete-confirm.png")) }
    }
    cancel.onPress?()
    try check(fm.fileExists(atPath: remote.path) && browser.filePasteboard.changeCount == version, "Cancel leaves the source and clipboard unchanged")
    try await present([remote]); try button(NL("永久删除")).onPress?()
    try await until { !browser.busy && !browser.loading && !fm.fileExists(atPath: remote.path) }
    try check(recycleCalls == 0 && !browser.contextItems().contains(where: { $0.title == NL("撤销") && $0.enabled }), "Confirmed network deletion bypasses Trash and creates no undo record")
    try check(browser.filePasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty != false, "Only successfully deleted source is consumed from the clipboard")
    let stale = try file("remote-stale.txt")
    try await present([stale])
    try fm.moveItem(at: stale, to: root.appendingPathComponent("retained-old")); try Data("replacement".utf8).write(to: stale)
    try button(NL("永久删除")).onPress?()
    try await until { !browser.busy && !browser.loading && browser.lastError != nil }
    try check(try String(contentsOf: stale) == "replacement", "Replacing the confirmed path prevents deletion of its new occupant")
    try check(browser.selectedPaths == [stale.path] && recycleCalls == 0, "Failed network deletion retains selection without falling back to Trash")
    let denied = root.appendingPathComponent("remote-denied")
    try fm.createDirectory(at: denied, withIntermediateDirectories: true); try Data("keep".utf8).write(to: denied.appendingPathComponent("child"))
    try await present([denied]); try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    try button(NL("永久删除")).onPress?()
    try await until { !browser.busy && !browser.loading && browser.lastError != nil }
    try check(browser.lastError?.contains("EACCES (13)") == true && browser.privacySettings.isHidden && browser.selectedPaths == [denied.path], "Network permission denial retains code and selection without macOS Settings recovery")
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
    try check(fm.fileExists(atPath: denied.appendingPathComponent("child").path), "Denied deletion does not alter permissions or contents")
    let batchGood = try file("remote-batch-good.txt"), batchStale = try file("remote-batch-stale.txt")
    try await select([batchGood, batchStale]); browser.executeAction("cut")
    try await present([batchGood, batchStale])
    try fm.moveItem(at: batchStale, to: root.appendingPathComponent("retained-batch-old")); try Data("batch replacement".utf8).write(to: batchStale)
    try button(NL("永久删除")).onPress?(); try await until { !browser.busy && !browser.loading && browser.lastError != nil }
    try check(!fm.fileExists(atPath: batchGood.path) && fm.fileExists(atPath: batchStale.path), "A partially failed network batch deletes only its unchanged confirmed item")
    try check(browser.selectedPaths == [batchStale.path], "A partial network failure selects only the remaining failed item")
    let remainingClipboard = (browser.filePasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    try check(remainingClipboard.map(\.path) == [batchStale.path], "Partial network deletion consumes only successful clipboard sources")
    try check(try String(contentsOf: batchStale) == "batch replacement", "A partial batch preserves the replacement occupant")
    let mixedRemote = try file("remote-mixed.txt"), local = try file("local.txt")
    try await present([local, mixedRemote])
    let mixedLabels = children(window).compactMap(\.contentView).flatMap(descendants).compactMap { ($0 as? NSTextField)?.stringValue }
    try check(mixedLabels.contains { $0.contains(NL("永久删除 {0} 个网络项目，并将 {1} 个本地项目移到回收站？网络项目无法撤销删除。", 1, 1)) }, "Mixed confirmation distinguishes permanent network deletion from local Trash")
    try button(NL("永久删除")).onPress?(); try await until { !browser.busy && !browser.loading && !fm.fileExists(atPath: mixedRemote.path) }
    try check(recycleCalls == 1 && fm.fileExists(atPath: root.appendingPathComponent("simulated-trash/local.txt").path), "Mixed selection recycles only the local item")
    try check(browser.contextItems().contains(where: { $0.title == NL("撤销") && $0.enabled }), "Only local Trash contributes a reversible change")
    browser.executeAction("undo"); try await until { !browser.busy && !browser.loading && fm.fileExists(atPath: local.path) }
    try check(!fm.fileExists(atPath: mixedRemote.path), "Undo restores the local Trash item while leaving the network deletion irreversible")
    let localOnly = try file("local-only.txt")
    try await select([localOnly]); browser.executeAction("trash"); try await until { !browser.busy && !browser.loading && !fm.fileExists(atPath: localOnly.path) }
    try check(recycleCalls == 2 && !ExplorerDialogs.isPresenting(in: window), "Local deletion retains the existing skip-confirmation Trash preference")
    return checks
  }
}
