import AppKit
import ExplorerCore
import Darwin

@MainActor
enum NativeCreatedDateChecks {
  private static func failure(_ message: String) -> NativeSmoke.Failure { .init(description: message) }
  private static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() {
      guard Date() < deadline else { throw failure("Created-date check timed out") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
  private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private static func children(_ window: NSWindow) -> [NSWindow] { (window.childWindows ?? []).flatMap { [$0] + children($0) } }
  private static func clickMenu(_ title: String, owner: NSWindow) throws {
    guard let row = children(owner).compactMap(\.contentView).flatMap(descendants).first(where: { $0.accessibilityRole() == .menuItem && $0.accessibilityLabel() == title }),
      let window = row.window,
      let event = NSEvent.mouseEvent(with: .leftMouseUp, location: row.convert(NSPoint(x: 20, y: 16), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)
    else { throw failure("Missing menu item: " + title) }
    row.mouseUp(with: event)
  }
  private static func capture(_ window: NSWindow, at url: URL) throws {
    guard let view = window.contentView else { throw failure("Missing created-date window") }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Cannot capture created-date layout") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("Cannot encode created-date layout") }
    try data.write(to: url)
  }

  static func run(output: URL) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-created-date-" + UUID().uuidString)
    try fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    for (name, created, modified) in [("new.txt", 1_700_000_000.0, 1_600_000_000.0), ("old10.txt", 1_600_000_000.0, 1_700_000_000.0), ("old2.txt", 1_600_000_000.0, 1_700_000_000.0)] {
      let file = root.appendingPathComponent(name)
      try Data(name.utf8).write(to: file)
      let fd = open(file.path, O_RDWR | O_NOFOLLOW)
      guard fd >= 0 else { throw failure("Cannot open date fixture") }
      var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
      attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
      var times = [timespec(tv_sec: Int(created), tv_nsec: 0), timespec(tv_sec: Int(modified), tv_nsec: 0)]
      let result = times.withUnsafeMutableBytes { fsetattrlist(fd, &attributes, $0.baseAddress, $0.count, 0) }
      var info = stat(); let readback = fstat(fd, &info); close(fd)
      guard result == 0, readback == 0, info.st_birthtimespec.tv_sec == Int(created), info.st_mtimespec.tv_sec == Int(modified) else { throw failure("Date fixture readback mismatch") }
    }
    for (name, seconds) in [("new.txt", 1_730_000_000.0), ("Folder", 1_720_000_000.0), ("old10.txt", 1_710_000_000.0), ("old2.txt", 1_710_000_000.0)] {
      try (root.appendingPathComponent(name) as NSURL).setResourceValue(Date(timeIntervalSince1970: seconds), forKey: .addedToDirectoryDateKey)
    }
    let before = try DirectoryReader.read(root).entries
    let suite = "local.macexplorer.native-created-date." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl")
    defaults.set(["view": "details", "iconSize": 64, "sort": "modified", "ascending": false], forKey: "defaultFolderView")
    let browser = BrowserController(initial: root, defaults: defaults)
    browser.home = root; browser.filePasteboard = NSPasteboard(name: .init(suite))
    var browsers = [browser], windows: [NSWindow] = []
    let oldAppearance = NSApp.appearance, oldKey = NSApp.keyWindow
    defer {
      ExplorerMenu.dismiss()
      for window in windows { ExplorerDialogs.close(in: window); window.close() }
      for browser in browsers { browser.stopObserving() }
      browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); defaults.synchronize()
      NSApp.appearance = oldAppearance; oldKey?.makeKeyAndOrderFront(nil); try? fm.removeItem(at: root)
    }
    func makeWindow(_ browser: BrowserController) -> NSWindow {
      let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1260, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentViewController = browser; window.makeKeyAndOrderFront(nil); windows.append(window); return window
    }
    let window = makeWindow(browser)
    try await until { !browser.loading && browser.entries.count == 4 }
    var checks: [String] = []
    func check(_ condition: Bool, _ text: String) throws { guard condition else { throw failure(text) }; checks.append(text); print("PASS created-date: " + text) }
    func column(_ id: String) -> NSTableColumn { browser.table.tableColumns.first { $0.identifier.rawValue == id }! }
    try check(browser.sort == .modified && !browser.ascending, "Legacy modified-date default is preserved")
    try check(browser.table.tableColumns.map { $0.identifier.rawValue } == ["name", "modified", "created", "added", "kind", "size"], "Created-date column follows Modified without reordering the original columns")
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/M/d HH:mm"; formatter.locale = NativeLanguage.formatLocale
    for entry in browser.entries where !entry.isDirectory {
      let row = browser.entries.firstIndex(of: entry)!
      let cell = browser.tableView(browser.table, viewFor: column("created"), row: row) as? MetadataCell
      try check(cell?.value.stringValue == entry.created.map(formatter.string) && cell?.value.stringValue != entry.modified.map(formatter.string), "Created-date cell uses birth time: " + entry.name)
    }
    ExplorerMenu.present(browser.sortMenu(), below: browser.sortButton)
    try clickMenu(NL("创建日期"), owner: window)
    try await until { browser.sort == .created && browser.entries.map(\.name) == ["Folder", "new.txt", "old10.txt", "old2.txt"] }
    try check(browser.table.sortDescriptors.first?.key == "created" && browser.table.sortDescriptors.first?.ascending == false && (column("created").headerCell as? ExplorerHeaderCell)?.ascending == false, "Sort menu synchronizes the native header descriptor and descending indicator")
    browser.table.sortDescriptors = [NSSortDescriptor(key: "created", ascending: true)]
    try await until { browser.ascending && browser.entries.map(\.name) == ["Folder", "old2.txt", "old10.txt", "new.txt"] }
    try check(browser.sortMenu().first { $0.title == NL("创建日期") }?.checked == true && browser.sortMenu().first { $0.title == NL("递增") }?.checked == true, "AppKit header sorting updates the menu and applies natural date ties")
    let stored = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]]
    try check(stored?[root.path]?["sort"] as? String == "created" && stored?[root.path]?["ascending"] as? Bool == true, "Created-date direction persists as a folder override")
    let second = BrowserController(initial: root, defaults: defaults); second.home = root; browsers.append(second)
    _ = makeWindow(second)
    try await until { !second.loading && second.entries.count == 4 }
    try check(second.sort == .created && second.ascending, "A new window restores the folder's creation-date override")
    browser.sortMenu().first { $0.title == NL("递减") }?.action?()
    try await until { second.sort == .created && !second.ascending && second.entries.first(where: { !$0.isDirectory })?.name == "new.txt" }
    try check(true, "Created-date preference changes synchronize across open windows")
    for mode in [ExplorerLayoutMode.icons, .list, .tiles, .content, .details] {
      browser.setView(mode)
      try await until { browser.entries.first(where: { !$0.isDirectory })?.name == "new.txt" }
      try check(browser.sort == .created && !browser.ascending, "Created-date order survives layout " + mode.rawValue)
    }
    for (width, pane) in [(1260.0, ""), (1100.0, ""), (920.0, ""), (800.0, ""), (1100.0, "preview"), (800.0, "details")] {
      browser.paneMode = pane; window.setContentSize(NSSize(width: width, height: 720)); browser.view.needsLayout = true; browser.view.layoutSubtreeIfNeeded()
      let visible = browser.table.tableColumns.filter { !$0.isHidden }
      let insets = browser.fileScroll.contentInsets
      let available = browser.fileScroll.contentSize.width - insets.left - insets.right
      let overflows = visible.reduce(0) { $0 + $1.width } > available + 1
      try check(visible.map { $0.identifier.rawValue } == DetailColumns.identifiers.filter { DetailColumns().visible.contains($0) } && column("name").width >= 150 &&
                browser.content.horizontalScroller.isHidden == !overflows,
                "Details keeps its columns and scrolls when needed at \(Int(width)) / \(pane)")
      if width == 800 {
        try check(overflows && browser.sortMenu().contains { $0.title == NL("创建日期") }, "Narrow Details keeps created-date sorting accessible")
      }
      try capture(window, at: output.appendingPathComponent("native-created-\(Int(width))-\(pane.isEmpty ? "none" : pane).png"))
    }
    let regularRowHeight = browser.table.rowHeight
    browser.paneMode = ""; window.setContentSize(NSSize(width: 1260, height: 780)); browser.compact = true; browser.updateMode(persist: false)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    try capture(window, at: output.appendingPathComponent("native-created-dark-compact.png"))
    try check(browser.table.rowHeight >= 28 && browser.table.rowHeight < regularRowHeight && !column("created").isHidden, "Compact dark details retain the creation-date column")
    NSApp.appearance = oldAppearance

