import AppKit
import ExplorerCore

@MainActor
enum NativeLatestChecks {
  static func run(parent: NSWindow) async throws -> [String] {
    var checks = try NativeSelectionChecks.run()
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("native-latest-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    func expect(_ value: Bool, _ message: String) throws {
      guard value else { throw NativeSmoke.Failure(description: message) }
      checks.append(message)
    }
    let folder = root.appendingPathComponent("Fixture", isDirectory: true)
    let nested = folder.appendingPathComponent("Nested", isDirectory: true)
    let archives = root.appendingPathComponent("archives", isDirectory: true)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    try fm.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: false)
    try fm.createDirectory(at: archives, withIntermediateDirectories: false)
    let content = Data("native archive fixture ✓".utf8), sibling = Data("nested preserved".utf8)
    let rootFile = root.appendingPathComponent("root.txt"), childFile = folder.appendingPathComponent("alpha.txt")
    try content.write(to: rootFile); try content.write(to: childFile)
    try sibling.write(to: nested.appendingPathComponent("child.txt"))
    try Data("second".utf8).write(to: nested.appendingPathComponent("second.txt"))
    let compressed = try await Task.detached(priority: .userInitiated) { try NativeArchives.compress([folder, rootFile]) }.value
    let archive = archives.appendingPathComponent("bundle.zip")
    try fm.moveItem(at: compressed, to: archive)
    var results: [FileActionResult] = []
    weak var retained: NativeArchiveWindow?
    retained = NativeArchiveWindow.present(archive: archive, parent: parent, onExtracted: { results.append($0) })
    try await until { retained?.isBusy == false }
    guard let controller = retained, let window = controller.window, let body = window.contentView else { throw NativeSmoke.Failure(description: "Archive preview is retained until closed") }
    defer { controller.close() }
    try expect(window.isVisible, "Archive preview is retained until closed")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func button(_ selector: String) throws -> NSButton {
      guard let button = descendants(body).compactMap({ $0 as? NSButton }).first(where: { $0.action == NSSelectorFromString(selector) && $0.target === controller }) else { throw NativeSmoke.Failure(description: "Missing archive action: \(selector)") }
      return button
    }
    guard let table = descendants(body).compactMap({ $0 as? NSTableView }).first,
          let target = descendants(body).compactMap({ $0 as? NSPopUpButton }).first else { throw NativeSmoke.Failure(description: "Archive native controls are available") }
    let all = try button("selectAllEntries"), up = try button("up")
    let extractSelected = try button("extractSelection"), extractAll = try button("extractEverything")
    func checkbox(_ path: String) throws -> NSButton {
      guard let index = controller.visibleEntryPaths.firstIndex(of: path), let checkbox = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSButton else { throw NativeSmoke.Failure(description: "Missing archive member checkbox: \(path)") }
      return checkbox
    }
    try expect(controller.visibleEntryPaths == ["Fixture", "root.txt"], "Archive preview lists folders before files")
    try expect(!extractSelected.isEnabled && extractAll.isEnabled && !up.isEnabled, "Archive actions reflect initial selection and root directory")
    try expect(target.numberOfItems == 3, "Archive extraction offers named, current, and chosen folders")
    all.performClick(nil)
    try expect(controller.selectedEntryPaths == ["Fixture", "root.txt"] && extractSelected.isEnabled, "Native archive Select All checks current directory entries")
    try expect(controller.enterDirectory("Fixture"), "Native archive opens an internal directory")
    try expect(controller.visibleEntryPaths == ["Fixture/empty", "Fixture/Nested", "Fixture/alpha.txt"], "Internal archive directories include empty folders")
    try expect(!controller.enterDirectory("Fixture/alpha.txt"), "File rows cannot be treated as archive directories")
    try expect(try checkbox("Fixture/alpha.txt").state == .on, "Selected ancestor checks descendant rows")
    try checkbox("Fixture/alpha.txt").performClick(nil)
    try expect(try checkbox("Fixture/alpha.txt").state == .off && checkbox("Fixture/Nested").state == .on && checkbox("Fixture/empty").state == .on, "Unchecking a descendant preserves selected siblings and empty folders")
    try expect(!controller.selectedEntryPaths.contains("Fixture") && controller.selectedEntryPaths.contains("root.txt"), "Archive member exclusions retain selections outside the current directory")
    try expect(controller.enterDirectory("Fixture/Nested"), "Archive browsing reaches nested directories")
    table.selectRowIndexes([0], byExtendingSelection: false)
    guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { throw NativeSmoke.Failure(description: "Cannot create archive keyboard fixture") }
    table.keyDown(with: space)
    try expect(try checkbox("Fixture/Nested/child.txt").state == .off && checkbox("Fixture/Nested/second.txt").state == .on, "Space toggles highlighted archive members")
    up.performClick(nil); up.performClick(nil)
    try expect(controller.visibleEntryPaths == ["Fixture", "root.txt"] && !up.isEnabled, "Archive Up returns to the root")
    all.performClick(nil)
    try expect(controller.selectedEntryPaths == ["Fixture", "root.txt"], "Select All resolves a partial directory selection")
    all.performClick(nil)
    try expect(controller.selectedEntryPaths.isEmpty && !extractSelected.isEnabled, "Native archive Select All can clear selection")
    try checkbox("root.txt").performClick(nil)
    target.selectItem(at: 1); extractSelected.performClick(nil)
    try await until { results.count == 1 && !controller.isBusy }
    try expect(results[0].errors.isEmpty && results[0].succeeded.map(\.lastPathComponent) == ["root.txt"] && results[0].changes.count == 1, "Archive selection extraction reaches native filesystem operations and undo records")
    try expect(try Data(contentsOf: archives.appendingPathComponent("root.txt")) == content && !fm.fileExists(atPath: archives.appendingPathComponent("Fixture").path), "Archive window extracts only checked members")
    extractSelected.performClick(nil)
    try await until { results.count == 2 && !controller.isBusy }
    try expect(results[1].succeeded.isEmpty && results[1].errors.count == 1, "Archive window reports destination collisions")
    try expect(try Data(contentsOf: archives.appendingPathComponent("root.txt")) == content, "Archive collision preserves existing bytes")
    target.selectItem(at: 0); extractAll.performClick(nil)
    try await until { results.count == 3 && !controller.isBusy }
    let extracted = archives.appendingPathComponent("bundle")
    try expect(results[2].errors.isEmpty && results[2].succeeded.map(\.path) == [extracted.resolvingSymlinksInPath().path], "Archive window extracts all into its named folder")
    try expect(try Data(contentsOf: extracted.appendingPathComponent("Fixture/Nested/child.txt")) == sibling && Data(contentsOf: extracted.appendingPathComponent("root.txt")) == content, "Named extraction includes nested and root members")
    try expect(try Data(contentsOf: rootFile) == content && Data(contentsOf: childFile) == content, "Native archive window operations preserve source files")
    window.setContentSize(NSSize(width: 650, height: 380)); body.layoutSubtreeIfNeeded()
    try expect(extractAll.frame.minX >= 0 && extractAll.frame.maxX <= body.bounds.width && table.enclosingScrollView!.frame.height > 150, "Archive controls fit the minimum window size")
    controller.close()
    checks += try await browserPreferencesAndKeys(root: root)
    return checks
  }

  private static func browserPreferencesAndKeys(root: URL) async throws -> [String] {
    let fm = FileManager.default, suite = "MacExplorer.NativeLatestChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw NativeSmoke.Failure(description: "Cannot create isolated browser preferences") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let home = root.appendingPathComponent("browser-home"), docs = home.appendingPathComponent("Documents")
    for name in ["Documents", "Desktop", "Downloads", ".Trash"] { try fm.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true) }
    try Data("visible".utf8).write(to: docs.appendingPathComponent("document.txt")); try Data("hidden".utf8).write(to: docs.appendingPathComponent(".secret"))
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    defaults.set(true, forKey: "extensions")
    let first = BrowserController(initial: docs, defaults: defaults), second = BrowserController(initial: docs, defaults: defaults)
    first.home = home; second.home = home; first.testTrashDirectory = home.appendingPathComponent(".Trash"); second.testTrashDirectory = first.testTrashDirectory
    let firstWindow = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 980, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let secondWindow = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 980, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    firstWindow.isReleasedWhenClosed = false; secondWindow.isReleasedWhenClosed = false
    firstWindow.contentViewController = first; secondWindow.contentViewController = second
    let previousMenu = NSApp.mainMenu
    defer {
      ExplorerDialogs.close(in: firstWindow); ExplorerDialogs.close(in: secondWindow)
      first.stopObserving(); second.stopObserving(); firstWindow.close(); secondWindow.close(); NSApp.mainMenu = previousMenu
    }
    NSApp.mainMenu = nil
    firstWindow.makeKeyAndOrderFront(nil); secondWindow.orderFront(nil); first.reload(); second.reload()
    try await until { !first.loading && !second.loading && first.entries.count == 1 && second.entries.count == 1 }
    var checks: [String] = []
    func expect(_ value: Bool, _ message: String) throws { guard value else { throw NativeSmoke.Failure(description: message) }; checks.append(message) }
    defaults.set(true, forKey: "showHidden"); defaults.set(false, forKey: "extensions"); defaults.set(true, forKey: "checkboxes")
    defaults.set(["view": "tiles", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    defaults.set([String: [String: Any]](), forKey: "folderViews")
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    try await until { [first, second].allSatisfy { $0.showHidden && !$0.extensions && $0.checkboxes && $0.mode == .tiles && $0.entries.count == 2 } }
    try expect(true, "Hidden files, extensions, checkboxes and default view synchronize across same-suite windows")
    firstWindow.contentView?.layoutSubtreeIfNeeded(); secondWindow.contentView?.layoutSubtreeIfNeeded()
    try await until { !first.collection.visibleItems().isEmpty && !second.collection.visibleItems().isEmpty }
    func checkHover(_ resolve: () -> (NSView, ExplorerCheckbox)) throws {
      var (view, checkbox) = resolve()
      func hover(_ value: Bool) {
        (view as? ItemSurface)?.hovered = value
        (view as? FileRowView)?.hovered = value
      }
      hover(false)
      try expect(checkbox.isHidden == (checkbox.state != .on), "Only selected item checkboxes remain visible without hover")
      let frame = checkbox.frame
      hover(true)
      try expect(!checkbox.isHidden && checkbox.frame == frame, "Hover reveals the item checkbox without shifting layout")
      if checkbox.state == .on { checkbox.performClick(nil); (view, checkbox) = resolve() }
      checkbox.performClick(nil)
      (view, checkbox) = resolve()
      try expect(checkbox.state == .on, "Hovered checkbox still selects the item")
      hover(false)
      try expect(!checkbox.isHidden && checkbox.state == .on, "Leaving keeps a checked checkbox visible and preserves selection")
      checkbox.state = .off
      try expect(checkbox.isHidden && checkbox.state == .off, "Programmatic deselection without hover hides the checkbox immediately")
      checkbox.state = .on
      try expect(!checkbox.isHidden, "Programmatic selection reveals the checkbox without hover")
      checkbox.available = false; hover(true)
      try expect(checkbox.isHidden, "Disabled item checkboxes stay hidden during hover")
      hover(false)
    }
    for browser in [first, second] {
      let items = browser.collection.visibleItems().compactMap { $0 as? IconItem }
      try expect(items.contains(where: { $0.nameLabel.stringValue == "document" }) && items.allSatisfy { $0.checkbox.available }, "Synchronized preferences update real collection labels and checkboxes")
      if let path = items.first?.view.toolTip {
        try checkHover {
          let item = browser.collection.visibleItems().compactMap { $0 as? IconItem }.first { $0.view.toolTip == path }!
          return (item.view, item.checkbox)
        }
      }
    }
    defaults.set(false, forKey: "showHidden"); defaults.set(true, forKey: "extensions"); defaults.set(false, forKey: "checkboxes")
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    try await until { [first, second].allSatisfy { !$0.showHidden && $0.extensions && !$0.checkboxes && $0.mode == .details && $0.entries.count == 1 } }
    try expect(true, "Reverting shared preferences refreshes both existing windows")
    first.checkboxes = true; first.table.reloadData(); firstWindow.contentView?.layoutSubtreeIfNeeded()
    guard first.table.rowView(atRow: 0, makeIfNecessary: true) != nil, let cell = first.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NameCell else { throw NativeSmoke.Failure(description: "Missing checkbox row") }
    cell.layoutSubtreeIfNeeded()
    try checkHover {
      let currentRow = first.table.rowView(atRow: 0, makeIfNecessary: true)!
      let currentCell = first.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NameCell
      currentCell.layoutSubtreeIfNeeded()
      return (currentRow, currentCell.checkbox)
    }
    first.checkboxes = false; first.table.reloadData()
    firstWindow.makeKeyAndOrderFront(nil); first.table.selectRowIndexes([0], byExtendingSelection: false); first.focusSearch()
    guard let editor = first.search.currentEditor() as? NSTextView else { throw NativeSmoke.Failure(description: "Search field has a native text editor") }
    editor.string = "unsubmitted search draft"; first.search.stringValue = editor.string
    let beforeSelection = first.selectedPaths, beforeFiles = try fm.contentsOfDirectory(atPath: docs.path), beforeTabs = first.tabs.count
    func deliver(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags) async throws {
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: firstWindow.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key.lowercased(), isARepeat: false, keyCode: code) else { throw NativeSmoke.Failure(description: "Cannot create browser keyboard fixture") }
      NSApp.postEvent(event, atStart: true)
      if let queued = NSApp.nextEvent(matching: .keyDown, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { NSApp.sendEvent(queued) }
      try await Task.sleep(nanoseconds: 60_000_000)
    }
    try await deliver("a", code: 0, flags: .command)
    try await deliver("N", code: 45, flags: [.command, .shift])
    try expect(first.selectedPaths == beforeSelection && first.tabs.count == beforeTabs && !ExplorerDialogs.isPresenting(in: firstWindow), "Text editing shortcuts do not select files or start file operations")
    try expect(try fm.contentsOfDirectory(atPath: docs.path) == beforeFiles && first.search.currentEditor() === editor, "File shortcuts preserve the active text editor and fixture directory")
    firstWindow.makeFirstResponder(first.table)
    first.executeAction("settings")
    try await until { ExplorerDialogs.isPresenting(in: firstWindow) }
    let beforeDirectory = first.directory, mode = first.mode
    try await deliver("t", code: 17, flags: .command)
    try await deliver("H", code: 4, flags: [.command, .shift])
    try await deliver("N", code: 45, flags: [.command, .shift])
    try expect(first.tabs.count == beforeTabs && first.directory == beforeDirectory && first.mode == mode && ExplorerDialogs.isPresenting(in: firstWindow), "Settings modal blocks tab, fixed-navigation and file shortcuts")
    ExplorerDialogs.close(in: firstWindow)
    try await until { !ExplorerDialogs.isPresenting(in: firstWindow) }
    firstWindow.makeFirstResponder(first.table)
    try await deliver("t", code: 17, flags: .command)
    try await until { first.tabs.count == beforeTabs + 1 && !first.loading }
    try expect(true, "Closing settings restores the real key-monitor shortcut path")
    return checks
  }

  private static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !predicate() {
      guard Date() < deadline else { throw NativeSmoke.Failure(description: "Latest native integration check timed out") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }
}
