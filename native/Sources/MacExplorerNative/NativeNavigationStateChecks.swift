import AppKit
import ExplorerCore

@MainActor
enum NativeNavigationStateChecks {
  static func run(showsWindows: Bool = true) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-navigation-state-" + UUID().uuidString)
    for i in 0..<320 { try fm.createDirectory(at: root.appendingPathComponent(String(format: "Folder %03d", i)), withIntermediateDirectories: true) }
    let child = root.appendingPathComponent("Folder 220")
    for i in 0..<120 { try Data("fixture".utf8).write(to: child.appendingPathComponent(String(format: "Item %03d.txt", i))) }
    let single = root.appendingPathComponent("Folder 000"), pair = single.appendingPathComponent("Only folder")
    try fm.createDirectory(at: pair.appendingPathComponent("First folder"), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: pair.appendingPathComponent("Second.txt"))
    let suite = "local.macexplorer.navigation-state." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    defaults.set(false, forKey: "versionControl")
    let key = NSApp.keyWindow
    let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 1100, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite)); window.contentViewController = browser
    if showsWindows { window.makeKeyAndOrderFront(nil) } else { browser.reload() }
    defer { browser.stopObserving(); window.close(); if showsWindows { key?.makeKeyAndOrderFront(nil) }; browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ ok: Bool, _ text: String) throws { guard ok else { throw NativeSmoke.Failure(description: text) }; checks.append(text); print("PASS navigation state: " + text) }
    func loaded(_ target: URL) async throws {
      let deadline = Date().addingTimeInterval(10)
      while browser.loading || browser.directory.path != target.path || browser.snapshot?.directory.path != target.path {
        guard Date() < deadline else { throw NativeSmoke.Failure(description: "Navigation load timed out: target=\(target.lastPathComponent), current=\(browser.directory.lastPathComponent), loading=\(browser.loading), entries=\(browser.entries.count), error=\(browser.lastError ?? "none")") }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      window.contentView?.layoutSubtreeIfNeeded(); browser.collection.layoutSubtreeIfNeeded()
    }
    func scroll() -> NSScrollView { browser.fileScroll }
    func frame(_ index: Int) -> NSRect { browser.mode == .details ? browser.table.rect(ofRow: index) : browser.collectionLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame }
    func origin() -> NSPoint { scroll().contentView.bounds.origin }
    func top() -> NSPoint { NSPoint(x: -scroll().contentInsets.left, y: browser.mode == .details ? -(browser.table.headerView?.frame.height ?? 0) : 0) }
    func firstRowVisible() -> Bool {
      guard browser.table.numberOfRows > 0 else { return false }
      let row = browser.table.rect(ofRow: 0), visible = browser.table.visibleRect
      let headerBottom = browser.table.headerView.map { browser.table.convert($0.bounds, from: $0).maxY } ?? visible.minY
      return row.minY >= max(visible.minY, headerBottom) && row.maxY <= visible.maxY
    }
    func close(_ a: NSPoint, _ b: NSPoint) -> Bool { abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2 }
    func position(_ index: Int) -> NSPoint {
      let rect = frame(index)
      browser.content.scrollTo(NSPoint(x: rect.minX - 50, y: rect.minY - 70))
      return origin()
    }
    func select(_ path: String) { browser.selectedPaths = [path]; browser.updateMode(persist: false); window.contentView?.layoutSubtreeIfNeeded() }
    try await loaded(root)
    try check(browser.mode == .details && firstRowVisible(), "Default Details displays the complete first folder below its header on initial load")
    for compact in [false, true] {
      browser.compact = compact; browser.updateMode(persist: false)
      for target in [single, pair] {
        browser.openTab(at: target); try await loaded(target)
        try check(firstRowVisible(), "Details with compact=\(compact) shows the complete first row in a \(browser.entries.count)-item folder")
        browser.reload(); try await loaded(target)
        try check(firstRowVisible(), "Refreshing a short Details folder preserves a fully visible first row")
        browser.closeTab(); try await loaded(root)
      }
    }
    browser.compact = false; browser.updateMode(persist: false)
    let layouts: [(ExplorerLayoutMode, CGFloat, String)] = [(.details,64,"details"),(.icons,128,"extra-large icons"),(.icons,96,"large icons"),(.icons,64,"medium icons"),(.icons,32,"small icons"),(.list,32,"list"),(.tiles,64,"tiles"),(.content,64,"content")]
    for (layout, size, title) in layouts {
      browser.navigate(to: root); try await loaded(root); browser.setView(layout, size: size); window.contentView?.layoutSubtreeIfNeeded()
      select(child.path); let parentPoint = position(220)
      try check(parentPoint.x > 100 || parentPoint.y > 100, title + ": fixture genuinely scrolls away from the first page; origin=\(parentPoint), document=\(scroll().documentView!.bounds.size), frame=\(scroll().documentView!.frame.size), layout=\(browser.collectionLayout.collectionViewContentSize), target=\(frame(220)), mode=\(browser.mode.rawValue), mask=\(browser.collection.autoresizingMask.rawValue), owner=\(browser.collection.collectionViewLayout === browser.collectionLayout)")
      browser.openSelected(); try await loaded(child)
      try check(close(origin(), top()) && (layout != .details || firstRowVisible()), title + ": entering a folder starts at its actual top with the first row clear of the header")
      browser.setView(layout, size: size); window.contentView?.layoutSubtreeIfNeeded()
      let item = browser.entries[80].id; select(item); let childPoint = position(80)
      browser.back(); try await loaded(root)
      try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], title + ": Back restores the parent scroll and selects the entered folder")
      browser.forward(); try await loaded(child)
      try check(close(origin(), childPoint) && browser.selectedPaths == [item], title + ": Forward restores its own scroll and selection")
      browser.up(); try await loaded(root)
      try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], title + ": Up restores the same parent position and folder selection")
      browser.openSelected(); try await loaded(child); browser.navigate(to: root); try await loaded(root)
      try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], title + ": ancestor breadcrumb navigation restores the parent state")
    }
    browser.setView(.details); select(child.path); let parentPoint = position(220)
    browser.openTab(at: root); try await loaded(root)
    try check(close(origin(), top()) && firstRowVisible() && browser.selectedPaths.isEmpty, "A new Details tab starts independently with a fully visible first row")
    let other = root.appendingPathComponent("Folder 070"); select(other.path); let otherPoint = position(70)
    browser.switchTab(to: 0); try await loaded(root)
    try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], "Switching back restores the first tab scroll and selection")
    browser.switchTab(to: 1); try await loaded(root)
    try check(close(origin(), otherPoint) && browser.selectedPaths == [other.path], "Tabs at the same directory do not overwrite each other's state")
    browser.closeTab(); try await loaded(root)
    try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], "Closing the active tab restores the remaining tab state")
    browser.openSelected(); browser.back(); try await loaded(root)
    try await Task.sleep(nanoseconds: 120_000_000)
    try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], "An immediately cancelled folder load cannot overwrite the returned parent state")
    browser.reload(); try await loaded(root)
    try check(close(origin(), parentPoint) && browser.selectedPaths == [child.path], "Explicit refresh preserves the current scroll and selection")
    // A new history branch must not inherit discarded forward-entry selection.
    browser.openSelected(); try await loaded(child); browser.back(); try await loaded(root)
    browser.navigate(to: other); try await loaded(other)
    try check(browser.selectedPaths.isEmpty && close(origin(), top()), "Branching history clears discarded forward-location state")
    browser.up(); try await loaded(root)
    try check(browser.selectedPaths == [other.path] && browser.table.visibleRect.intersects(frame(70)), "Up reveals an ancestor's actual immediate child even when it was outside the saved viewport")
    browser.navigate(to: root); try await loaded(root); browser.setView(.details); select(child.path); let mixedPoint = position(220)
    browser.openSelected(); try await loaded(child); browser.setView(.list); window.contentView?.layoutSubtreeIfNeeded()
    select(browser.entries[80].id); let mixedChildPoint = position(80)
    browser.back(); try await loaded(root)
    try check(browser.mode == .details && close(origin(), mixedPoint) && browser.selectedPaths == [child.path], "A horizontal child view does not leak its coordinates into the Details parent")
    browser.forward(); try await loaded(child)
    try check(browser.mode == .list && close(origin(), mixedChildPoint), "Returning to a different child layout restores that layout's horizontal position")
    browser.up(); try await loaded(root)
    select(child.path); _ = position(220)
    let anchorIndex = browser.table.rows(in: browser.table.visibleRect).location, anchor = browser.entries[anchorIndex].id
    let offset = frame(anchorIndex).minY - origin().y
    browser.openSelected(); try await loaded(child)
    let inserted = root.appendingPathComponent("Folder 000-extra"); try fm.createDirectory(at: inserted, withIntermediateDirectories: false)
    window.setContentSize(NSSize(width: 920, height: 560)); browser.back(); try await loaded(root)
    guard let moved = browser.entries.firstIndex(where: { $0.id == anchor }) else { throw NativeSmoke.Failure(description: "Missing stable viewport anchor") }
    try check(abs((frame(moved).minY - origin().y) - offset) < 2 && browser.selectedPaths == [child.path], "Insertion above the viewport and a smaller window retain the visible item anchor and entered child")
    try fm.removeItem(at: inserted); browser.reload(); try await loaded(root)
    browser.openTab(at: child); try await loaded(child); browser.up(); try await loaded(root)
    let childIndex = browser.entries.firstIndex(where: { $0.id == child.path })!
    try check(browser.selectedPaths == [child.path] && browser.table.visibleRect.intersects(frame(childIndex)), "Up from a new tab reveals its child even without a prior parent snapshot")
    browser.closeTab(); try await loaded(root)
    // Only temporary fixtures are changed; deleted children must not become phantom selections.
    let doomed = root.appendingPathComponent("Folder 300"); select(doomed.path); _ = position(300)
    browser.openSelected(); try await loaded(doomed); try fm.removeItem(at: doomed); browser.up(); try await loaded(root)
    try check(browser.selectedPaths.isEmpty && origin().y.isFinite && origin().y >= top().y, "A removed child is pruned from selection and the parent scroll remains valid")

    let media = root.appendingPathComponent("Media.localized"), inbox = media.appendingPathComponent("Automatically Add to Music.localized")
    try fm.createDirectory(at: inbox.appendingPathComponent(".localized"), withIntermediateDirectories: true)
    browser.navigate(to: media); try await loaded(media)
    browser.setView(.icons, size: 64); window.contentView?.layoutSubtreeIfNeeded()
    func expandedNames() -> [String] { browser.collection.subviews.compactMap { ($0 as? NativeExpandedNameView)?.text.stringValue } }
    browser.selectedPaths = [inbox.path]; browser.collection.layoutSubtreeIfNeeded()
    try check(expandedNames() == [inbox.lastPathComponent], "Selecting a long folder name in Icons expands its label")
    browser.selectedPaths = []
    try check(expandedNames().isEmpty, "Deselecting a long folder name removes its expanded label without another layout pass")
    browser.selectedPaths = [inbox.path]; browser.collection.layoutSubtreeIfNeeded()
    if showsWindows {
      if #available(macOS 14, *) { NSApp.activate() }
      else { NSApp.activate(ignoringOtherApps: true) }
      try await NativeSmoke.until { NSApp.isActive }
      window.makeKeyAndOrderFront(nil)
      try await NativeSmoke.until { window.isKeyWindow }
      let cell = frame(0)
      let point = browser.collection.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
      for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2,
                                       pressure: type == .leftMouseDown ? 1 : 0)!
        NSApp.sendEvent(event)
      }
    } else {
      browser.openSelected()
    }
    try check(browser.directory.path == inbox.path, "Double-click opens the selected folder before checking its expanded label")
    try check(expandedNames().isEmpty, "Opening a selected folder clears its expanded label before the destination loads")
    try check(browser.loading && browser.loadingView.isHidden && browser.emptyLabel.isHidden,
              "Opening a local folder does not immediately flash a loading placeholder or empty state")
    try await loaded(inbox)
    try check(browser.entries.isEmpty && browser.selectedPaths.isEmpty && expandedNames().isEmpty,
              "Entering a folder with only hidden contents removes its expanded label from the previous directory")
    try await Task.sleep(nanoseconds: 200_000_000)
    try check(browser.loadingView.isHidden && !browser.emptyLabel.isHidden,
              "A completed empty folder cannot show a stale loading placeholder")
    browser.back(); try await loaded(media)
    try check(browser.selectedPaths == [inbox.path] && expandedNames() == [inbox.lastPathComponent],
              "Back restores the folder selection and expands the current label once")

    try check(try Data(contentsOf: child.appendingPathComponent("Item 080.txt")) == Data("fixture".utf8), "Navigation checks preserve fixture contents")
    return checks
  }
}
