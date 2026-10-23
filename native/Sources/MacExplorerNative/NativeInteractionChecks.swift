import AppKit
import ExplorerCore

@MainActor
private final class FixtureDrag: NSObject, NSDraggingInfo {
  let draggingDestinationWindow: NSWindow?
  let draggingPasteboard: NSPasteboard
  let draggingLocation: NSPoint
  let draggingSequenceNumber: Int
  var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
  var draggingSource: Any? { nil }
  var draggedImageLocation: NSPoint { draggingLocation }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(row: NSView, y: CGFloat, board: NSPasteboard) {
    draggingDestinationWindow = row.window; draggingLocation = row.convert(NSPoint(x: 45, y: y), to: nil); draggingPasteboard = board; draggingSequenceNumber = board.changeCount
  }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
  func resetSpringLoading() {}
}

private final class FixtureMiddleClick: NSEvent {
  var point = NSPoint.zero
  override var buttonNumber: Int { 2 }
  override var locationInWindow: NSPoint { point }
  override var type: NSEvent.EventType { .otherMouseUp }
}

@MainActor
enum NativeInteractionChecks {
  static func run(source: BrowserController, output: URL) async throws -> [String] {
    guard let app = NSApp.delegate as? ApplicationDelegate else { throw NativeSmoke.Failure(description: "No application delegate") }
    let fm = FileManager.default, root = FileManager.default.temporaryDirectory.appendingPathComponent("native-interactions-\(UUID().uuidString)")
    for folder in ["Applications", "Desktop", "Downloads", "Documents", "Pictures", "Extra", ".Trash", "Package.app"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
    let docs = root.appendingPathComponent("Documents"), extra = root.appendingPathComponent("Extra")
    for i in 0..<120 { try Data("payload \(i)".utf8).write(to: docs.appendingPathComponent("item\(i).txt")) }
    var windows: [NSWindow] = []
    defer { for window in windows { if window.isVisible { window.close() } }; try? fm.removeItem(at: root) }
    let previousHome = source.home; source.home = root
    let window = app.createWindow(tab: BrowserTab(history: [docs]), source: source, at: NSPoint(x: 300, y: 900)); windows.append(window); source.home = previousHome
    guard let browser = window.contentViewController as? BrowserController else { throw NativeSmoke.Failure(description: "No browser in new window") }
    try await until { !browser.loading && browser.entries.count == 120 }
    browser.setView(.details); window.makeKeyAndOrderFront(nil)
    var checks: [String] = []
    func check(_ condition: Bool, _ label: String) throws { guard condition else { throw NativeSmoke.Failure(description: label) }; checks.append(label); print("PASS interaction: \(label)") }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for titles in [["剪切", "复制", "重命名", "移到回收站"], ["Cut", "Copy", "Rename", "Move to Trash"]] {
      ExplorerMenu.show([ExplorerMenuItem(title: "Open")], at: NSPoint(x: window.frame.minX + 50, y: window.frame.maxY - 100), owner: window, quickActions: titles.map { ExplorerMenuItem(title: $0) })
      guard let menu = window.childWindows?.last, let body = menu.contentView else { throw NativeSmoke.Failure(description: "Quick-action menu is visible") }
      let buttons = descendants(body).compactMap { $0 as? NSButton }.filter { titles.contains($0.title) }
      try check(buttons.count == titles.count, "All quick-action buttons are present")
      for button in buttons {
        let textWidth = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
        try check(button.bounds.width >= textWidth + 12, "Quick-action hover background contains \(button.title) with padding")
      }
      ExplorerMenu.dismiss()
    }
    for title in ["项目复选框", "文件扩展名", "隐藏的项目"] {
      let before = browser.viewMenu().flatMap(\.children).first { $0.title == title }!.checked
      ExplorerMenu.present(browser.viewMenu(), below: browser.viewButton)
      guard let parentPanel = window.childWindows?.last, let parentBody = parentPanel.contentView,
            let show = descendants(parentBody).first(where: { $0.accessibilityLabel() == "显示" }) else { throw NativeSmoke.Failure(description: "Show submenu row is present") }
      let hover = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: parentPanel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
      show.mouseEntered(with: hover)
      guard let submenu = window.childWindows?.last, submenu !== parentPanel, let body = submenu.contentView,
            let row = descendants(body).first(where: { $0.accessibilityLabel() == title }) else { throw NativeSmoke.Failure(description: "Show submenu target is present") }
      try check(!submenu.isKeyWindow, "Hover opens a non-key submenu for \(title)")
      let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
      let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: submenu.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
      try check(row.acceptsFirstMouse(for: down), "Submenu accepts the first click on \(title)")
      submenu.sendEvent(down)
      submenu.sendEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: submenu.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!)
      try check(browser.viewMenu().flatMap(\.children).first { $0.title == title }!.checked != before, "One submenu click toggles \(title)")
      browser.viewMenu().flatMap(\.children).first { $0.title == title }!.action?()
      try await until { !browser.loading }
    }
    func place(_ path: String) throws -> ExplorerSidebarRow {
      guard let row = browser.sidebarDocument.subviews.compactMap({ $0 as? ExplorerSidebarRow }).first(where: { $0.placePath == path }) else { throw NativeSmoke.Failure(description: "Missing quick access row \(path)") }; return row
    }
    let defaults = browser.pinnedPaths, downloads = root.appendingPathComponent("Downloads").path
    browser.togglePin(URL(fileURLWithPath: downloads))
    try check(!browser.pinnedPaths.contains(downloads), "Default Quick Access folders can be unpinned")
    browser.togglePin(URL(fileURLWithPath: downloads))
    try check(browser.pinnedPaths.filter { $0 == downloads }.count == 1, "Repinning a default never duplicates it")
    let board = NSPasteboard(name: .init("native-interaction-drag.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.setString(downloads, forType: ExplorerSidebarRow.placeType)
    let first = try place(defaults[0]), drag = FixtureDrag(row: first, y: 1, board: board)
    try check(first.draggingEntered(drag) == .move, "Quick Access reorder uses the row insertion zone")
    try check(first.performDragOperation(drag), "Native sidebar drop accepts pin reorder")
    try check(browser.pinnedPaths.first == downloads, "Reordering changes the visible pinned order")
    try check(QuickAccessState(defaults: browser.defaults).visible(defaultPaths: defaults).first == downloads, "Quick Access ordering persists")
    board.clearContents(); board.writeObjects([extra as NSURL])
    let target = try place(downloads), pinDrag = FixtureDrag(row: target, y: 35, board: board)
    try check(target.draggingEntered(pinDrag) == .copy && target.performDragOperation(pinDrag), "Dropping a folder at the row edge pins without moving it")
    try await until { browser.pinnedPaths.contains(extra.path) }
    try check(fm.fileExists(atPath: extra.path) && browser.pinnedPaths[1] == extra.path, "Pinned folder remains at its original filesystem location")
    try check(await browser.pinFolders([root.appendingPathComponent("Package.app")], at: 0) == false, "Application packages cannot be pinned as folders")
    try check(await browser.pinFolders([root.appendingPathComponent(".Trash")], at: 0) == false, "Trash cannot be pinned through folder drops")
    let incoming = root.appendingPathComponent("incoming.txt"); try Data("incoming payload".utf8).write(to: incoming)
    board.clearContents(); board.writeObjects([incoming as NSURL])
    let destination = try place(downloads), fileDrag = FixtureDrag(row: destination, y: 18, board: board)
    try check(destination.draggingEntered(fileDrag) == .move && destination.performDragOperation(fileDrag), "Sidebar row centre retains move-into-folder behavior")
    try await until { !browser.busy && fm.fileExists(atPath: root.appendingPathComponent("Downloads/incoming.txt").path) }
    try check(!fm.fileExists(atPath: incoming.path), "Sidebar move changes only the temporary fixture")
    try await until { !browser.loading }
    browser.table.selectRowIndexes(IndexSet(integer: 45), byExtendingSelection: false); browser.table.scrollRowToVisible(65)
    window.contentView?.layoutSubtreeIfNeeded()
    let selection = browser.selectedPaths
    try await Task.sleep(nanoseconds: 300_000_000)
    window.contentView?.layoutSubtreeIfNeeded()
    // Compare the refresh with the settled viewport immediately before the external
    // mutation, rather than an earlier pending AppKit selection/scroll adjustment.
    let scroll = browser.tableScroll.contentView.bounds.origin
    try check(browser.selectedPaths == selection && !selection.isEmpty && scroll.y > 100, "External refresh fixture starts with a settled nonempty selection and scrolled viewport")
    try Data("external".utf8).write(to: docs.appendingPathComponent("zz-external.txt"))
    try await until { browser.entries.contains { $0.name == "zz-external.txt" } }
    guard browser.selectedPaths == selection && abs(browser.tableScroll.contentView.bounds.origin.y - scroll.y) < 1 else {
      throw NativeSmoke.Failure(description: "External create refreshes in place without losing selection or scroll; before=\(scroll), after=\(browser.tableScroll.contentView.bounds.origin), selectedBefore=\(selection), selectedAfter=\(browser.selectedPaths)")
    }
    try check(true, "External create refreshes in place without losing selection or scroll")
    let renaming = browser.entries.firstIndex { $0.id == selection.first }!
    browser.table.scrollRowToVisible(renaming); browser.executeAction("rename")
    guard let field = (browser.table.view(atColumn: 0, row: renaming, makeIfNecessary: false) as? NameCell)?.nameLabel, let editor = field.currentEditor() as? NSTextView else { throw NativeSmoke.Failure(description: "No rename editor") }
    let editorRect = field.convert(editor.bounds, from: editor)
    try check(abs(editorRect.midY - field.bounds.midY) < 0.5, "Rename text selection is vertically centered in its input")
    let nameCell = field.superview as! NameCell
    try check(abs(field.frame.minX + editorRect.minX - (nameCell.icon.frame.maxX + 9)) < 0.5, "Rename text keeps the filename leading alignment")
    let previousAppearance = window.appearance
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
      window.appearance = NSAppearance(named: appearance)
      try capture(window, to: output.appendingPathComponent("native-rename-\(name).png"))
    }
    window.appearance = previousAppearance
    editor.string = "Unsubmitted draft.txt"; field.stringValue = "Unsubmitted draft.txt"
    try Data("during rename".utf8).write(to: docs.appendingPathComponent("zz-during-edit.txt"))
    try await Task.sleep(nanoseconds: 700_000_000)
    try check(field.isEditable && editor.string == "Unsubmitted draft.txt", "Automatic refresh does not interrupt an in-progress rename")
    try check(!browser.canDetachTab, "Tab detach is disabled during inline rename")
    _ = browser.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    try await until { browser.entries.contains { $0.name == "zz-during-edit.txt" } }
    try check(!fm.fileExists(atPath: docs.appendingPathComponent("Unsubmitted draft.txt").path), "Cancelled rename remains cancelled after deferred refresh")
    browser.executeAction("settings")
    try await until { ExplorerDialogs.isPresenting(in: window) }
    try Data("during modal".utf8).write(to: docs.appendingPathComponent("zz-modal.txt"))
    try await Task.sleep(nanoseconds: 600_000_000)
    try check(ExplorerDialogs.isPresenting(in: window) && !browser.entries.contains { $0.name == "zz-modal.txt" }, "Directory refresh waits until the modal dialog is dismissed")
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    func descendants(_ window: NSWindow) -> [NSWindow] { (window.childWindows ?? []).flatMap { [$0] + descendants($0) } }
    guard let close = descendants(window).compactMap(\.contentView).flatMap(buttons).first(where: { $0.title == "关闭" && !$0.isHiddenOrHasHiddenAncestor }) else { throw NativeSmoke.Failure(description: "Missing settings close button") }
    close.performClick(nil)
    try await until { browser.entries.contains { $0.name == "zz-modal.txt" } }
    try fm.removeItem(at: docs.appendingPathComponent("zz-modal.txt"))
    try await until { !browser.entries.contains { $0.name == "zz-modal.txt" } }
    try fm.moveItem(at: docs.appendingPathComponent("zz-external.txt"), to: docs.appendingPathComponent("zz-renamed.txt"))
    try await until { browser.entries.contains { $0.name == "zz-renamed.txt" } && !browser.entries.contains { $0.name == "zz-external.txt" } }
    try fm.removeItem(at: docs.appendingPathComponent("zz-renamed.txt"))
    try await until { !browser.entries.contains { $0.name == "zz-renamed.txt" } }
    try check(true, "External rename and removal refresh the native list")
    browser.openTab(at: extra); browser.navigate(to: docs)
    try await until { !browser.loading && browser.entries.count == 121 }
    browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let tab = browser.tabs[browser.activeTab]
    let beforeWindows = app.browserWindows.count
    guard let tabView = browser.tabsDocument.subviews.compactMap({ $0 as? ExplorerTabView }).last else { throw NativeSmoke.Failure(description: "No tab view") }
    let downPoint = tabView.convert(NSPoint(x: 50, y: 18), to: nil), dragPoint = browser.view.convert(NSPoint(x: 360, y: 105), to: nil)
    tabView.mouseDown(with: mouse(.leftMouseDown, point: downPoint, window: window))
    tabView.mouseDragged(with: mouse(.leftMouseDragged, point: dragPoint, window: window))
    try await until { app.browserWindows.count == beforeWindows + 1 }
    guard let detachedWindow = app.browserWindows.last, let detached = detachedWindow.contentViewController as? BrowserController else { throw NativeSmoke.Failure(description: "No detached window") }
    windows.append(detachedWindow)
    try await until { !detached.loading && detached.snapshot != nil }
    try check(detached.tabs[0].id == tab.id && detached.tabs[0].history == tab.history && detached.tabs[0].index == tab.index && detached.selectedPaths == tab.selectedPaths, "Dragging a tab out preserves its identity, history, and selection")
    try check(browser.tabs.count == 1 && window.isVisible, "Tab detach leaves the source window and remaining tab intact")
    detached.back()
    try await until { !detached.loading && detached.directory.path == extra.path }
    try check(browser.directory.path == docs.path, "Detached back navigation never navigates the source window")
    detached.forward()
    try await until { !detached.loading && detached.directory.path == docs.path }
    detached.setView(.tiles)
    browser.navigate(to: extra); try await until { !browser.loading }; browser.setView(.list)
    let saved = browser.defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]]
    try check(saved?[docs.path]?["view"] as? String == "tiles" && saved?[extra.path]?["view"] as? String == "list", "Independent windows preserve each other's saved folder layouts")
    browser.navigate(to: docs); try await until { !browser.loading }; browser.setView(.details)
    try check(detached.pinnedPaths == browser.pinnedPaths, "Detached window restores Quick Access order")
    detached.togglePin(extra)
    try check(!browser.pinnedPaths.contains(extra.path), "Quick Access changes synchronize between windows")
    let newTabMenu = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == #selector(BrowserController.newTab) }
    try check(newTabMenu?.target === detached, "Application menu targets the active detached window")
    if let item = newTabMenu, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    try await until { !detached.loading && detached.tabs.count == 2 }
    try check(browser.tabs.count == 1, "New-tab menu never changes an inactive window")
    guard let closing = detached.tabsDocument.subviews.compactMap({ $0 as? ExplorerTabView }).last else { throw NativeSmoke.Failure(description: "No closeable tab") }
    closing.otherMouseUp(with: mouse(.otherMouseUp, point: closing.convert(NSPoint(x: 40, y: 18), to: nil), window: detachedWindow, button: 2))
    try await until { !detached.loading && detached.tabs.count == 1 }
    try check(true, "Middle-click closes only the clicked tab")
    let count = app.browserWindows.count
    try check(detached.detachTab(id: detached.tabs[0].id, at: NSPoint(x: 600, y: 800)) && app.browserWindows.count == count, "Dragging the sole tab moves the window without creating a duplicate")
    try capture(window, to: output.appendingPathComponent("native-quick-access.png"))
    try capture(detachedWindow, to: output.appendingPathComponent("native-detached-window.png"))
    let refreshes = detached.automaticRefreshCount
    detachedWindow.close()
    try Data("after close".utf8).write(to: docs.appendingPathComponent("zz-after-close.txt"))
    try await until { browser.entries.contains { $0.name == "zz-after-close.txt" } }
    try check(detached.automaticRefreshCount == refreshes && window.isVisible, "Closing one window stops its watcher without stopping other windows")
    try check(try (0..<120).allSatisfy { try Data(contentsOf: docs.appendingPathComponent("item\($0).txt")) == Data("payload \($0)".utf8) }, "All 120 original fixture files remain unchanged")
    return checks
  }
  private static func mouse(_ type: NSEvent.EventType, point: NSPoint, window: NSWindow, button: Int = 0) -> NSEvent {
    if button == 2 { let event = FixtureMiddleClick(); event.point = point; return event }
    return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
  }
  private static func until(_ predicate: () -> Bool) async throws {
    let end = Date().addingTimeInterval(10)
    while !predicate() { guard Date() < end else { throw NativeSmoke.Failure(description: "Timed out during pin/detach/refresh checks") }; try await Task.sleep(nanoseconds: 30_000_000) }
  }
  private static func capture(_ window: NSWindow, to path: URL) throws {
    guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NativeSmoke.Failure(description: "Missing interaction window") }
    view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NativeSmoke.Failure(description: "Missing screenshot") }; try data.write(to: path)
  }
}
