import AppKit
import ExplorerCore

@MainActor
enum NativeNavigationStateChecks {
  static func run() async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-navigation-state-" + UUID().uuidString)
    for i in 0..<320 { try fm.createDirectory(at: root.appendingPathComponent(String(format: "Folder %03d", i)), withIntermediateDirectories: true) }
    let child = root.appendingPathComponent("Folder 220")
    for i in 0..<120 { try Data("fixture".utf8).write(to: child.appendingPathComponent(String(format: "Item %03d.txt", i))) }
    let suite = "local.macexplorer.navigation-state." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    defaults.set(false, forKey: "versionControl")
    let key = NSApp.keyWindow
    let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 1100, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite)); window.contentViewController = browser; window.makeKeyAndOrderFront(nil)
    defer { browser.stopObserving(); window.close(); key?.makeKeyAndOrderFront(nil); browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
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
    func scroll() -> NSScrollView { browser.mode == .details ? browser.tableScroll : browser.collectionScroll }
    func frame(_ index: Int) -> NSRect { browser.mode == .details ? browser.table.rect(ofRow: index) : browser.collectionLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame }
    func origin() -> NSPoint { scroll().contentView.bounds.origin }
    func close(_ a: NSPoint, _ b: NSPoint) -> Bool { abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2 }
    func position(_ index: Int) -> NSPoint {
      let rect = frame(index), view = scroll(), document = view.documentView!
      let point = NSPoint(x: min(max(0, rect.minX - 50), max(0, document.bounds.width - view.contentSize.width)), y: min(max(0, rect.minY - 70), max(0, document.bounds.height - view.contentSize.height)))
      view.contentView.scroll(to: point); view.reflectScrolledClipView(view.contentView)
      return origin()
    }
    func select(_ path: String) { browser.selectedPaths = [path]; browser.updateMode(persist: false); window.contentView?.layoutSubtreeIfNeeded() }
    let layouts: [(ExplorerLayoutMode, CGFloat, String)] = [(.details,64,"details"),(.icons,128,"extra-large icons"),(.icons,96,"large icons"),(.icons,64,"medium icons"),(.icons,32,"small icons"),(.list,32,"list"),(.tiles,64,"tiles"),(.content,64,"content")]
    for (layout, size, title) in layouts {
      browser.navigate(to: root); try await loaded(root); browser.setView(layout, size: size); window.contentView?.layoutSubtreeIfNeeded()
      select(child.path); let parentPoint = position(220)
      try check(parentPoint.x > 100 || parentPoint.y > 100, title + ": fixture genuinely scrolls away from the first page; origin=\(parentPoint), document=\(scroll().documentView!.bounds.size), frame=\(scroll().documentView!.frame.size), layout=\(browser.collectionLayout.collectionViewContentSize), target=\(frame(220)), mode=\(browser.mode.rawValue), mask=\(browser.collection.autoresizingMask.rawValue), owner=\(browser.collection.collectionViewLayout === browser.collectionLayout)")
      browser.openSelected(); try await loaded(child)
      try check(close(origin(), .zero), title + ": entering a folder starts at the top instead of inheriting its parent scroll")
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
    try check(close(origin(), .zero) && browser.selectedPaths.isEmpty, "A new tab starts independently even at the same directory")
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
    try check(browser.selectedPaths.isEmpty && close(origin(), .zero), "Branching history clears discarded forward-location state")
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
    try check(browser.selectedPaths.isEmpty && origin().y.isFinite && origin().y >= 0, "A removed child is pruned from selection and the parent scroll remains valid")
    try check(try Data(contentsOf: child.appendingPathComponent("Item 080.txt")) == Data("fixture".utf8), "Navigation checks preserve fixture contents")
    return checks
  }
}
