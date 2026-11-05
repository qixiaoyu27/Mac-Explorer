import AppKit
import ExplorerCore
import ObjectiveC

@MainActor
enum NativeSearchTagChecks {
  static func run() async throws -> [String] {
    // Exercise real dialogs while suppressing window ordering in this test process.
    let suppress: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
    let replacement = imp_implementationWithBlock(suppress)
    let methods = [#selector(NSWindow.orderFront(_:)), #selector(NSWindow.makeKeyAndOrderFront(_:))].map { class_getInstanceMethod(NSWindow.self, $0)! }
    let originals = methods.map { method_setImplementation($0, replacement) }
    defer { for (method, original) in zip(methods, originals) { method_setImplementation(method, original) }; imp_removeBlock(replacement) }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("explorer-search-tags-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["a.txt", "b.txt"] { try Data("preserved".utf8).write(to: root.appendingPathComponent(name)) }
    let suite = "local.macexplorer.search-tags." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl")
    defaults.set(FileSearchFilters(tag: "Missing fixture tag").propertyList, forKey: "searchFilters")
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; browser.reload()
    defer {
      ExplorerMenu.dismiss(); ExplorerDialogs.close(in: window); browser.stopObserving(); window.close()
      defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root)
    }
    var checks: [String] = []
    func check(_ value: Bool, _ title: String) throws { guard value else { throw NativeSmoke.Failure(description: title) }; checks.append(title); print("PASS search tags: " + title) }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func children(_ owner: NSWindow) -> [NSWindow] { (owner.childWindows ?? []).flatMap { [$0] + children($0) } }
    func controls() -> [NSView] { children(window).compactMap(\.contentView).flatMap(descendants) }
    func field() throws -> ExplorerTextField {
      guard let field = controls().compactMap({ $0 as? ExplorerTextField }).first(where: { ($0.accessibilityLabel() ?? "").hasPrefix(NL("标签名称")) }) else { throw NativeSmoke.Failure(description: "Missing tag input") }
      field.window?.contentView?.layoutSubtreeIfNeeded(); return field
    }
    func apply() throws {
      guard let button = controls().compactMap({ $0 as? EDButton }).first(where: { $0.title == NL("应用") }) else { throw NativeSmoke.Failure(description: "Missing Apply button") }
      try check(button.isEnabled, "Empty tag input remains actionable for removing tags")
      button.onPress?()
    }
    func until(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while !condition() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Search tag check timed out: loading=\(browser.loading), entries=\(browser.entries.count), error=\(browser.lastError ?? "none")") }; try await Task.sleep(nanoseconds: 20_000_000) }
    }
    try await until { !browser.loading && browser.entries.count == 2 }
    var submittedTag: String?
    ExplorerDialogs.searchTag(in: window, initial: "") { submittedTag = $0 }
    let searchField = try field()
    try check(searchField.frame.width >= 300 && searchField.isEditable, "Empty search-tag input has a usable width")
    try apply()
    try check(submittedTag == "", "The tag-filter dialog submits an empty value to clear filtering")
    var submittedNames: [String]?
    ExplorerDialogs.finderTags(in: window, initial: [], count: 2) { submittedNames = $0 }
    let editField = try field()
    try check(editField.frame.width >= 300 && editField.isEditable, "Empty batch-tag input has a usable width")
    editField.stringValue = "  工作, 待办, 工作  "; try apply()
    try check(submittedNames == ["工作", "待办"], "Batch-tag dialog submits normalized comma-separated names")
    ExplorerDialogs.finderTags(in: window, initial: ["工作"], count: 2) { submittedNames = $0 }
    try field().stringValue = ""; try apply()
    try check(submittedNames == [], "Removing every shared tag submits an explicit empty edit")
    browser.searchBox.onSearch?()
    try await until { !browser.loading }
    try check(browser.entries.isEmpty && browser.lastError == nil && browser.searchBox.filtersActive, "A tag-only search applies the active filter")
    browser.searchBox.onFilters?()
    guard let row = NSApp.windows.compactMap(\.contentView).flatMap(descendants).first(where: { $0.accessibilityRole() == .menuItem && $0.accessibilityLabel() == NL("Finder 标签：{0}", "Missing fixture tag") }),
          let event = NSEvent.mouseEvent(with: .leftMouseUp, location: row.convert(NSPoint(x: 20, y: 16), to: nil), modifierFlags: [], timestamp: 0, windowNumber: row.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { throw NativeSmoke.Failure(description: "Missing Finder tag filter menu item") }
    row.mouseUp(with: event)
    try field().stringValue = ""; try apply()
    try await until { !browser.loading && browser.entries.count == 2 }
    try check(!browser.searchBox.filtersActive && browser.lastError == nil && FileSearchFilters(propertyList: defaults.dictionary(forKey: "searchFilters")).isDefault, "Clearing the last tag filter reloads the unfiltered directory and resets its indicator")
    try check(!NSApp.windows.contains { $0.isVisible }, "Tag UI checks display no windows")
    return checks
  }
}
