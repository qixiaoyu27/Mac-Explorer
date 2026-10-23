import AppKit
import ExplorerCore

@MainActor
enum NativeColumnChecks {
  private static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Column workflow timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
  }
  private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private static func children(_ window: NSWindow) -> [NSWindow] { (window.childWindows ?? []).flatMap { [$0] + children($0) } }
  private static func click(_ title: String, owner: NSWindow) throws {
    guard let row = children(owner).compactMap(\.contentView).flatMap(descendants).first(where: { $0.accessibilityRole() == .menuItem && $0.accessibilityLabel() == title }), let window = row.window,
      let event = NSEvent.mouseEvent(with: .leftMouseUp, location: row.convert(NSPoint(x: 20, y: 16), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw NativeSmoke.Failure(description: "Missing column menu: " + title) }
    row.mouseUp(with: event)
  }
  private static func headerMenu(_ browser: BrowserController, window: NSWindow) throws {
    guard let header = browser.table.headerView, let event = NSEvent.mouseEvent(with: .rightMouseDown, location: header.convert(NSPoint(x: 30, y: 15), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { throw NativeSmoke.Failure(description: "Missing column header") }
    header.rightMouseDown(with: event)
  }
  private static func capture(_ window: NSWindow, to path: URL) throws {
    guard let view = window.contentView else { throw NativeSmoke.Failure(description: "Missing column view") }; view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NativeSmoke.Failure(description: "Missing column bitmap") }; view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NativeSmoke.Failure(description: "Missing column PNG") }; try data.write(to: path)
  }
  static func run(output: URL) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-columns-" + UUID().uuidString)
    let other = root.appendingPathComponent("Other"), file = root.appendingPathComponent("item.txt")
    try fm.createDirectory(at: other, withIntermediateDirectories: true); try Data("unchanged".utf8).write(to: file)
    let before = try DirectoryReader.read(root).entries
    let suite = "local.macexplorer.native-columns." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl"); defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    let oldKey = NSApp.keyWindow, oldAppearance = NSApp.appearance
    var browsers: [BrowserController] = [], windows: [NSWindow] = []
    let board = NSPasteboard(name: .init(suite))
    defer {
      ExplorerMenu.dismiss(); for browser in browsers { browser.stopObserving() }; for window in windows { ExplorerDialogs.close(in: window); window.close() }
      board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); defaults.synchronize(); try? fm.removeItem(at: root)
      NSApp.appearance = oldAppearance; oldKey?.makeKeyAndOrderFront(nil)
    }
    func makeBrowser() -> (BrowserController, NSWindow) {
      let browser = BrowserController(initial: root, defaults: defaults); browser.home = root; browser.filePasteboard = board; browsers.append(browser)
      let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1260, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentViewController = browser; window.makeKeyAndOrderFront(nil); windows.append(window); return (browser, window)
    }
    let (browser, window) = makeBrowser()
    try await until { !browser.loading && browser.entries.count == 2 }; window.contentView?.layoutSubtreeIfNeeded()
    var checks: [String] = []
    func check(_ value: Bool, _ title: String) throws { guard value else { throw NativeSmoke.Failure(description: title) }; checks.append(title); print("PASS columns: " + title) }
    func column(_ id: String, _ owner: BrowserController? = nil) -> NSTableColumn { (owner ?? browser).table.tableColumns.first { $0.identifier.rawValue == id }! }
    func folder() -> [String: Any] { (defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]])?[root.path] ?? [:] }
    try check(browser.detailColumns.automatic && defaults.dictionary(forKey: "folderViews") == nil, "Legacy folder preferences keep responsive columns without migration writes")
    try check(browser.columnMenu().first { $0.title == NL("名称") }?.enabled == false, "Name remains visible and cannot be unchecked")
    try check(browser.viewMenu().first { $0.title == NL("列") }?.children.count == 6, "View menu exposes the same five columns and reset")
    try headerMenu(browser, window: window); try click(NL("修改日期"), owner: window)
    window.contentView?.layoutSubtreeIfNeeded()
    try check(!browser.detailColumns.automatic && column("modified").isHidden && !column("name").isHidden, "Header context click hides only the chosen column")
    try check(folder()["columns"] != nil && folder()["view"] == nil && folder()["sort"] == nil, "A columns-only folder override survives independently of layout and sorting")
    column("created").width = 222
    try await until { browser.detailColumns.widths["created"] == 222 }
    try check(DetailColumns(propertyList: folder()["columns"])?.widths["created"] == 222, "Native header resize persists the chosen width")
    browser.table.moveColumn(browser.table.column(withIdentifier: .init("created")), toColumn: 1)
    try await until { browser.detailColumns.order[1] == "created" }
    try check(DetailColumns(propertyList: folder()["columns"])?.order[1] == "created", "Native column reorder persists without changing sort")
    browser.table.moveColumn(browser.table.column(withIdentifier: .init("name")), toColumn: 4)
    let rowIndex = browser.entries.firstIndex { $0.url.path == file.path }!
    browser.table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false); browser.executeAction("rename")
    guard let nameCell = browser.table.view(atColumn: browser.table.column(withIdentifier: .init("name")), row: rowIndex, makeIfNecessary: true) as? NameCell,
      let editor = nameCell.nameLabel.currentEditor() as? NSTextView else { throw NativeSmoke.Failure(description: "Missing reordered-name editor") }
    try check(nameCell.nameLabel.isEditable && !browser.canDetachTab, "Inline rename finds Name after it is moved out of the first column")
    _ = browser.control(nameCell.nameLabel, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    if let row = browser.table.rowView(atRow: rowIndex, makeIfNecessary: true) as? FileRowView,
      let currentCell = row.view(atColumn: browser.table.column(withIdentifier: .init("name"))) as? NameCell {
      row.hovered = true; try check(currentCell.checkbox.hovered, "Checkbox hover follows the reordered Name cell"); row.hovered = false
    } else { throw NativeSmoke.Failure(description: "Missing reordered-name row") }
    browser.table.moveColumn(browser.table.column(withIdentifier: .init("name")), toColumn: 0)
    let (second, _) = makeBrowser(); try await until { !second.loading && second.entries.count == 2 }
    try check(second.detailColumns == browser.detailColumns, "A new window restores visibility, order and widths")
    try headerMenu(browser, window: window); try click(NL("创建日期"), owner: window)
    try await until { second.detailColumns == browser.detailColumns }
    try check(!second.detailColumns.visible.contains("created"), "Column choices synchronize into another open window")
    browser.sortMenu().first { $0.title == NL("创建日期") }?.action?()
    try await until { browser.sort == .created && second.sort == .created }
    try check(column("created").isHidden && browser.table.sortDescriptors.first?.key == "created", "Hidden creation date remains available for sorting")
    let custom = browser.detailColumns
    for mode in [ExplorerLayoutMode.icons, .list, .tiles, .content, .details] { browser.setView(mode); window.contentView?.layoutSubtreeIfNeeded(); try check(browser.detailColumns == custom, "Column choices survive layout " + mode.rawValue) }
    browser.navigate(to: other); try await until { !browser.loading && browser.directory.path == other.path }
    try check(browser.detailColumns.automatic, "Unconfigured folders continue to inherit responsive defaults")
    browser.navigate(to: root); try await until { !browser.loading && browser.directory.path == root.path }
    try check(browser.detailColumns == custom && browser.sort == .created, "Returning to a folder restores its independent columns and sort")
    NSApp.appearance = NSAppearance(named: .aqua); window.contentView?.layoutSubtreeIfNeeded(); try capture(window, to: output.appendingPathComponent("native-columns-custom-light.png"))
    for pane in ["", "preview", "details"] {
      browser.paneMode = pane; window.setContentSize(NSSize(width: 800, height: 780)); browser.view.needsLayout = true; window.contentView?.layoutSubtreeIfNeeded()
      let visible = Set(browser.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue })
      try check(visible == custom.visible && browser.detailColumns == custom && browser.tableScroll.hasHorizontalScroller, "Narrow window preserves explicit column choices with pane " + pane)
      let last = browser.table.tableColumns.lastIndex { !$0.isHidden }!
      browser.table.scrollColumnToVisible(last); browser.tableScroll.layoutSubtreeIfNeeded()
      try check(browser.table.rect(ofColumn: last).maxX <= browser.table.visibleRect.maxX + 1, "Horizontal scrolling reaches the last chosen column with pane " + pane)
      browser.table.scrollColumnToVisible(browser.table.column(withIdentifier: .init("name")))
    }
    NSApp.appearance = NSAppearance(named: .darkAqua); try capture(window, to: output.appendingPathComponent("native-columns-narrow-dark.png"))
    browser.paneMode = ""; window.setContentSize(NSSize(width: 1260, height: 780)); browser.view.needsLayout = true; window.contentView?.layoutSubtreeIfNeeded()
    try check(browser.detailColumns == custom && column("created").width == 222, "Window and pane resizing cannot overwrite preferred column widths")
    defaults.synchronize(); try await relaunch(root: root, suite: suite, output: output)
    try check(true, "Fresh process restores columns, widths, order and hidden-column sorting")
    browser.columnMenu().last?.action?(); window.contentView?.layoutSubtreeIfNeeded()
    try check(browser.detailColumns.automatic && folder()["columns"] == nil && folder()["sort"] as? String == "created", "Reset columns restores adaptive layout while preserving sorting")
    browser.columnMenu().first { $0.title == NL("修改日期") }?.action?(); window.contentView?.layoutSubtreeIfNeeded()
    let globalColumns = browser.detailColumns
    browser.viewMenu().first { $0.title == NL("应用到所有文件夹") }?.action?()
    try await until { second.detailColumns == globalColumns }
    try check(DetailColumns(propertyList: defaults.dictionary(forKey: "defaultFolderView")?["columns"]) == globalColumns && (defaults.dictionary(forKey: "folderViews") ?? [:]).isEmpty, "Apply to all folders includes the column group and clears overrides")
    browser.columnMenu().last?.action?(); window.contentView?.layoutSubtreeIfNeeded()
    try check(browser.detailColumns.automatic && DetailColumns(propertyList: folder()["columns"])?.automatic == true, "Reset can override a customized global default without changing other folders")
    browser.executeAction("settings"); try await until { ExplorerDialogs.isPresenting(in: window) }
    guard let picker = children(window).compactMap(\.contentView).flatMap(descendants).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == NL("默认排序") }) else { throw NativeSmoke.Failure(description: "Missing default-sort picker") }
    picker.scrollToVisible(picker.bounds); picker.performClick(nil); try click(NL("修改日期"), owner: window); ExplorerDialogs.close(in: window)
    try check(DetailColumns(propertyList: defaults.dictionary(forKey: "defaultFolderView")?["columns"]) == globalColumns, "Changing a default setting preserves the independent global column group")
    var crowded: [String: [String: Any]] = [:]
    for i in 0..<5000 { crowded["/column-check-unused/\(i)"] = ["columns": globalColumns.propertyList, "lastUsed": Double(i)] }
    defaults.set(crowded, forKey: "folderViews"); browser.columnMenu().first { $0.title == NL("大小") }?.action?()
    let bounded = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    try check(bounded.count == 5000 && bounded[root.path]?["columns"] != nil && bounded["/column-check-unused/0"] == nil, "Columns-only overrides honor the 5000-folder limit and retain the active folder")
    var inherited = defaults.dictionary(forKey: "defaultFolderView")!
    inherited["columns"] = ["version": 99]; defaults.set(inherited, forKey: "defaultFolderView")
    defaults.set([root.path: ["columns": "invalid"]], forKey: "folderViews"); browser.navigate(to: root)
    try await until { !browser.loading }
    try check(browser.detailColumns == DetailColumns() && browser.sort.rawValue == inherited["sort"] as? String, "Malformed folder and unknown global column versions retain the independent sort and safe defaults")
    let after = try DirectoryReader.read(root).entries
    try check(zip(before, after).allSatisfy { $0.id == $1.id && $0.size == $1.size && $0.created == $1.created && $0.modified == $1.modified } && (try Data(contentsOf: file)) == Data("unchanged".utf8), "Column workflows preserve fixture content and file dates")
    return checks
  }
  private static func relaunch(root: URL, suite: String, output: URL) async throws {
    let process = Process(); process.executableURL = Bundle.main.executableURL
    let report = output.appendingPathComponent("columns-relaunch.json"), log = output.appendingPathComponent("columns-relaunch.log")
    process.arguments = ["--smoke-test", root.path, "--report", report.path, "--column-settings", suite]
    FileManager.default.createFile(atPath: log.path, contents: nil); let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
    process.standardOutput = handle; process.standardError = handle; try process.run(); defer { if process.isRunning { process.terminate() } }
    try await until { !process.isRunning }
    guard process.terminationStatus == 0, let data = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any], data["passed"] as? Bool == true else { throw NativeSmoke.Failure(description: "Column relaunch failed") }
  }
  static func restore(root: URL, suite: String, window: NSWindow) async throws -> [String] {
    let prefix = "local.macexplorer.native-columns."
    guard suite.hasPrefix(prefix), UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil, root.lastPathComponent.hasPrefix("native-columns-"), let defaults = UserDefaults(suiteName: suite) else { throw NativeSmoke.Failure(description: "Invalid columns fixture") }
    (window.contentViewController as? BrowserController)?.stopObserving()
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root; window.contentViewController = browser
    try await until { !browser.loading && browser.entries.count == 2 }; window.contentView?.layoutSubtreeIfNeeded()
    guard browser.detailColumns.order[1] == "created", browser.detailColumns.widths["created"] == 222, !browser.detailColumns.visible.contains("created"), !browser.detailColumns.visible.contains("modified"), browser.sort == .created,
      browser.table.tableColumns.first(where: { $0.identifier.rawValue == "created" })?.isHidden == true else { throw NativeSmoke.Failure(description: "Column restart mismatch") }
    browser.stopObserving(); return ["Column intent survives process restart", "Hidden creation date remains the active sort"]
  }
}
