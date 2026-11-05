import AppKit
import ExplorerCore

@MainActor
private final class AddressTabDrag: NSObject, NSDraggingInfo {
  let draggingDestinationWindow: NSWindow?
  let draggingPasteboard: NSPasteboard
  let draggingLocation: NSPoint
  var draggingSequenceNumber: Int { draggingPasteboard.changeCount }
  var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
  var draggingSource: Any? { nil }
  var draggedImageLocation: NSPoint { draggingLocation }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(view: NSView, board: NSPasteboard) { draggingDestinationWindow = view.window; draggingPasteboard = board; draggingLocation = view.convert(NSPoint(x: 50, y: 15), to: nil) }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
  func resetSpringLoading() {}
}

@MainActor
enum NativeAddressTabChecks {
  static func run(source: BrowserController) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-address-tabs-" + UUID().uuidString)
    for path in ["Applications", "Desktop", "Downloads", "Documents/A", "Documents/alpha", "Documents/Beta", "Documents/.hidden", "Documents/Archive.app", "Documents/Applications", ".Trash"] { try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
    for index in 0..<7 { try fm.createDirectory(at: root.appendingPathComponent("Downloads/Item \(index)"), withIntermediateDirectories: false) }
    let docs = root.appendingPathComponent("Documents"), apps = root.appendingPathComponent("Applications"), downloads = root.appendingPathComponent("Downloads"), file = docs.appendingPathComponent("keep.txt"), bytes = Data("preserved fixture".utf8)
    try bytes.write(to: file)
    let domain = "local.macexplorer.address-tabs." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: domain) else { throw failure("Cannot create address fixture preferences") }
    let originalKey = NSApp.keyWindow
    let window = NSWindow(contentRect: NSRect(x: 220, y: 160, width: 1180, height: 780), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let browser = BrowserController(initial: docs, defaults: defaults); browser.home = root; browser.testTrashDirectory = root.appendingPathComponent(".Trash")
    browser.filePasteboard = NSPasteboard(name: .init(domain + ".clipboard")); window.contentViewController = browser; window.makeKeyAndOrderFront(nil)
    let host = NSWindow(contentRect: NSRect(x: 280, y: 220, width: 900, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false; let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: 900, height: 540)); host.contentView = surface
    let bar = ExplorerAddressBar(frame: NSRect(x: 24, y: 70, width: 850, height: 35)); surface.addSubview(bar); bar.homeDirectory = root; bar.setDirectory(docs)
    let board = NSPasteboard(name: .init(domain + ".drag")); board.writeObjects([file as NSURL])
    defer {
      ExplorerMenu.dismiss(); host.close(); browser.stopObserving(); window.close(); originalKey?.makeKeyAndOrderFront(nil)
      board.releaseGlobally(); browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: domain); try? fm.removeItem(at: root)
    }
    var checks: [String] = []
    func check(_ value: Bool, _ text: String) throws { guard value else { throw failure(text) }; checks.append(text); print("PASS address/tab: \(text)") }
    try check(try NativeAddressPath.resolve("~/Applications", current: docs, home: root).path == apps.path, "Tilde addresses use the configured home directory")
    try check(try NativeAddressPath.resolve("Applications", current: URL(string: "explorer://computer")!, home: root).path == apps.path, "Relative addresses on virtual pages use the home directory")
    try check(try NativeAddressPath.metadata(docs.appendingPathComponent("Archive.app")).isFolder == false && !NativeAddressPath.metadata(file).isFolder, "Address metadata treats application bundles and files as openable items")
    let entries = try EntryQuery.apply(DirectoryReader.read(docs).entries, showHidden: false, query: "", sort: .name, ascending: true)
    try check(NativeAddressPath.suggestions(entries, prefix: "~/Documents/", name: "a") == ["~/Documents/A", "~/Documents/alpha", "~/Documents/Applications"], "Folder suggestions preserve typed prefixes and exclude app bundles")
    try check(NativeAddressPath.prefix("file:///tmp/") == nil && NativeAddressPath.prefix("SMB://server/") == nil, "File and SMB URLs do not become folder-prefix suggestions")
    try await until { !browser.loading }
    browser.addressBar.onSubmit?("~/Applications")
    try await until { browser.directory.path == apps.path && !browser.loading }
    try check(defaults.stringArray(forKey: "typedPaths")?.first == apps.path, "Successful address navigation stores the resolved Applications path")
    let remembered = defaults.stringArray(forKey: "typedPaths")
    browser.addressBar.onSubmit?(root.appendingPathComponent("missing").path)
    try await until { browser.lastError != nil }
    try check(defaults.stringArray(forKey: "typedPaths") == remembered && browser.directory.path == apps.path, "Missing address metadata preserves location and successful history")

