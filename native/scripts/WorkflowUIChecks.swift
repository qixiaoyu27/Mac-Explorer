import AppKit
import ExplorerCore

private final class WorkflowPointerWindow: NSWindow {
  var pointerIsActive = false
  var pointer = NSPoint(x: -1000, y: -1000)
  override var isKeyWindow: Bool { pointerIsActive || super.isKeyWindow }
  override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

@MainActor
enum NativeWorkflowChecks {
  static func run(output: URL) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("explorer-workflow-" + UUID().uuidString)
    let folder = root.appendingPathComponent("Folder")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<90 { try Data("original-\(index)".utf8).write(to: root.appendingPathComponent(String(format: "File %03d", index) + (index % 2 == 0 ? ".txt" : ".md"))) }
    let suite = "local.macexplorer.workflow." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl")
    ExplorerTypography.configure(defaults)
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    let window = WorkflowPointerWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; browser.reload()
    defer { browser.stopObserving(); browser.filePasteboard.releaseGlobally(); window.close(); defaults.removePersistentDomain(forName: suite); ExplorerTypography.baseSize = 13; try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ value: Bool, _ text: String) throws { guard value else { throw NativeSmoke.Failure(description: text) }; checks.append(text); print("PASS workflow: " + text) }
    func until(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(12)
      while !condition() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Workflow timed out") }; try await Task.sleep(nanoseconds: 20_000_000) }
      window.contentView?.layoutSubtreeIfNeeded(); browser.collection.layoutSubtreeIfNeeded()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    try await until { !browser.loading && browser.entries.count == 91 }
    try check(browser.groupMode == .none && browser.displayRows.count == browser.entries.count, "Grouping starts disabled")
    try check(browser.viewMenu().contains { $0.title == NL("分组依据") } && !browser.sortMenu().contains { $0.title == NL("分组依据") }, "Grouping is offered in View")
    for layout in [ExplorerLayoutMode.details, .icons, .list, .tiles, .content] {
      browser.setView(layout, size: 64); browser.setGrouping(.kind); window.contentView?.layoutSubtreeIfNeeded()
      try check(browser.displayRows.compactMap(\.entry).count == 91, "\(layout): grouping retains every file")
      for row in browser.displayRows.indices {
        if let index = browser.entryIndex(at: row) {
          let writer = layout == .details ? browser.tableView(browser.table, pasteboardWriterForRow: row) : browser.collectionView(browser.collection, pasteboardWriterForItemAt: IndexPath(item: row, section: 0))
          guard (writer as? NSURL)?.path == browser.entries[index].url.path else { throw NativeSmoke.Failure(description: "Grouped drag maps to wrong file") }
          if layout != .details, let attrs = browser.collectionLayout.layoutAttributesForItem(at: IndexPath(item: row, section: 0)) {
            let hit = browser.collectionLayout.layoutAttributesForDropTarget(at: NSPoint(x: attrs.frame.midX, y: attrs.frame.midY))
            guard hit?.indexPath?.item == row else { throw NativeSmoke.Failure(description: "Grouped drop maps to wrong file") }
          }
        } else { try check(browser.tableView(browser.table, pasteboardWriterForRow: row) == nil, "\(layout): headers cannot be dragged as files") }
      }
      let row = browser.displayRows.firstIndex { $0.group != nil }!
      let group = browser.groups[browser.groupIndex(at: row)!]
      let groupPaths = Set(group.entries.map(\.id))
      browser.selectedPaths = groupPaths; browser.toggleGroup(at: row)
      let visibleSelectionCount = layout == .details ? browser.table.selectedRowIndexes.count : browser.collection.selectionIndexPaths.count
      try check(browser.selectedPaths == groupPaths && visibleSelectionCount == 0 &&
                browser.displayRows.compactMap(\.entry).count == 91 - group.entries.count, "\(layout): collapse preserves selection and removes hidden rows from the view")
      browser.selectAllFiles()
      try check(browser.selectedEntries().count == 91, "\(layout): Select All includes collapsed items")
      browser.toggleGroup(at: row)
    }
    browser.checkboxes = true; browser.setView(.details); browser.setGrouping(.none); window.contentView?.layoutSubtreeIfNeeded()
    let nameColumn = browser.table.column(withIdentifier: .init("name"))
    func nameCell(_ row: Int) -> NameCell { browser.table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as! NameCell }
    func checkboxMatches(_ row: Int) -> Bool { nameCell(row).checkbox.state == (browser.table.selectedRowIndexes.contains(row) ? .on : .off) }
    browser.table.selectRowIndexes([0], byExtendingSelection: false); window.contentView?.layoutSubtreeIfNeeded()
    try check(checkboxMatches(0) && !nameCell(0).checkbox.isHidden, "Selecting a Details row immediately checks and reveals its checkbox")
    browser.table.selectRowIndexes([1], byExtendingSelection: true)
    try check(checkboxMatches(0) && checkboxMatches(1), "Adding a row to the selection checks both boxes")
    browser.table.selectRowIndexes([2], byExtendingSelection: false)
    try check((0...2).allSatisfy(checkboxMatches), "Selecting another row clears the previous checkboxes")
    browser.table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)!)
    try check(browser.table.selectedRowIndexes == [2, 3] && (0...3).allSatisfy(checkboxMatches), "Keyboard range selection keeps checkboxes synchronized")
    browser.table.deselectAll(nil)
    try check((0...3).allSatisfy(checkboxMatches), "Clearing the selection unchecks all visible rows")
    let firstID = browser.entries[browser.entryIndex(at: 0)!].id
    let secondID = browser.entries[browser.entryIndex(at: 1)!].id
    nameCell(0).checkbox.performClick(nil); window.contentView?.layoutSubtreeIfNeeded()
    try check(browser.selectedPaths == [firstID] && checkboxMatches(0), "Clicking a checkbox selects its row")
    nameCell(1).checkbox.performClick(nil); window.contentView?.layoutSubtreeIfNeeded()
    try check(browser.selectedPaths == [firstID, secondID] && checkboxMatches(0) && checkboxMatches(1), "Clicking another checkbox preserves existing selections")
    nameCell(0).checkbox.performClick(nil); window.contentView?.layoutSubtreeIfNeeded()
    try check(browser.selectedPaths == [secondID] && checkboxMatches(0) && checkboxMatches(1), "Unchecking one box clears only its row")
    browser.table.scrollRowToVisible(80); window.contentView?.layoutSubtreeIfNeeded()
    browser.table.scrollRowToVisible(0); window.contentView?.layoutSubtreeIfNeeded()
    try check(checkboxMatches(0) && checkboxMatches(1), "Recreated rows retain the correct checkbox selection")
    let hoverSelection = browser.selectedPaths
    window.pointerIsActive = true
    let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    let firstRow = browser.table.rowView(atRow: 2, makeIfNecessary: true) as! FileRowView
    let rowFrame = browser.table.rect(ofRow: 2)
    window.pointer = browser.table.convert(NSPoint(x: rowFrame.minX + 100, y: rowFrame.midY), to: nil)
    firstRow.mouseEntered(with: hoverEvent)
    try check(firstRow.hovered, "The row under the pointer receives a hover background")
    let tableOrigin = browser.fileScroll.contentView.bounds.origin
    for offset: CGFloat in [8, 16, 3, 0] {
      browser.fileScroll.contentView.scroll(to: NSPoint(x: tableOrigin.x, y: tableOrigin.y + offset * browser.table.rowHeight))
      browser.fileScroll.reflectScrolledClipView(browser.fileScroll.contentView); window.contentView?.layoutSubtreeIfNeeded()
      let visible = browser.table.rows(in: browser.table.visibleRect)
      let rows = (visible.location..<NSMaxRange(visible)).compactMap { browser.table.rowView(atRow: $0, makeIfNecessary: true) as? FileRowView }
      firstRow.updateTrackingAreas(); rows.forEach { $0.updateTrackingAreas() }
      let target = browser.table.row(at: browser.table.convert(window.pointer, from: nil))
      let targetView = browser.table.rowView(atRow: target, makeIfNecessary: false)
      let hovered = rows.filter(\.hovered)
      try check(hovered.count == 1 && hovered.first === targetView && firstRow.hovered == (firstRow === targetView), "Details scroll offset \(offset): only the row currently under the stationary pointer stays hovered")
    }
    let originalSize = window.contentView!.bounds.size
    window.setContentSize(NSSize(width: 900, height: 500))
    for mode in [ExplorerLayoutMode.icons, .list, .tiles, .content] {
      browser.setView(mode, size: 64); window.contentView?.layoutSubtreeIfNeeded()
      let clip = browser.fileScroll.contentView
      clip.scroll(to: .zero); browser.fileScroll.reflectScrolledClipView(clip); browser.collection.layoutSubtreeIfNeeded()
      let firstPath = browser.collection.indexPathsForVisibleItems().min { $0.item < $1.item }!
      let first = browser.collection.item(at: firstPath)!.view as! ItemSurface
      window.pointer = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
      first.mouseEntered(with: hoverEvent)
      try check(first.hovered, "\(mode): the item under the pointer receives a hover background")
      let extent = mode == .list ? browser.collection.bounds.width - clip.bounds.width : browser.collection.bounds.height - clip.bounds.height
      try check(extent > 0, "\(mode): the hover fixture genuinely scrolls")
      for fraction: CGFloat in [0.35, 0.75, 0.15, 0] {
        clip.scroll(to: mode == .list ? NSPoint(x: extent * fraction, y: 0) : NSPoint(x: 0, y: extent * fraction))
        browser.fileScroll.reflectScrolledClipView(clip); browser.collection.layoutSubtreeIfNeeded()
        let surfaces = browser.collection.visibleItems().map(\.view).compactMap { $0 as? ItemSurface }
        first.updateTrackingAreas(); surfaces.forEach { $0.updateTrackingAreas() }
        let targetPath = browser.collection.indexPathForItem(at: browser.collection.convert(window.pointer, from: nil))
        let target = targetPath.flatMap { browser.collection.item(at: $0)?.view }
        let hovered = surfaces.filter(\.hovered)
        try check(target == nil ? hovered.isEmpty : hovered.count == 1 && hovered.first === target, "\(mode) scroll fraction \(fraction): recycled items do not retain hover backgrounds [target=\(String(describing: targetPath)), hovered=\(hovered.count)]")
        let trackingTargets = surfaces.filter { surface in
          surface.trackingAreas.contains { area in
            let rect = area.options.contains(.inVisibleRect) ? surface.visibleRect : area.rect
            return rect.contains(surface.convert(window.pointer, from: nil))
          }
        }
        try check(target == nil ? trackingTargets.isEmpty : trackingTargets.count == 1 && trackingTargets.first === target, "\(mode) scroll fraction \(fraction): mouse tracking areas cover only the current file")
      }
      window.pointer = NSPoint(x: -1000, y: -1000)
      let surfaces = browser.collection.visibleItems().map(\.view).compactMap { $0 as? ItemSurface }
      surfaces.forEach { $0.updateTrackingAreas() }
      try check(!surfaces.contains(where: \.hovered), "\(mode): leaving the file area clears every hover background")
    }
    window.setContentSize(originalSize)
    window.pointerIsActive = false
    try check(browser.selectedPaths == hoverSelection, "Scrolling and hover tracking preserve the selected files")
    browser.setView(.details)
    browser.setGrouping(.modified)
    let selected = browser.entries.last!.id
    browser.selectedPaths = [selected]; browser.updateMode(persist: false)
    browser.fileScroll.contentView.scroll(to: NSPoint(x: 0, y: 1200)); browser.fileScroll.reflectScrolledClipView(browser.fileScroll.contentView)
    let originalOffset = browser.fileScroll.contentView.bounds.origin
    browser.openTab(at: folder); try await until { !browser.loading && browser.directory.path == folder.path }
    try check(browser.groupMode == .none, "A different folder retains its independent grouping preference")
    browser.closeTab(); try await until { !browser.loading && browser.directory.path == root.path }
    try check(browser.groupMode == .modified && browser.selectedPaths == [selected] && abs(browser.fileScroll.contentView.bounds.origin.y - originalOffset.y) < 2, "Returning to a grouped tab restores its scroll and selection; mode=\(browser.groupMode), selection=\(browser.selectedPaths), before=\(originalOffset), after=\(browser.fileScroll.contentView.bounds.origin)")
    for mode in [ExplorerLayoutMode.details, .icons] {
      browser.setView(mode)
      let fileView = browser.fileScroll.documentView
      var renamed = false, opened = false
      let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
      let open = browser.selectionManager.openSelection
      browser.selectionManager.openSelection = { opened = true }
      defer { browser.selectionManager.openSelection = open }
      if let table = fileView as? FileTableView { let rename = table.renameSelection; table.renameSelection = { renamed = true }; table.keyDown(with: key); table.renameSelection = rename }
      if let collection = fileView as? FileCollectionView { let rename = collection.renameSelection; collection.renameSelection = { renamed = true }; collection.keyDown(with: key); collection.renameSelection = rename }
      try check(renamed && !opened, "Return retains the existing rename action")
    }
    let filenameFixtures = ["数字员工平台需求说明.docx", "Codex 实施文档与数字员工平台系统运行流程和配置说明（修订版）.md", String(repeating: "LongFileName", count: 6) + ".txt"]
    for name in filenameFixtures { try Data("filename fixture".utf8).write(to: folder.appendingPathComponent(name)) }
    browser.openTab(at: folder); try await until { !browser.loading && browser.entries.count == filenameFixtures.count }
    browser.extensions = true; browser.setView(.icons, size: 64)
    for name in filenameFixtures {
      let row = browser.displayRows.firstIndex { $0.entry.map { browser.entries[$0].name == name } == true }!
      let path = IndexPath(item: row, section: 0)
      browser.collection.scrollToItems(at: [path], scrollPosition: .top); browser.collection.layoutSubtreeIfNeeded()
      let frames = browser.displayRows.indices.compactMap { browser.collectionLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
      browser.collection.selectionIndexPaths = [path]
      browser.collectionView(browser.collection, didSelectItemsAt: [path]); browser.collection.layoutSubtreeIfNeeded()
      guard let item = browser.collection.item(at: path) as? IconItem else { throw NativeSmoke.Failure(description: "Missing filename fixture") }
      let field = item.nameLabel
      try check(field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000)).height > ExplorerTypography.lineHeight, "Icon filenames render across multiple lines: \(name)")
      let expanded = browser.collection.subviews.compactMap { $0 as? NativeExpandedNameView }
      let fullText = NSTextField(labelWithString: name)
      fullText.font = field.font; fullText.maximumNumberOfLines = 0; fullText.lineBreakMode = .byWordWrapping
      let fullHeight = fullText.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width - 4, height: 10_000)).height
      if fullHeight > field.bounds.height {
        guard let overlay = expanded.first, let text = descendants(overlay).compactMap({ $0 as? NSTextField }).first else { throw NativeSmoke.Failure(description: "Single click did not expand the complete filename") }
        overlay.layoutSubtreeIfNeeded()
        let renderedHeight = text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.bounds.width, height: 10_000)).height
        try check(expanded.count == 1 && text.stringValue == name && renderedHeight <= text.bounds.height, "Selection displays the complete filename within its expanded label [count=\(expanded.count), name=\(text.stringValue), height=\(renderedHeight), available=\(text.bounds.height)]")
        try check(overlay.frame.width == item.view.bounds.width, "Expanded selection keeps the icon card width")
        try check(frames == browser.displayRows.indices.compactMap { browser.collectionLayout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }, "Filename expansion preserves the icon grid")
        let point = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.maxY - 2), to: browser.collection)
        try check(browser.collection.hitTest(point) !== overlay, "Expanded text does not intercept file selection")
        if name.hasPrefix("Codex"), let bitmap = window.contentView?.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
          window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
          try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("workflow-selected-filename.png"))
        }
      } else {
        try check(expanded.isEmpty, "A filename fitting in two lines needs no expansion")
      }
      browser.executeAction("rename")
      guard let editor = field.currentEditor() as? NSTextView else { throw NativeSmoke.Failure(description: "Missing filename editor") }
      let stem = (name as NSString).deletingPathExtension
      try check(editor.selectedRange() == NSRange(location: 0, length: (stem as NSString).length), "Inline rename selects the filename stem and preserves the extension")
      try check(!browser.collection.subviews.contains { $0 is NativeExpandedNameView }, "Inline rename removes expanded text")
      _ = browser.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
      browser.collection.layoutSubtreeIfNeeded()
      try check(fm.fileExists(atPath: folder.appendingPathComponent(name).path), "Cancelling inline rename preserves the original filename")
    }
    browser.collection.deselectAll(nil); browser.collection.layoutSubtreeIfNeeded()
    try check(!browser.collection.subviews.contains { $0 is NativeExpandedNameView }, "Deselecting collapses the complete filename")
    browser.closeTab(); try await until { !browser.loading && browser.directory.path == root.path }
    let sources = Array(browser.entries.filter { !$0.isDirectory }.prefix(2)).map(\.url)
    let form = EDBatchRenameForm(sources: sources)
    form.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
    try check(!form.isValid, "Batch editor disables empty rules")
    form.prefix.stringValue = "New-"; form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.prefix)); form.layoutSubtreeIfNeeded()
    try check(form.isValid && descendants(form).compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains(" → New-") }, "Batch editor previews source and destination names")
    form.prefix.stringValue = "bad/"; form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.prefix))
    try check(!form.isValid, "Invalid names are rejected before submission")
    form.prefix.stringValue = "New-"; form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.prefix))
    browser.runAsyncOperation { FileActions.batchRename(sources, options: BatchRenameOptions(prefix: "New-")) }
    try await until { !browser.busy && !browser.loading }
    browser.undoFiles(); try await until { !browser.busy && !browser.loading }
    try check(sources.allSatisfy { fm.fileExists(atPath: $0.path) }, "One UI undo restores the batch")
    browser.redoFiles(); try await until { !browser.busy && !browser.loading }
    try check(sources.allSatisfy { fm.fileExists(atPath: $0.deletingLastPathComponent().appendingPathComponent("New-" + $0.lastPathComponent).path) }, "One UI redo reapplies the batch")
    defaults.set("custom", forKey: NativeStartLocation.preferenceKey); defaults.set(folder.path, forKey: NativeStartLocation.customPathKey)
    browser.newTab(); try await until { !browser.loading }
    try check(browser.directory.path == folder.path, "New tabs use the custom startup folder")
    try NativeSessions.save([NativeSavedWindow(locations: [root.absoluteString, "explorer://computer"], frame: "")], to: defaults)
    browser.restoreLocations(NativeSessions.load(defaults)[0].locations)
    try check(browser.tabs.contains { $0.directory.absoluteString == "explorer://computer" }, "Custom startup does not suppress saved-session locations")
    var attempted: [String] = []
    browser.reconnectServer = { attempted.append($0); return nil }
    browser.rememberServer("smb://server/share"); browser.rememberServer("smb://user:password@server/private")
    browser.reconnectSavedServers(); await Task.yield()
    try check(attempted.isEmpty && defaults.stringArray(forKey: "recentSMBServers") == ["smb://server/share"], "Reconnect defaults off and never stores credentials")
    defaults.set(true, forKey: "autoReconnectSMB"); browser.reconnectSavedServers(); try await until { attempted.count == 1 }
    try check(attempted == ["smb://server/share"], "Opt-in reconnect uses the validated successful endpoint")
    for size in [24, 10, 24, 13] {
      defaults.set(size, forKey: ExplorerTypography.preferenceKey)
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
      try await until { ExplorerTypography.baseSize == CGFloat(size) && !browser.loading }
      browser.setView(.details); window.contentView?.layoutSubtreeIfNeeded()
      let cell = NameCell(frame: NSRect(x: 0, y: 0, width: 400, height: browser.table.rowHeight)); cell.configure(browser.entries.first ?? FileEntry(url: root, name: "Fixture", isDirectory: true, isSymbolicLink: false, isPackage: false, size: 0, modified: nil, isHidden: false)); cell.layoutSubtreeIfNeeded()
      try check(cell.nameLabel.font?.pointSize == CGFloat(size) && cell.bounds.contains(cell.nameLabel.frame), "\(size) pt: repeated changes preserve font size and fit the file row")
      try check(cell.nameLabel.font == NSFont.systemFont(ofSize: CGFloat(size)) && ExplorerTypography.font(weight: .regular) == NSFont.systemFont(ofSize: CGFloat(size)), "\(size) pt: file labels use the standard system font weight")
      browser.setView(.icons, size: 64); browser.collection.layoutSubtreeIfNeeded()
      let settings = EDSettingsBody(theme: "light", toolbar: [], shortcutRows: [], onTheme: { _ in }, onToolbar: nil, onShortcut: nil, shortcutDefaults: [:], folderDefaults: [:], onFolderDefaults: nil, onResetFolders: nil)
      settings.browser = browser; settings.openTab(0); settings.frame = NSRect(x: 0, y: 0, width: 850, height: 600); settings.layoutSubtreeIfNeeded()
      let controls = descendants(settings).compactMap { $0 as? NSButton }
      try check(controls.contains { $0.accessibilityLabel() == NL("默认打开") } && controls.contains { $0.accessibilityLabel() == NL("界面文字") } && !controls.contains { $0.title == NL("日常精简") }, "\(size) pt: settings retain startup and font controls without a profile mode")
      if size == 24, let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) { settings.cacheDisplay(in: settings.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("workflow-settings-24pt.png")) }
    }
    var reconnectCancelled = false
    var reconnectStarted = false
    browser.reconnectServer = { _ in
      reconnectStarted = true
      do { try await Task.sleep(nanoseconds: 5_000_000_000) }
      catch { reconnectCancelled = Task.isCancelled }
      return nil
    }
    await Task.yield(); browser.reconnectSavedServers(); try await until { reconnectStarted }; browser.stopObserving()
    try await until { reconnectCancelled }
    try check(reconnectCancelled, "Closing the owner cancels pending reconnect")
    try check(!window.isVisible, "All workflow checks leave the desktop foreground unchanged")
    return checks
  }
}
