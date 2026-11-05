import AppKit
import ExplorerCore
import ObjectiveC

@MainActor private final class TransferUIDrag: NSObject, NSDraggingInfo {
  let draggingDestinationWindow: NSWindow?
  let draggingPasteboard: NSPasteboard
  let draggingLocation: NSPoint
  var draggingSequenceNumber: Int { draggingPasteboard.changeCount }
  var draggingSourceOperationMask: NSDragOperation = .copy
  var draggingSource: Any? { nil }
  var draggedImageLocation: NSPoint { draggingLocation }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingFormation: NSDraggingFormation = .none
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(view: NSView, board: NSPasteboard, point: NSPoint) { draggingDestinationWindow = view.window; draggingPasteboard = board; draggingLocation = view.convert(point, to: nil) }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
  func resetSpringLoading() {}
}

@main enum TransferUIChecks {
  @MainActor static func main() async {
    do { try await run() }
    catch { fputs("TransferUIChecks FAILED: \(error)\n", stderr); exit(1) }
  }
  @MainActor static func run() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let suppress: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
    let replacement = imp_implementationWithBlock(suppress)
    let methods = [#selector(NSWindow.orderFront(_:)), #selector(NSWindow.makeKeyAndOrderFront(_:))].map { class_getInstanceMethod(NSWindow.self, $0)! }
    let originals = methods.map { method_setImplementation($0, replacement) }
    defer { for (method, original) in zip(methods, originals) { method_setImplementation(method, original) }; imp_removeBlock(replacement) }
    NativeLanguage.load(from: URL(fileURLWithPath: CommandLine.arguments[1])); NativeLanguage.mode = "zh-CN"
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-transfer-ui-" + UUID().uuidString)
    let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), empty = root.appendingPathComponent("empty")
    for directory in [source, target, empty, target.appendingPathComponent("folder")] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
    let file = source.appendingPathComponent("item.txt"), existing = target.appendingPathComponent("item.txt")
    try Data("source".utf8).write(to: file); try Data("existing".utf8).write(to: existing)
    let suite = "native-transfer-ui." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl"); defaults.set(false, forKey: "serverSideTransfer")
    let browser = BrowserController(initial: target, defaults: defaults); browser.home = root
    let board = NSPasteboard(name: .init(suite)); board.writeObjects([file as NSURL]); browser.filePasteboard = board
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1050, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser
    defer { browser.stopObserving(); window.close(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ value: @autoclosure () throws -> Bool, _ text: String) throws { guard try value() else { throw NativeSmoke.Failure(description: text) }; checks.append(text) }
    func until(line: Int = #line, _ predicate: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(8)
      while !predicate() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Transfer UI timed out at line \(line), after \(checks.count) checks") }; try await Task.sleep(nanoseconds: 20_000_000) }
    }
    browser.reload()
    try await until { !browser.loading && browser.entries.count == 2 }
    for directory in [target, empty] {
      browser.navigate(to: directory); try await until { !browser.loading && browser.directory.path == directory.path }
      for mode: ExplorerLayoutMode in [.icons, .list, .tiles, .content] {
        browser.mode = mode; browser.updateMode(persist: false); browser.view.layoutSubtreeIfNeeded()
        let collection = browser.collection, layout = collection.collectionViewLayout!
        layout.prepare()
        try check(!collection.isHiddenOrHasHiddenAncestor, "\(mode): loaded folders keep their drop receiver visible, including empty folders")
        if browser.entries.isEmpty {
          let center = NSPoint(x: browser.emptyIcon.frame.midX, y: browser.emptyIcon.frame.midY)
          let hit = browser.content.hitTest(browser.content.convert(center, to: browser.content.superview))
          try check(hit === collection || hit?.isDescendant(of: collection) == true, "\(mode): the empty-folder message passes hits through to the file view")
        }
        for point in [NSPoint(x: 5, y: 5), NSPoint(x: collection.visibleRect.maxX - 5, y: collection.visibleRect.maxY - 5)] {
          let attributes = layout.layoutAttributesForDropTarget(at: point)
          try check(attributes?.representedElementCategory == .interItemGap && attributes?.indexPath?.item == browser.entries.count, "\(mode): empty canvas and margins propose a background drop")
          let drag = TransferUIDrag(view: collection, board: board, point: point)
          try check(collection.draggingEntered(drag) == .copy, "\(mode): AppKit accepts an external file over the background")
          collection.draggingExited(drag)
        }
        for (row, entry) in browser.entries.enumerated() {
          let index = IndexPath(item: row, section: 0), frame = layout.layoutAttributesForItem(at: index)!.frame
          let point = NSPoint(x: frame.midX, y: frame.midY)
          try check(layout.layoutAttributesForDropTarget(at: point)?.indexPath == index, "\(mode): item centers retain their actual drop target")
          var proposed: NSIndexPath = index as NSIndexPath, operation: NSCollectionView.DropOperation = .on
          let drag = TransferUIDrag(view: collection, board: board, point: point)
          let accepted = browser.collectionView(collection, validateDrop: drag, proposedIndexPath: &proposed, dropOperation: &operation)
          try check(accepted == .copy && operation == (entry.isDirectory ? .on : .before), "\(mode): folders receive files and regular items target the current folder")
          if operation == .before { try check(layout.layoutAttributesForInterItemGap(before: proposed as IndexPath) != nil, "\(mode): proposed insertion targets have valid layout attributes") }
        }
      }
    }
    browser.navigate(to: target); try await until { !browser.loading && browser.entries.count == 2 }
    let folder = target.appendingPathComponent("folder"), payload = folder.appendingPathComponent("keep.txt")
    try Data("preserved".utf8).write(to: payload)
    for mode: ExplorerLayoutMode in [.details, .icons, .list, .tiles, .content] {
      browser.setView(mode, size: 64); browser.view.layoutSubtreeIfNeeded()
      let row = browser.entries.firstIndex { $0.url.path == folder.path }!
      let host: NSView = mode == .details ? browser.table : browser.collection
      let drag = TransferUIDrag(view: host, board: board, point: .zero)
      for mask: NSDragOperation in [.move, .copy] {
        drag.draggingSourceOperationMask = mask
        board.clearContents(); board.writeObjects([folder as NSURL, existing as NSURL])
        let offered: NSDragOperation, accepted: Bool
        if mode == .details {
          offered = browser.tableView(browser.table, validateDrop: drag, proposedRow: row, proposedDropOperation: .on)
          accepted = browser.tableView(browser.table, acceptDrop: drag, row: row, dropOperation: .on)
        } else {
          var proposed = IndexPath(item: row, section: 0) as NSIndexPath, operation = NSCollectionView.DropOperation.on
          offered = browser.collectionView(browser.collection, validateDrop: drag, proposedIndexPath: &proposed, dropOperation: &operation)
          accepted = browser.collectionView(browser.collection, acceptDrop: drag, indexPath: proposed as IndexPath, dropOperation: operation)
        }
        try check(offered.isEmpty && !accepted && !browser.busy && browser.lastError == nil, "\(mode): releasing a selection onto its own folder silently rejects \(mask == .move ? "move" : "copy")")
      }
      board.clearContents(); board.writeObjects([folder as NSURL, existing as NSURL]); drag.draggingSourceOperationMask = .move
      let backgroundAccepted = mode == .details
        ? browser.tableView(browser.table, acceptDrop: drag, row: -1, dropOperation: .on)
        : browser.collectionView(browser.collection, acceptDrop: drag, indexPath: IndexPath(item: browser.entries.count, section: 0), dropOperation: .before)
      try check(backgroundAccepted, "\(mode): background release still accepts a same-directory move")
      try await until { !browser.busy && !browser.loading }
      try check(browser.lastError == nil && (try Data(contentsOf: payload)) == Data("preserved".utf8) && (try Data(contentsOf: existing)) == Data("existing".utf8), "\(mode): same-directory release leaves files intact without a warning")
      let incoming = source.appendingPathComponent("incoming.txt"), moved = folder.appendingPathComponent("incoming.txt")
      try Data("incoming".utf8).write(to: incoming)
      board.clearContents(); board.writeObjects([incoming as NSURL])
      let movedIntoFolder = mode == .details
        ? browser.tableView(browser.table, acceptDrop: drag, row: row, dropOperation: .on)
        : browser.collectionView(browser.collection, acceptDrop: drag, indexPath: IndexPath(item: row, section: 0), dropOperation: .on)
      try check(movedIntoFolder, "\(mode): dropping into a different folder still accepts a move")
      try await until { !browser.busy && !browser.loading }
      try check(browser.lastError == nil && !fm.fileExists(atPath: incoming.path) && (try Data(contentsOf: moved)) == Data("incoming".utf8), "\(mode): a valid folder drop moves the file intact")
      try fm.removeItem(at: moved)
    }
    board.clearContents(); board.writeObjects([target as NSURL])
    let tab = browser.tabsDocument.subviews.compactMap { $0 as? ExplorerTabView }.first!
    let tabDrag = TransferUIDrag(view: tab, board: board, point: .zero)
    try check(tab.draggingEntered(tabDrag).isEmpty && !tab.performDragOperation(tabDrag), "Folder tabs reject their own folder without starting a transfer")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let breadcrumb = descendants(browser.addressBar).compactMap { $0 as? ExplorerButton }.first { $0.title == target.lastPathComponent }!
    let breadcrumbDrag = TransferUIDrag(view: breadcrumb, board: board, point: .zero)
    try check(breadcrumb.draggingEntered(breadcrumbDrag).isEmpty && !breadcrumb.performDragOperation(breadcrumbDrag), "Address breadcrumbs reject their own folder without starting a transfer")
    board.clearContents(); board.writeObjects([existing as NSURL])
    let copy = TransferUIDrag(view: browser.collection, board: board, point: .zero)
    try check(browser.collectionView(browser.collection, acceptDrop: copy, indexPath: IndexPath(item: browser.entries.count, section: 0), dropOperation: .before), "Copying within the current folder is still accepted")
    try await until { !browser.busy && !browser.loading }
    let duplicate = browser.entries.first { $0.url != existing && !$0.isDirectory }
    try check(browser.lastError == nil && duplicate != nil && (try Data(contentsOf: duplicate!.url)) == Data("existing".utf8), "Same-directory copying creates a numbered duplicate")
    try fm.removeItem(at: duplicate!.url)
    board.clearContents(); board.writeObjects([file as NSURL])
    for action in ["skip", "sheet-cancel", "escape", "cancel", "close", "keep-both", "retry"] {
      fputs("Collision fixture: \(action)\n", stderr)
      let panel = NativeTransferPanel(parent: window, showsWindows: false)
      var result: FileActionResult?
      browser.runTransferOperation(panel: panel, completion: { result = $0 }) { control in FileActions.transfer([file], to: target, move: false, control: control) }
      try await until { panel.pendingAlert != nil }
      let alert = panel.pendingAlert!.0
      if action == "close" { panel.window.performClose(nil) }
      else if action == "cancel" { panel.cancel.performClick(nil) }
      else {
        if action == "retry" { try fm.moveItem(at: existing, to: target.appendingPathComponent("previous.txt")) }
        let offset = action == "retry" ? 0 : action == "keep-both" ? 1 : action == "sheet-cancel" ? 3 : 2
        panel.resolve(alert, response: action == "escape" ? .cancel : .init(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + offset))
      }
      try await until { !browser.busy && result != nil }
      try check(panel.pendingAlert == nil && panel.control == nil && !panel.window.isVisible, "\(action): collision resolves the worker and closes its transfer panel")
      try check(try Data(contentsOf: file) == Data("source".utf8), "\(action): resolving a copy collision preserves the source")
      let old = action == "retry" ? target.appendingPathComponent("previous.txt") : existing
      try check(try Data(contentsOf: old) == Data("existing".utf8), "\(action): collision never overwrites the existing file")
      if action == "keep-both" || action == "retry" { try check(result!.succeeded.count == 1, "\(action): selected collision decision finishes the copy") }
      panel.resolve(alert, response: .alertFirstButtonReturn)
      if action == "keep-both" { try fm.removeItem(at: result!.succeeded[0]) }
    }
    let next = NativeTransferPanel(parent: window, showsWindows: false)
    browser.runTransferOperation(panel: next) { control in FileActions.transfer([file], to: empty, move: false, control: control) }
    try await until { !browser.busy && fm.fileExists(atPath: empty.appendingPathComponent("item.txt").path) }
    try check(try Data(contentsOf: empty.appendingPathComponent("item.txt")) == Data("source".utf8), "A new transfer succeeds in the same browser after collision cancellation")
    for login in [false, true] {
      let panel = NativeTransferPanel(parent: nil, showsWindows: false); panel.control = FileTransferControl()
      var replies = 0
      if login { panel.login(server: "fixture.invalid", account: "fixture", previous: nil, error: nil) { _ in replies += 1 } }
      else { panel.present(NSAlert()) { _ in replies += 1 } }
      let alert = panel.pendingAlert!.0
      panel.cancel.performClick(nil); panel.resolve(alert, response: .alertFirstButtonReturn); panel.close()
      try check(replies == 1 && panel.pendingAlert == nil, "Cancelling \(login ? "login" : "keychain warning") releases exactly one reply, including late sheet callbacks")
    }
    let panel = NativeTransferPanel(parent: nil, showsWindows: false); panel.control = FileTransferControl()
    var answers: [String] = []
    let first = NSAlert(), second = NSAlert()
    panel.present(first) { _ in answers.append("first") }; panel.resolve(first, response: .alertFirstButtonReturn)
    panel.present(second) { _ in answers.append("second") }; panel.resolve(first, response: .abort)
    try check(answers == ["first"] && panel.pendingAlert?.0 === second, "A late callback cannot resolve the next sheet")
    panel.close(); try check(answers == ["first", "second"], "Closing the panel releases any final pending reply")
    try await Task.sleep(nanoseconds: 350_000_000)
    try check(!NSApp.windows.contains { $0.isVisible }, "Transfer checks never display or focus a window, including delayed progress panels")
    try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("report.json"))
  }
}
