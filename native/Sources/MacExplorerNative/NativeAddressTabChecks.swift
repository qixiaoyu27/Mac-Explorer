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
    let host = NSWindow(contentRect: NSRect(x: 280, y: 220, width: 1100, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false; let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: 1100, height: 540)); host.contentView = surface
    let bar = AddressBand(frame: NSRect(x: 24, y: 70, width: 850, height: 35))
    surface.addSubview(bar)
    bar.homeDirectory = root
    bar.labelForPath = { [weak browser] in browser?.locationLabel($0) ?? $0.lastPathComponent }
    bar.SetNavigationState(AddressNavigationState(location: docs))
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
    browser.addressBar.editBox._HandleUserAction("\"~/Applications\"")
    try await until { browser.directory.path == apps.path && !browser.loading }
    try check(defaults.stringArray(forKey: "typedPaths")?.first == apps.path, "Successful address navigation stores the resolved Applications path")
    let remembered = defaults.stringArray(forKey: "typedPaths")
    browser.addressBar.editBox._HandleUserAction(root.appendingPathComponent("missing").path)
    try await until { browser.lastError != nil }
    try check(defaults.stringArray(forKey: "typedPaths") == remembered && browser.directory.path == apps.path, "Missing address metadata preserves location and successful history")

    host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); try await until { NSApp.isActive && host.isKeyWindow }; surface.layoutSubtreeIfNeeded(); bar.layoutSubtreeIfNeeded()
    let box = bar.editBox, field = box.field
    bar.recentPaths = (0..<12).map { root.appendingPathComponent("history-\($0)").path }
    func visibleButtons(_ view: NSView) -> [ExplorerButton] {
      descendants(view).compactMap { $0 as? ExplorerButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }
    func trailingGap() -> CGFloat {
      let rightEdge = visibleButtons(bar.breadcrumbBar).map { $0.convert($0.bounds, to: bar).maxX }.max() ?? 0
      return bar.bounds.maxX - rightEdge
    }
    let longPath = docs.appendingPathComponent(String(repeating: "long-folder-", count: 18), isDirectory: true)
    bar.SetNavigationState(AddressNavigationState(location: longPath))
    for width in [CGFloat(850), 225] {
      bar.frame.size.width = width
      bar.layoutSubtreeIfNeeded()
      try check(visibleButtons(bar.breadcrumbBar).contains { $0.title == longPath.lastPathComponent } &&
                trailingGap() >= 28, "A long path keeps the trailing edit column at address width \(Int(width))")
    }
    let blank = bar.convert(NSPoint(x: bar.bounds.maxX - trailingGap() / 2, y: bar.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = NSEvent.mouseEvent(with: type, location: blank, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                     context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
      NSApp.sendEvent(event)
    }
    try check(bar.editing && field.currentEditor() != nil && box.GetText().text == longPath.path, "Clicking the trailing address background opens the full path for editing")
    bar.RevertEditChanges()
    bar.SetNavigationState(AddressNavigationState(location: docs))
    bar.frame.size.width = 225
    bar.layoutSubtreeIfNeeded()
    let narrow = visibleButtons(bar.breadcrumbBar)
    try check(narrow.contains { $0.title == NL("文档") && $0.convert($0.bounds, to: bar.breadcrumbBar).maxX <= bar.breadcrumbBar.bounds.maxX }, "Breadcrumb overflow keeps the current directory inside the address band")
    guard let overflow = narrow.first(where: { $0.iconName == "more" }) else { throw failure("No breadcrumb overflow button") }
    var navigated: URL?
    bar.onAddressDestination = { if case .location(let url) = $0 { navigated = url } }
    overflow.performClick(nil)
    try await until { host.childWindows?.contains { child in descendants(child.contentView).contains { $0.accessibilityLabel() == "Macintosh HD" } } == true }
    try check(true, "The overflow button opens a dropdown containing hidden ancestors")
    ExplorerMenu.dismiss()
    host.makeKeyAndOrderFront(nil)
    bar.frame.size.width = 1040
    bar.layoutSubtreeIfNeeded()
    try check(!visibleButtons(bar.breadcrumbBar).contains { $0.iconName == "more" }, "Widening the band restores the hidden breadcrumb buttons")
    try check(trailingGap() > 28, "Unused breadcrumb space extends the clickable trailing column")
    guard let drive = visibleButtons(bar.breadcrumbBar).first(where: { $0.title == "Macintosh HD" }),
          let current = visibleButtons(bar.breadcrumbBar).first(where: { $0.title == NL("文档") }) else { throw failure("No visible ancestor and current breadcrumb") }
    drive.performClick(nil)
    try check(navigated?.path == "/" && !bar.editing, "An ancestor breadcrumb navigates through AddressBand")
    current.performClick(nil)
    try await until { field.currentEditor() is NSTextView }
    guard let editor = field.currentEditor() as? NSTextView else { throw failure("No address field editor") }
    func suggestionRows() -> [ExplorerButton] { host.childWindows?.flatMap { descendants($0.contentView).compactMap { $0 as? ExplorerButton } } ?? [] }
    try check(bar.editing && editor.string == docs.path && editor.selectedRange().length == (docs.path as NSString).length && suggestionRows().isEmpty, "The current breadcrumb selects the full editable path without opening history")
    bar.ShowAddressHistory()
    try check(suggestionRows().count == 12, "Address history retains more than eight entries in a scrollable list")
    _ = box.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
    try check(box.GetText().text == bar.recentPaths.first && suggestionRows().count == 12, "Down arrow changes the address without narrowing history")
    _ = box.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
    try check(box.GetText().text == bar.recentPaths.last && suggestionRows().last?.visibleRect.height ?? 0 > 0, "Up arrow wraps to the last history row and scrolls it into view")
    _ = box.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    try check(bar.editing && suggestionRows().isEmpty && box.GetText().text == docs.path, "Escape closes the open dropdown and restores its draft")
    editor.string = "~/ap"; box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await until { suggestionRows().map(\.title) == ["~/Applications"] }
    try check(true, "Applications is suggested with the original tilde prefix")
    editor.string = "~/Downloads/it"; box.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    try await until { suggestionRows().count == 5 && suggestionRows().allSatisfy { $0.title.hasPrefix("~/Downloads/Item ") } }
    try check(true, "Case-insensitive folder suggestions stop at five")
    _ = box.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    bar._SetFocusAndEditMode()
    try check(bar.GetText().text == "~/Downloads/it" && bar.GetText().dirty, "Focusing an active address editor retains its draft")
    _ = box.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    try check(!bar.editing && box.GetText().text == docs.path && (host.firstResponder as? ExplorerButton)?.iconName == "computer", "Escape restores breadcrumbs and returns focus to the first crumb")
    bar.SetNavigationState(AddressNavigationState(location: docs.appendingPathComponent("Applications"))); bar.layoutSubtreeIfNeeded()
    try check(descendants(bar).compactMap { $0 as? ExplorerButton }.contains { $0.title == "Applications" }, "Nested Applications folders retain their real path label")
    bar.SetNavigationState(AddressNavigationState(location: apps)); bar.layoutSubtreeIfNeeded()
    try check(descendants(bar).compactMap { $0 as? ExplorerButton }.contains { $0.title == NL("应用程序") }, "Home Applications has the standard localized label")
    bar.breadcrumbBar.SetCurrentFolderContainsSubFolders(false)
    bar.layoutSubtreeIfNeeded()
    let appCrumb = descendants(bar).compactMap { $0 as? BreadcrumbBarItemControl }.first { $0.name.title == NL("应用程序") }
    try check(appCrumb?.arrow.isHidden == true, "A leaf folder has no subfolder chevron")
    bar._SetFocusAndEditMode()
    guard let input = field.currentEditor() as? NSTextView else { throw failure("No active address field editor") }
    try check(visibleButtons(bar).isEmpty, "The modern address editor has no separate Go or history button")
    input.string = "~/Downloads"
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber,
                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    NSApp.sendEvent(enter)
    try await until { navigated?.path == downloads.path && !bar.editing }
    try check(bar.recentPaths.first == downloads.path, "Enter uses the edit box parser and records a successful address")
    navigated = nil
    box._HandleUserAction("~/Downloads")
    bar.SetNavigationState(AddressNavigationState(location: apps, tab: UUID()))
    try await Task.sleep(nanoseconds: 100_000_000)
    try check(navigated == nil, "Switching tabs cancels pending address navigation even at the same folder")

    var selected = 0, dropped = 0
    let tab = ExplorerTabView()
    tab.header = "fixture"
    tab.onSelect = { selected += 1 }
    tab.setFrameOrigin(NSPoint(x: 24, y: 12))
    surface.addSubview(tab)
    surface.layoutSubtreeIfNeeded()
    let leftFoot = NSPoint(x: 2.5, y: tab.bounds.maxY - 0.5)
    let rightFoot = NSPoint(x: tab.bounds.maxX - leftFoot.x, y: leftFoot.y)
    let shape = tab.tabViewTemplateSettings.tabGeometry
    try check(shape.contains(leftFoot) && shape.contains(rightFoot) && !shape.contains(NSPoint(x: leftFoot.x, y: 20)),
              "The selected tab geometry flares only at the two bottom corners")
    try check(tab.hitTest(tab.convert(leftFoot, to: surface)) == nil && tab.hitTest(tab.convert(rightFoot, to: surface)) == nil,
              "The flared corners do not extend the tab hit target")
    guard let closeButton = tab.subviews.compactMap({ $0 as? ExplorerButton }).first else { throw failure("Missing tab close button") }
    var closeRequests = 0
    tab.onClose = { closeRequests += 1 }
    tab.isClosable = false
    closeButton.performClick(nil)
    try check(closeButton.isHidden && closeRequests == 0, "A nonclosable tab hides its close button and rejects its action")
    tab.isClosable = true
    closeButton.performClick(nil)
    try check(!closeButton.isHidden && closeRequests == 1, "The close button sends one request to the tab controller")
    tab.onDragValidate = { info in info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .move : [] }
    tab.onDrop = { _ in dropped += 1; return true }
    let drag = AddressTabDrag(view: tab, board: board)
    try check(tab.draggingEntered(drag) == .move, "File drags are accepted by folder tabs")
    try await Task.sleep(nanoseconds: 100_000_000); tab.draggingExited(drag); try await Task.sleep(nanoseconds: 550_000_000)
    try check(selected == 0, "Leaving a tab cancels its pending hover switch")
    _ = tab.draggingEntered(drag); try await until { selected == 1 }; tab.isSelected = true
    try check(true, "Holding a file drag over an inactive tab selects it after 600ms")
    try check(tab.performDragOperation(drag) && dropped == 1, "Tab drops use the configured file-drop callback")
    board.clearContents(); board.setString("text only", forType: .string)
    try check(tab.draggingEntered(AddressTabDrag(view: tab, board: board)).isEmpty, "Plain text cannot trigger a file tab drop")

    window.makeKeyAndOrderFront(nil); browser.navigate(to: docs); try await until { !browser.loading && browser.directory == docs }
    let f4 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                              context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 118)!
    NSApp.sendEvent(f4)
    try check(browser.addressBar.editing && window.childWindows?.isEmpty == false, "F4 opens typed-address history through the browser window")
    browser.addressBar.RevertEditChanges()
    let breadcrumbSource = downloads.appendingPathComponent("breadcrumb-source.txt")
    try Data("breadcrumb transfer".utf8).write(to: breadcrumbSource)
    guard let breadcrumb = descendants(browser.addressBar).compactMap({ $0 as? ExplorerButton }).first(where: { $0.title == NL("文档") }) else { throw failure("No Documents breadcrumb") }
    let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: breadcrumb.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    func chooseAddressMenuItem(_ title: String) throws {
      breadcrumb.rightMouseDown(with: rightClick)
      guard let row = window.childWindows?.flatMap({ descendants($0.contentView) }).first(where: { $0.accessibilityLabel() == title }) else {
        throw failure("Missing address menu item " + title)
      }
      let release = NSEvent.mouseEvent(with: .leftMouseUp,
        location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: row.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
      row.mouseUp(with: release)
    }
    try chooseAddressMenuItem(NL("复制地址"))
    try check(browser.filePasteboard.string(forType: .string) == docs.path && browser.filePasteboard.string(forType: .fileURL) != nil, "Copy address writes both the path and its file reference")
    try chooseAddressMenuItem(NL("将地址复制为文本"))
    try check(browser.filePasteboard.string(forType: .string) == docs.path && browser.filePasteboard.string(forType: .fileURL) == nil, "Copy address as text writes only the path")
    try chooseAddressMenuItem(NL("删除历史记录"))
    try check(defaults.stringArray(forKey: "typedPaths") == [] && browser.addressBar.recentPaths.isEmpty, "Delete history clears the address dropdown and persisted history")
    board.clearContents(); board.writeObjects([breadcrumbSource as NSURL])
    let breadcrumbDrag = AddressTabDrag(view: breadcrumb, board: board)
    try check(!breadcrumb.draggingEntered(breadcrumbDrag).isEmpty, "Address breadcrumbs validate file drops using the real Browser transfer rules")
    try check(breadcrumb.performDragOperation(breadcrumbDrag), "Address breadcrumbs accept file drops")
    try await until { fm.fileExists(atPath: docs.appendingPathComponent("breadcrumb-source.txt").path) && !fm.fileExists(atPath: breadcrumbSource.path) }
    try check(try String(contentsOf: docs.appendingPathComponent("breadcrumb-source.txt"), encoding: .utf8) == "breadcrumb transfer", "Address breadcrumb drops move files into their target folder")
    browser.openTab(at: downloads); try await until { !browser.loading && browser.directory == downloads }
    browser.openTab(at: apps); try await until { !browser.loading && browser.directory == apps }
    let tabs = browser.tabsDocument.subviews.compactMap { $0 as? ExplorerTabView }
    guard tabs.count == 3 else { throw failure("Expected three browser folder tabs") }
    let first = tabs[0], second = tabs[1], third = tabs[2]
    let document = browser.tabsDocument
    let seam = second.frame.midX - ExplorerTabView.bodyWidth / 2
    let beforeSeam = document.convert(NSPoint(x: seam - 0.5, y: 18), to: document.superview)
    let afterSeam = document.convert(NSPoint(x: seam + 0.5, y: 18), to: document.superview)
    try check(document.hitTest(beforeSeam) === first && document.hitTest(afterSeam) === second,
              "Adjacent tabs meet without a gap or an overlapping hit target")
    try check(!second.showsTrailingSeparator && third.layer?.zPosition == 1,
              "The active tab paints above its neighbors and hides the separator at its leading edge")
    let hover = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    try check(first.showsTrailingSeparator, "Idle inactive tabs show their shared separator")
    first.mouseEntered(with: hover)
    try check(!first.showsTrailingSeparator, "Hovering the left tab hides the shared separator")
    first.mouseExited(with: hover)
    second.mouseEntered(with: hover)
    try check(!first.showsTrailingSeparator, "Hovering the right tab hides the same shared separator")
    second.mouseExited(with: hover)
    try check(first.showsTrailingSeparator && !second.showsTrailingSeparator,
              "Leaving either tab restores the shared separator and respects the active tab")
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
