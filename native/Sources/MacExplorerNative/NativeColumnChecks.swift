import AppKit
import ExplorerCore

@MainActor
enum NativeColumnChecks {
  private final class SidebarHoverWindow: NSWindow {
    var pointerLocation = NSPoint.zero
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointerLocation }
  }

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

  static func runScrollbars(browser: BrowserController, window: NSWindow) async throws -> [String] {
    var checks: [String] = []
    func check(_ condition: Bool, _ title: String) throws {
      guard condition else { throw NativeSmoke.Failure(description: title) }
      checks.append(title)
    }
    let pane = browser.content, scroll = pane.scroll, table = browser.table
    let h = pane.horizontalScroller, v = pane.verticalScroller
    let name = table.tableColumn(withIdentifier: .init("name"))!
    let initialMode = browser.mode, initialIconSize = browser.iconSize
    func layout() { window.contentView?.layoutSubtreeIfNeeded() }
    func hoverEvent(for scroller: ExplorerScroller) -> NSEvent {
      let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
      return NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }
    func checkAutoHide(_ scroller: ExplorerScroller, name: String) async throws {
      let frame = scroller.frame, rect = scroller.thumbRect
      let event = hoverEvent(for: scroller)
      guard let track = scroller.layer, let thumb = track.sublayers?.first else {
        throw NativeSmoke.Failure(description: "Missing \(name) thumb layer")
      }
      scroller.mouseExited(with: event)
      try await until { (thumb.presentation() ?? thumb).opacity == 0 }
      scroller.mouseEntered(with: event)
      try await until { (thumb.presentation() ?? thumb).opacity == 1 }
      scroller.mouseExited(with: event)
      try await until { (thumb.presentation() ?? thumb).opacity == 0 }
      try check(scroller.thumbRect == rect && scroller.frame == frame && track.backgroundColor == nil,
                "\(name) reveals and fades a fixed-size thumb on a transparent track")
    }
    browser.setView(.details); layout()
    defer {
      browser.columnMenu().last?.action?()
      browser.setView(initialMode, size: initialIconSize); layout()
    }
    try check(h.isHidden && !v.isHidden, "Details reserves only the right track when the columns fit")
    let wideWindowSize = browser.view.bounds.size
    let defaultColumns = browser.detailColumns
    window.setContentSize(NSSize(width: 800, height: wideWindowSize.height)); layout()
    let narrowColumns = table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
    try check(narrowColumns == DetailColumns.identifiers.filter { DetailColumns().visible.contains($0) } && browser.detailColumns == defaultColumns &&
              !h.isHidden && h.isEnabled && h.layer?.sublayers?.first?.opacity == 1,
              "Narrow Details keeps the default columns and reveals the new horizontal scrollbar")
    let lastColumn = table.numberOfColumns - 1
    table.scrollColumnToVisible(lastColumn)
    try check(h.doubleValue > 0 && table.rect(ofColumn: lastColumn).maxX <= table.visibleRect.maxX + 1,
              "Horizontal scrolling reaches the last default column in a narrow window")
    window.setContentSize(wideWindowSize); layout()
    try check(h.isHidden && browser.detailColumns == defaultColumns,
              "Widening Details releases the horizontal track without changing column preferences")
    name.width = 1600
    try await until { browser.detailColumns.widths["name"] == 1600 }
    browser.view.needsLayout = true; layout()
    let visible = pane.fileViewport
    try check(h.superview === pane && v.superview === pane && !h.isHidden && !v.isHidden &&
              h.frame.minY == visible.maxY && v.frame.minX == visible.maxX && !h.frame.intersects(v.frame) &&
              !scroll.hasHorizontalScroller && !scroll.hasVerticalScroller,
              "Details places both scrollers outside the file viewport with a separate corner")
    try check(h.frame.height == ExplorerScroller.thickness && v.frame.width == ExplorerScroller.thickness && [h, v].allSatisfy {
      let thumb = $0.thumbRect
      return !thumb.isEmpty && $0.bounds.contains(thumb)
    }, "Both reserved tracks contain their thumbs")
    try await checkAutoHide(h, name: "Details horizontal scrollbar")
    try await checkAutoHide(v, name: "Details vertical scrollbar")
    guard let header = table.headerView, let headerClip = header.superview else {
      throw NativeSmoke.Failure(description: "Details scrollbar fixture has a pinned header")
    }
    let headerFrame = pane.convert(headerClip.bounds, from: headerClip)
    try check(headerFrame.maxX == visible.maxX && headerFrame.maxY == visible.minY && !v.frame.intersects(headerFrame),
              "The pinned header ends at the right track and the top of the file rows")
    let origin = scroll.contentView.bounds.origin
    let column = table.column(withIdentifier: name.identifier)
    let headerY = pane.convert(header.bounds, from: header).minY
    for scroller in [h, v] {
      let thumb = scroller.thumbRect
      let start = NSPoint(x: thumb.midX, y: thumb.midY)
      let end = scroller === h ? NSPoint(x: start.x + 64, y: start.y) : NSPoint(x: start.x, y: start.y + 64)
      func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: scroller.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
      }
      NSApp.postEvent(mouse(.leftMouseUp, at: end), atStart: true)
      NSApp.postEvent(mouse(.leftMouseDragged, at: end), atStart: true)
      scroller.mouseDown(with: mouse(.leftMouseDown, at: start))
    }
    let moved = scroll.contentView.bounds.origin
    try check(moved.x > origin.x && moved.y > origin.y && h.doubleValue > 0 && v.doubleValue > 0 &&
              abs(pane.convert(header.headerRect(ofColumn: column), from: header).minX -
                  pane.convert(table.rect(ofColumn: column), from: table).minX) < 1 &&
              pane.convert(header.bounds, from: header).minY == headerY,
              "Dragging each thumb moves its axis and keeps the header aligned horizontally and pinned vertically")
    for scroller in [h, v] {
      let point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
      let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      try check(pane.pointerTarget(at: event) == nil, "The \(scroller === h ? "bottom" : "right") track cannot start file marquee selection")
    }
    pane.scrollTo(origin)
    for scroller in [h, v] { scroller.mouseExited(with: hoverEvent(for: scroller)) }
    try await until { [h, v].allSatisfy { $0.layer?.sublayers?.first?.opacity == 0 } }
    guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -3, wheel2: -4, wheel3: 0),
          let event = NSEvent(cgEvent: wheel) else {
      throw NativeSmoke.Failure(description: "Could not construct a wheel event for the scrollbar fixture")
    }
    h.scrollWheel(with: event)
    try await until {
      let wheeled = scroll.contentView.bounds.origin
      return wheeled.x > origin.x && wheeled.y > origin.y && h.doubleValue > 0 && v.doubleValue > 0
    }
    try check([h, v].allSatisfy { $0.layer?.sublayers?.first?.opacity == 1 },
              "Wheel input over a track moves the shared viewport and reveals both thumbs")
    browser.setView(.list); layout()
    try check(!h.isHidden && v.isHidden && h.frame.minY == pane.fileViewport.maxY && pane.fileViewport.width == pane.bounds.width,
              "Ungrouped List reserves only the bottom track")
    browser.setView(.icons, size: 128); layout()
    try check(h.isHidden && !v.isHidden && v.frame.minX == pane.fileViewport.maxX && pane.fileViewport.height == pane.bounds.height,
              "Icons reserve only the right track")
    let windowSize = browser.view.bounds.size
    window.setContentSize(NSSize(width: windowSize.width, height: 480)); layout()
    defer { window.setContentSize(windowSize); layout() }
    guard let sidebarTrack = browser.sidebarScroll.verticalScroller as? ExplorerScroller else {
      throw NativeSmoke.Failure(description: "The shortcut sidebar has the shared scrollbar")
    }
    try check(sidebarTrack.frame.width == ExplorerScroller.thickness && browser.sidebarDocument.frame.width == browser.sidebarScroll.contentSize.width,
              "The overflowing shortcut sidebar reserves the shared track beside the rows")
    guard let sidebarRow = browser.sidebarDocument.subviews.first(where: { $0 is ExplorerSidebarRow }),
          let sidebarDivider = browser.sidebarDocument.subviews.first(where: { $0.identifier?.rawValue == "divider" }) else {
      throw NativeSmoke.Failure(description: "Missing shortcut sidebar row or divider")
    }
    try check(sidebarRow.frame.maxX == browser.sidebarDocument.bounds.maxX &&
              browser.sidebarScroll.bounds.maxX - sidebarDivider.frame.maxX == sidebarDivider.frame.minX,
              "Sidebar rows use the reserved track as their right inset and dividers keep equal margins")
    try await checkAutoHide(sidebarTrack, name: "Shortcut sidebar scrollbar")
    let sidebarClip = browser.sidebarScroll.contentView
    let sidebarOrigin = sidebarClip.bounds.origin
    sidebarClip.scroll(to: NSPoint(x: sidebarOrigin.x, y: sidebarOrigin.y + 36))
    browser.sidebarScroll.reflectScrolledClipView(sidebarClip)
    try check(sidebarClip.bounds.origin.y > sidebarOrigin.y && sidebarTrack.layer?.sublayers?.first?.opacity == 1,
              "Scrolling the shortcut sidebar reveals its thumb")
    let hoverBounds = NSRect(x: 0, y: 0, width: 180, height: 120)
    let hoverWindow = SidebarHoverWindow(contentRect: hoverBounds, styleMask: .borderless, backing: .buffered, defer: false)
    let hoverScroll = ExplorerSidebarScrollView(frame: hoverBounds)
    hoverWindow.contentView?.addSubview(hoverScroll)
    let hoverDocument = SurfaceView(frame: NSRect(x: 0, y: 0, width: hoverBounds.width, height: 240))
    let hoverRows = (0..<5).map { index in
      let row = ExplorerSidebarRow(title: "Folder \(index)", icon: "folder", onOpen: {})
      row.frame = NSRect(x: 8, y: 8 + CGFloat(index) * 36, width: 140, height: 24)
      hoverDocument.addSubview(row)
      return row
    }
    hoverScroll.documentView = hoverDocument
    let hoverClip = hoverScroll.contentView
    hoverWindow.pointerLocation = hoverDocument.convert(NSPoint(x: 35, y: hoverRows[0].frame.midY), to: nil)
    hoverScroll.reflectScrolledClipView(hoverClip)
    let beforeScroll = hoverRows.filter(\.hovered)
    let hoverOrigin = hoverClip.bounds.origin
    hoverClip.scroll(to: NSPoint(x: hoverOrigin.x, y: hoverOrigin.y + 36))
    hoverScroll.reflectScrolledClipView(hoverClip)
    let afterScroll = hoverRows.filter(\.hovered)
    hoverClip.scroll(to: NSPoint(x: hoverOrigin.x, y: hoverOrigin.y + 52))
    hoverScroll.reflectScrolledClipView(hoverClip)
    try check(beforeScroll == [hoverRows[0]] && afterScroll == [hoverRows[1]] && hoverRows.allSatisfy { !$0.hovered },
              "A stationary pointer transfers sidebar hover on scroll and clears it over a gap")

    let detached = FilePaneSurface(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 295, height: 220))
    detached.install(document)
    detached.layoutViewport(filesVisible: true) {}
    try check(!detached.horizontalScroller.isHidden && !detached.verticalScroller.isHidden,
              "Space reserved for one track can expose overflow on the other axis")
    detached.setFrameSize(NSSize(width: 310, height: 230))
    detached.layoutViewport(filesVisible: true) {}
    try check(detached.horizontalScroller.isHidden && detached.verticalScroller.isHidden && detached.scroll.frame == detached.bounds,
              "When the document fits, both tracks return their space to the viewport")
    return checks
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
    try check(browser.viewMenu().first { $0.title == NL("列") }?.children.count == 7, "View menu exposes the same six columns and reset")
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
      try check(visible == custom.visible && browser.detailColumns == custom, "Narrow window preserves explicit column choices with pane " + pane)
      let last = browser.table.tableColumns.lastIndex { !$0.isHidden }!
      browser.table.scrollColumnToVisible(last); browser.fileScroll.layoutSubtreeIfNeeded()
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