    host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await until { NSApp.isActive && host.isKeyWindow }; surface.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded()
    bar.recentPaths = (0..<12).map { root.appendingPathComponent("history-\($0)").path }; bar.beginEditing()
    try await until { bar.field.currentEditor() is NSTextView }
    guard let editor = bar.field.currentEditor() as? NSTextView else { throw failure("No address field editor") }
    func suggestionRows() -> [ExplorerButton] { host.childWindows?.flatMap { descendants($0.contentView).compactMap { $0 as? ExplorerButton } } ?? [] }
    try check(suggestionRows().count == 12, "Address history retains more than eight entries in a scrollable list")
    _ = bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
    try check(bar.field.stringValue == bar.recentPaths.first && suggestionRows().count == 12, "Down arrow changes the address without narrowing history")
    _ = bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
    try check(bar.field.stringValue == bar.recentPaths.last && suggestionRows().last?.visibleRect.height ?? 0 > 0, "Up arrow wraps to the last history row and scrolls it into view")
    bar.field.stringValue = "~/ap"; editor.string = "~/ap"; bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
    try await until { suggestionRows().map(\.title) == ["~/Applications"] }
    try check(true, "Applications is suggested with the original tilde prefix")
    bar.field.stringValue = "~/Downloads/it"; editor.string = bar.field.stringValue; bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
    try await until { suggestionRows().count == 5 && suggestionRows().allSatisfy { $0.title.hasPrefix("~/Downloads/Item ") } }
    try check(true, "Case-insensitive folder suggestions stop at five")
    _ = bar.control(bar.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    bar.setDirectory(docs.appendingPathComponent("Applications")); bar.layoutSubtreeIfNeeded()
    try check(descendants(bar).compactMap { $0 as? ExplorerButton }.contains { $0.title == "Applications" }, "Nested Applications folders retain their real path label")
    bar.setDirectory(apps); bar.layoutSubtreeIfNeeded()
    try check(descendants(bar).compactMap { $0 as? ExplorerButton }.contains { $0.title == NL("应用程序") }, "Home Applications has the standard localized label")

    var selected = 0, dropped = 0
    let tab = ExplorerTabView(title: "fixture", active: false, onSelect: { selected += 1 }, onClose: {})
    tab.frame = NSRect(x: 24, y: 12, width: 214, height: 36); surface.addSubview(tab)
    tab.onDragValidate = { info in info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .move : [] }
    tab.onDrop = { _ in dropped += 1; return true }
    let drag = AddressTabDrag(view: tab, board: board)
    try check(tab.draggingEntered(drag) == .move, "File drags are accepted by folder tabs")
    try await Task.sleep(nanoseconds: 100_000_000); tab.draggingExited(drag); try await Task.sleep(nanoseconds: 550_000_000)
    try check(selected == 0, "Leaving a tab cancels its pending hover switch")
    _ = tab.draggingEntered(drag); try await until { selected == 1 }; tab.selected = true
    try check(true, "Holding a file drag over an inactive tab selects it after 600ms")
    try check(tab.performDragOperation(drag) && dropped == 1, "Tab drops use the configured file-drop callback")
    board.clearContents(); board.setString("text only", forType: .string)
    try check(tab.draggingEntered(AddressTabDrag(view: tab, board: board)).isEmpty, "Plain text cannot trigger a file tab drop")

    window.makeKeyAndOrderFront(nil); browser.navigate(to: docs); try await until { !browser.loading && browser.directory == docs }
    let breadcrumbSource = downloads.appendingPathComponent("breadcrumb-source.txt")
    try Data("breadcrumb transfer".utf8).write(to: breadcrumbSource)
    guard let breadcrumb = descendants(browser.addressBar).compactMap({ $0 as? ExplorerButton }).first(where: { $0.title == NL("文档") }) else { throw failure("No Documents breadcrumb") }
    board.clearContents(); board.writeObjects([breadcrumbSource as NSURL])
    let breadcrumbDrag = AddressTabDrag(view: breadcrumb, board: board)
    try check(!breadcrumb.draggingEntered(breadcrumbDrag).isEmpty, "Address breadcrumbs validate file drops using the real Browser transfer rules")
    try check(breadcrumb.performDragOperation(breadcrumbDrag), "Address breadcrumbs accept file drops")
    try await until { fm.fileExists(atPath: docs.appendingPathComponent("breadcrumb-source.txt").path) && !fm.fileExists(atPath: breadcrumbSource.path) }
    try check(try String(contentsOf: docs.appendingPathComponent("breadcrumb-source.txt"), encoding: .utf8) == "breadcrumb transfer", "Address breadcrumb drops move files into their target folder")
    browser.openTab(at: downloads); try await until { !browser.loading && browser.directory == downloads }
    guard let first = browser.tabsDocument.subviews.compactMap({ $0 as? ExplorerTabView }).first else { throw failure("No Browser folder tab") }
    board.clearContents(); board.writeObjects([file as NSURL])
    try check(!first.draggingEntered(AddressTabDrag(view: first, board: board)).isEmpty, "Browser folder tabs expose the existing file-drop validation")
    try await until { browser.activeTab == 0 && !browser.loading }
    try check(browser.directory == docs && Data(contentsOf: file) == bytes, "Real Browser tab hover switches folders without changing dragged files")
    return checks
  }
  private static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
  private static func failure(_ text: String) -> NativeSmoke.Failure { NativeSmoke.Failure(description: text) }
  private static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() { guard Date() < deadline else { throw failure("Address/tab fixture timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
  }
}