    // Use the real settings controls and reset only this fixture's folder overrides.
    browser.executeAction("settings")
    try await until { ExplorerDialogs.isPresenting(in: window) }
    func choice(_ label: String) throws -> NSButton {
      guard let button = children(window).compactMap(\.contentView).flatMap(descendants).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == label }) else { throw failure("Missing settings choice " + label) }
      button.scrollToVisible(button.bounds); return button
    }
    try choice(NL("默认排序")).performClick(nil); try clickMenu(NL("创建日期"), owner: window)
    try check(defaults.dictionary(forKey: "defaultFolderView")?["sort"] as? String == "created", "Settings default-sort picker offers and saves Created date")
    guard let reset = children(window).compactMap(\.contentView).flatMap(descendants).compactMap({ $0 as? EDButton }).first(where: { $0.title == NL("重置所有文件夹") }) else { throw failure("Missing folder reset") }
    reset.onPress?()
    ExplorerDialogs.close(in: window)
    try await until { browser.sort == .created && !browser.ascending && second.sort == .created && !second.ascending }
    try check(defaults.dictionary(forKey: "folderViews") == nil, "Reset folders follows the Created default without retaining overrides")
    browser.sortMenu().first { $0.title == NL("递增") }?.action?()
    defaults.synchronize()
    try await verifyRelaunch(root: root, suite: suite, output: output)
    try check(true, "Fresh application process restores Created default and ascending folder override")
    try check(browser.foldersFirst && column("added").isHidden, "Legacy settings keep folders first and Added hidden")
    ExplorerMenu.present(browser.columnMenu(), below: browser.viewButton)
    try clickMenu(NL("添加日期"), owner: window)
    window.contentView?.layoutSubtreeIfNeeded()
    try check(!column("added").isHidden && browser.detailColumns.visible.contains("added"), "Added date can be enabled from the real column menu")
    for (row, entry) in browser.entries.enumerated() {
      let cell = browser.tableView(browser.table, viewFor: column("added"), row: row) as? MetadataCell
      try check(entry.added != nil && cell?.value.stringValue == entry.added.map(formatter.string), "Added cell displays system metadata: " + entry.name)
    }
    browser.executeAction("settings")
    try await until { ExplorerDialogs.isPresenting(in: window) }
    try choice(NL("默认排序")).performClick(nil); try clickMenu(NL("添加日期"), owner: window)
    ExplorerDialogs.close(in: window)
    ExplorerMenu.present(browser.sortMenu(), below: browser.sortButton)
    try clickMenu(NL("添加日期"), owner: window)
    browser.sortMenu().first { $0.title == NL("递减") }?.action?()
    try await until { browser.sort == .added && browser.entries.map(\.name) == ["Folder", "new.txt", "old10.txt", "old2.txt"] }
    ExplorerMenu.present(browser.sortMenu(), below: browser.sortButton)
    try clickMenu(NL("文件夹优先"), owner: window)
    let mixed = ["new.txt", "Folder", "old10.txt", "old2.txt"]
    try await until { browser.entries.map(\.name) == mixed && second.entries.map(\.name) == mixed && !second.foldersFirst }
    try check(browser.sortMenu().first { $0.title == NL("文件夹优先") }?.checked == false, "Mixed sorting and folder preference synchronize across windows")
    browser.table.sortDescriptors = [NSSortDescriptor(key: "added", ascending: true)]
    try await until { browser.entries.map(\.name) == ["old2.txt", "old10.txt", "Folder", "new.txt"] }
    browser.table.sortDescriptors = [NSSortDescriptor(key: "added", ascending: false)]
    try await until { browser.entries.map(\.name) == mixed }
    browser.reload()
    try await until { !browser.loading && browser.entries.map(\.name) == mixed }
    try check(!browser.foldersFirst, "Mixed added-date sorting survives header direction changes and reload")
    let incoming = root.appendingPathComponent("incoming.txt")
    try Data("new arrival".utf8).write(to: incoming)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: incoming.path)
    try await until { browser.entries.count == 5 && browser.entries.first?.name == "incoming.txt" }
    try check(browser.entries.first?.added != nil && browser.entries.dropFirst().map(\.name) == mixed, "Watcher puts a newly added file first despite its older modification date")
    try fm.removeItem(at: incoming)
    try await until { browser.entries.map(\.name) == mixed }
    defaults.synchronize(); try await verifyRelaunch(root: root, suite: suite, output: output, added: true)
    try check(true, "Added sort, visible column and disabled folders-first survive process restart")
    try capture(window, at: output.appendingPathComponent("native-added-date-mixed.png"))
    browser.viewMenu().first { $0.title == NL("应用到所有文件夹") }?.action?()
    try await until { (defaults.dictionary(forKey: "folderViews") ?? [:]).isEmpty }
    try check(defaults.dictionary(forKey: "defaultFolderView")?["foldersFirst"] as? Bool == false, "Apply to all folders saves disabled folders-first")
    browser.sortMenu().first { $0.title == NL("文件夹优先") }?.action?()
    browser.sortMenu().first { $0.title == NL("文件夹优先") }?.action?()
    try check((defaults.dictionary(forKey: "folderViews") ?? [:]).isEmpty, "Returning to inherited sorting removes the folder override")
    defaults.removeObject(forKey: "folderViews")
    defaults.set(["view": "details", "sort": "future-sort", "ascending": true], forKey: "defaultFolderView")
    let fallback = BrowserController(initial: root, defaults: defaults); browsers.append(fallback)
    try check(fallback.sort == .name && fallback.mode == .details, "Unknown saved sort safely falls back without resetting layout")
    try check(try DirectoryReader.read(root).entries.sorted { $0.id < $1.id } == before.sorted { $0.id < $1.id }, "Created-date UI leaves fixture metadata unchanged")
    try check(try before.filter { !$0.isDirectory }.allSatisfy { try Data(contentsOf: $0.url) == Data($0.name.utf8) }, "Created-date UI leaves fixture data unchanged")
    return checks
  }

  private static func verifyRelaunch(root: URL, suite: String, output: URL, added: Bool = false) async throws {
    let report = output.appendingPathComponent(added ? "added-date-relaunch.json" : "created-date-relaunch.json")
    let process = Process(); process.executableURL = Bundle.main.executableURL
    process.arguments = ["--smoke-test", root.path, "--report", report.path, "--created-date-settings", suite]
    let log = output.appendingPathComponent("created-date-relaunch.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    process.standardOutput = handle; process.standardError = handle
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try await until { !process.isRunning }
    guard process.terminationStatus == 0,
      let result = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any], result["passed"] as? Bool == true else { throw failure("Created-date settings failed after process relaunch; see " + log.path) }
  }

  /// Called only by the explicit smoke-test subprocess, using its parent's disposable suite.
  static func restore(root: URL, suite: String, window: NSWindow) async throws -> [String] {
    guard suite.hasPrefix("local.macexplorer.native-created-date."), UUID(uuidString: String(suite.dropFirst("local.macexplorer.native-created-date.".count))) != nil,
      root.lastPathComponent.hasPrefix("native-created-date-"), let defaults = UserDefaults(suiteName: suite) else { throw failure("Invalid created-date smoke fixture") }
    (window.contentViewController as? BrowserController)?.stopObserving()
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root
    window.contentViewController = browser
    defer { browser.stopObserving() }
    try await until { !browser.loading && browser.entries.count == 4 }
    if defaults.dictionary(forKey: "defaultFolderView")?["sort"] as? String == "added" {
      guard browser.sort == .added, !browser.ascending, !browser.foldersFirst,
        browser.detailColumns.visible.contains("added"), browser.table.sortDescriptors.first?.key == "added",
        browser.entries.map(\.name) == ["new.txt", "Folder", "old10.txt", "old2.txt"] else { throw failure("Added-date preferences did not survive process relaunch") }
      return ["Added-date column and mixed sorting restored in a fresh process"]
    }
    guard defaults.dictionary(forKey: "defaultFolderView")?["sort"] as? String == "created", browser.sort == .created, browser.ascending,
      browser.table.sortDescriptors.first?.key == "created", browser.table.sortDescriptors.first?.ascending == true,
      browser.entries.map(\.name) == ["Folder", "old2.txt", "old10.txt", "new.txt"] else { throw failure("Creation-date preferences/order did not survive process relaunch") }
    return ["Persisted Created default and folder override restored in a fresh process", "Creation-date header and file order restored"]
  }
}
