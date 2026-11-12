import AppKit
import ExplorerCore

@MainActor
enum NativeLifecycleChecks {
  static func run(source: BrowserController) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-lifecycle-" + UUID().uuidString)
    try fm.createDirectory(at: root.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
    let domain = "local.macexplorer.native-lifecycle." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: domain) else { throw failure("Cannot create lifecycle fixture preferences") }
    let originalMenu = NSApp.mainMenu, originalWindowsMenu = NSApp.windowsMenu, originalKey = NSApp.keyWindow
    let delegate = ApplicationDelegate()
    defer {
      for window in delegate.browserWindows { ExplorerDialogs.close(in: window); window.close() }
      NSApp.mainMenu = originalMenu; NSApp.windowsMenu = originalWindowsMenu; originalKey?.makeKeyAndOrderFront(nil)
      defaults.removePersistentDomain(forName: domain); defaults.synchronize(); try? fm.removeItem(at: root)
    }
    let originalTabs = source.tabs.count, originalSelection = source.selectedPaths
    let fixture = BrowserController(initial: root, defaults: defaults)
    fixture.home = root; fixture.testTrashDirectory = root.appendingPathComponent(".Trash")
    fixture.filePasteboard = NSPasteboard(name: .init(domain))
    defer { fixture.filePasteboard.releaseGlobally() }
    let window = delegate.createWindow(tab: BrowserTab(history: [root]), source: fixture, at: NSPoint(x: 360, y: 800))
    try await until { !delegate.browser.loading }
    var checks: [String] = []
    func check(_ condition: Bool, _ text: String) throws { guard condition else { throw failure(text) }; checks.append(text) }
    try check(NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.title == NL("设置…") && $0.keyEquivalent == "," }) == true, "Application menu exposes Settings on Command+comma")
    guard let dock = delegate.applicationDockMenu(NSApp) else { throw failure("No Native Dock menu") }
    try check(dock.items.map(\.title) == [NL("新建窗口"), NL("新建选项卡")], "Dock exposes New Window and New Tab")
    dock.performActionForItem(at: 1)
    try check(delegate.browser.tabs.count == 2 && delegate.browser.directory.path == root.path, "Dock New Tab opens the personal folder in the active fixture window")
    dock.performActionForItem(at: 0)
    try check(delegate.browserWindows.count == 2 && delegate.browser.directory.path == root.path, "Dock New Window creates an independent fixture window")
    var views: [String: [String: Any]] = [:]
    for index in 0..<5000 { views[root.appendingPathComponent("old-\(index)").path] = ["view": "icons", "sort": "name", "ascending": true, "lastUsed": Double(index)] }
    defaults.set(views, forKey: "folderViews")
    delegate.browser.setView(.details)
    let stored = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(stored.count == 5000 && stored[root.path] != nil && stored[root.appendingPathComponent("old-0").path] == nil, "Folder view writes cap history at 5000 and evict the oldest saved setting")
    let browser = delegate.browser!
    defaults.removeObject(forKey: "folderViews")
    defaults.set(["view": "icons", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    browser.navigate(to: root); browser.setView(.details)
    var overrides = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(overrides[root.path]?["view"] as? String == "details" && overrides[root.path]?["sort"] == nil, "Changing layout saves only the layout override")
    defaults.set(["view": "icons", "iconSize": 64, "sort": "size", "ascending": false], forKey: "defaultFolderView")
    browser.navigate(to: root)
    try check(browser.mode == .details && browser.sort == .size && !browser.ascending, "Untouched sort follows changed defaults while the layout override remains")
    browser.sortMenu().first(where: { $0.title == NL("名称") })?.action?()
    overrides = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(overrides[root.path]?["view"] as? String == "details" && overrides[root.path]?["sort"] as? String == "name", "Changing sort preserves the existing layout override")
    defaults.set(["view": "tiles", "iconSize": 80, "sort": "modified", "ascending": true], forKey: "defaultFolderView")
    browser.navigate(to: root); browser.setView(.tiles, size: 80)
    overrides = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(overrides[root.path]?["view"] == nil && overrides[root.path]?["sort"] as? String == "name", "Returning layout to defaults clears only its override")
    defaults.set(["view": "content", "iconSize": 88, "sort": "modified", "ascending": true], forKey: "defaultFolderView")
    browser.navigate(to: root)
    try check(browser.mode == .content && browser.iconSize == 88 && browser.sort == .name && !browser.ascending, "Cleared layout follows defaults without changing explicit sort")
    browser.sortMenu().first(where: { $0.title == NL("修改日期") })?.action?()
    browser.sortMenu().first(where: { $0.title == NL("递增") })?.action?()
    overrides = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(overrides[root.path] == nil, "Returning both groups to defaults removes the per-folder record")
    browser.navigate(to: URL(string: "explorer://trash")!); browser.setView(.list)
    browser.navigate(to: root); browser.navigate(to: URL(string: "explorer://trash")!)
    try check(browser.mode == .list, "Virtual Trash remembers its own layout override")
    defaults.set(["view": "icons", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    let touched = root.appendingPathComponent("old-0")
    try fm.createDirectory(at: touched, withIntermediateDirectories: true)
    defaults.set(views, forKey: "folderViews")
    browser.navigate(to: touched); browser.navigate(to: root); browser.setView(.details)
    overrides = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(overrides[touched.path] != nil && overrides[root.appendingPathComponent("old-1").path] == nil, "Opening a saved location refreshes its eviction recency")
    let missing = root.appendingPathComponent("missing-folder")
    overrides[missing.path] = ["view": "details", "iconSize": 64, "lastUsed": 0]
    defaults.set(overrides, forKey: "folderViews"); browser.navigate(to: missing)
    overrides = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(overrides[missing.path] == nil, "Touch removes a saved location that no longer exists")
    browser.navigate(to: root)
    for owned in Array(delegate.browserWindows) { owned.close() }
    try check(delegate.browserWindows.isEmpty && delegate.window == nil && !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing all fixture windows keeps the application available")
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    try await until { delegate.window != nil && !delegate.browser.loading }
    try check(delegate.browserWindows.count == 1 && delegate.browser.defaults === defaults && delegate.browser.directory.path == root.path, "Reopen recreates a window with the existing preference domain and home folder")
    for owned in Array(delegate.browserWindows) { owned.close() }
    dock.performActionForItem(at: 1)
    try await until { delegate.window != nil && !delegate.browser.loading }
    try check(delegate.browserWindows.count == 1 && delegate.browser.tabs.count == 1, "Dock New Tab without a window creates exactly one home tab")
    for owned in Array(delegate.browserWindows) { owned.close() }
    let external = root.appendingPathComponent("external.txt"); try Data("fixture".utf8).write(to: external)
    delegate.application(NSApp, open: [external])
    try await until { delegate.window != nil && !delegate.browser.loading && delegate.browser.entries.contains(where: { $0.url.path == external.path }) }
    try check(delegate.browser.selectedPaths.contains(external.path), "External open recreates a closed window and selects the requested file")
    let big = root.appendingPathComponent("big"), nested = big.appendingPathComponent("a-child"), other = root.appendingPathComponent("other")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true); try fm.createDirectory(at: other, withIntermediateDirectories: true)
    for index in 0..<300 { try Data().write(to: big.appendingPathComponent(String(format: "file-%03d.txt", index))) }
    let target = big.appendingPathComponent("zzz-target.txt"), second = big.appendingPathComponent("zzz-second.txt"), elsewhere = other.appendingPathComponent("elsewhere.txt")
    for file in [target, second, elsewhere] { try Data().write(to: file) }
    func revealed(_ file: URL) -> Bool {
      guard let current = delegate.browser, !current.loading, current.directory.path == file.deletingLastPathComponent().path, let row = current.entries.firstIndex(where: { $0.id == file.path }) else { return false }
      current.view.layoutSubtreeIfNeeded()
      guard current.selectedPaths.contains(file.path) else { return false }
      if current.mode == .details { return current.table.rows(in: current.table.visibleRect).contains(row) }
      return current.collection.indexPathsForVisibleItems().contains(IndexPath(item: row, section: 0))
    }
    let defaultView = defaults.object(forKey: "defaultFolderView")
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    delegate.browser.navigate(to: nested)
    try await until { !delegate.browser.loading && delegate.browser.directory.path == nested.path }
    delegate.application(NSApp, open: [target])
    try await until("Reveal from a child folder timed out") { revealed(target) }
    try check(delegate.browser.mode == .details && delegate.browser.selectedPaths == [target.path], "External open from a child folder reveals the requested file instead of that folder")
    delegate.browser.table.scroll(.zero)
    delegate.application(NSApp, open: [target])
    try await until("Reveal in the current folder timed out") { revealed(target) }
    try check(delegate.browserWindows.count == 1, "External open in the current folder scrolls to the requested file")
    defaults.set(["view": "icons", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    delegate.browser.navigate(to: nested)
    try await until("Icon view fixture timed out") { !delegate.browser.loading && delegate.browser.directory.path == nested.path }
    delegate.application(NSApp, open: [target])
    try await until("Reveal in icon view timed out") { revealed(target) }
    try check(delegate.browser.mode != .details, "External open scrolls to the requested file in icon view")
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    let tabCount = delegate.browser.tabs.count
    delegate.application(NSApp, open: [target, second])
    try await until("Reveal of two files timed out") { revealed(second) && delegate.browser.selectedPaths == [target.path, second.path] }
    try check(delegate.browser.tabs.count == tabCount, "External files in one folder share a tab and a selection")
    delegate.application(NSApp, open: [target, elsewhere])
    try await until("Reveal across folders timed out") { revealed(elsewhere) }
    try check(delegate.browser.tabs.count == tabCount + 1 && delegate.browser.selectedPaths == [elsewhere.path], "External files in different folders open separate tabs")
    let package = other.appendingPathComponent("Fixture.app")
    try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    delegate.browser.reload()
    delegate.application(NSApp, open: [package])
    try await until("Reveal of an application bundle timed out") { revealed(package) }
    try check(delegate.browser.selectedPaths == [package.path], "An external application bundle is selected in its folder, not entered")
    delegate.application(NSApp, open: [nested])
    try await until("External folder open timed out") { !delegate.browser.loading && delegate.browser.directory.path == nested.path }
    try check(delegate.browser.selectedPaths.isEmpty, "An external folder opens directly")
    delegate.browser.navigate(to: big)
    try await until("Return to the fixture folder timed out") { !delegate.browser.loading && delegate.browser.directory.path == big.path }
    let beforeMissing = delegate.browser.directory.path
    delegate.application(NSApp, open: [big.appendingPathComponent("missing.txt")])
    try await until("Missing item error timed out") { delegate.browser.lastError == NL("项目不存在或无法访问") }
    try check(delegate.browser.directory.path == beforeMissing, "A missing external item reports an error and keeps the location")
    guard let blocked = delegate.window, let blockedBrowser = delegate.browser else { throw failure("No lifecycle window for the dialog case") }
    ExplorerDialogs.confirm(in: blocked, title: "fixture", detail: "fixture", confirmTitle: NL("确定")) {}
    delegate.application(NSApp, open: [target])
    try await until("Reveal under a dialog timed out") { revealed(target) }
    try check(delegate.browserWindows.count == 2 && delegate.window !== blocked && ExplorerDialogs.isPresenting(in: blocked) && blockedBrowser.directory.path == beforeMissing, "External open under a dialog uses a new window and leaves the dialog alone")
    ExplorerDialogs.close(in: blocked)
    defaults.set(defaultView, forKey: "defaultFolderView")
    guard let owner = delegate.window else { throw failure("No lifecycle window for the file viewer prompt") }
    let viewerSystem = root.appendingPathComponent("viewer-system.plist")
    try PropertyListSerialization.data(fromPropertyList: ["global": "com.removed.viewer"], format: .xml, options: 0).write(to: viewerSystem)
    func viewerGlobal() throws -> String? { (try PropertyListSerialization.propertyList(from: Data(contentsOf: viewerSystem), format: nil) as? [String: Any])?["global"] as? String }
    let viewer = NativeFileViewer(backupURL: root.appendingPathComponent("viewer-backup.plist"), fixture: viewerSystem, appExists: { $0 != "com.removed.viewer" })
    var suppressions = 0
    let native = "local.macexplorer.native-prototype"
    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    func panels(_ parent: NSWindow) -> [NSWindow] { (parent.childWindows ?? []).flatMap { [$0] + panels($0) } }
    func dialogViews() -> [NSView] { panels(owner).compactMap(\.contentView).flatMap(descendants) }
    ExplorerDialogs.offerFileViewer(in: owner, viewer: viewer) { suppressions += 1 }
    try check(ExplorerDialogs.isPresenting(in: owner), "File viewer prompt opens over the window")
    try check(try viewerGlobal() == "com.removed.viewer", "Showing the file viewer prompt writes nothing")
    ExplorerDialogs.close(in: owner)
    try check(!ExplorerDialogs.isPresenting(in: owner) && (try viewerGlobal()) == "com.removed.viewer", "Dismissing the file viewer prompt keeps the existing setting")
    try check(suppressions == 0 && viewer.shouldPromptAtLaunch(suppressed: false, bundleID: native), "Cancelling without opting out asks again on the next launch")
    ExplorerDialogs.offerFileViewer(in: owner, viewer: viewer) { suppressions += 1 }
    guard let optOut = dialogViews().compactMap({ $0 as? NSButton }).first(where: { $0.title == NL("不再询问") }) else { throw failure("File viewer prompt has no opt-out") }
    optOut.state = .on
    ExplorerDialogs.close(in: owner)
    try check(suppressions == 1 && (try viewerGlobal()) == "com.removed.viewer", "Cancelling with Don't ask again suppresses the prompt and keeps the setting")
    ExplorerDialogs.offerFileViewer(in: owner, viewer: viewer) { suppressions += 1 }
    guard let confirm = dialogViews().compactMap({ $0 as? EDButton }).first(where: { $0.title == NL("确定") }) else { throw failure("File viewer prompt has no confirm button") }
    confirm.onPress?()
    try await until { !ExplorerDialogs.isPresenting(in: owner) }
    try check(try viewerGlobal() == native, "Confirming the file viewer prompt replaces a removed viewer")
    try check(suppressions == 1, "Confirming without opting out records no suppression")
    try check(window.isVisible == false && source.tabs.count == originalTabs && source.selectedPaths == originalSelection, "Lifecycle checks leave the caller window and selection unchanged")
    return checks
  }
  private static func until(_ label: String = "Lifecycle fixture timed out", _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() { if Date() >= deadline { throw failure(label) }; try await Task.sleep(nanoseconds: 30_000_000) }
  }
  private static func failure(_ message: String) -> NSError { NSError(domain: "NativeLifecycleChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
