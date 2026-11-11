import AppKit
import ExplorerCore
import UniformTypeIdentifiers

final class NativeArchiveWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
  private struct Row {
    let path: String
    let directory: Bool
    let size: Int64
    var name: String { (path as NSString).lastPathComponent }
  }
  private static var presentations: [ObjectIdentifier: NativeArchiveWindow] = [:]
  private static var preparedDirectories: [URL] = []
  private static var cleanupObserver: NSObjectProtocol?
  private let archive: URL
  private let onExtracted: (FileActionResult) -> Void
  private var preview: NativeArchivePreview?
  private var directory = ""
  private var rows: [Row] = []
  private var selected = Set<String>()
  private var busy = false
  private let root = ExplorerRootView()
  private let back = NSButton(title: "", target: nil, action: nil)
  private let location = label("", size: 13)
  private let all = NSButton(checkboxWithTitle: NL("全选"), target: nil, action: nil)
  private let target = ExplorerPopUpButton(frame: .zero, pullsDown: false)
  private let extractAll = NSButton(title: NL("全部解压"), target: nil, action: nil)
  private let extractSelected = NSButton(title: NL("解压所选"), target: nil, action: nil)
  private let table = ArchiveTable()
  private let scroll = ExplorerScrollView()
  private let status = label(NL("正在读取…"), size: 12)

  var visibleEntryPaths: [String] { rows.map(\.path) }
  var selectedEntryPaths: Set<String> { selected }
  var isBusy: Bool { busy }

  @discardableResult
  func enterDirectory(_ path: String) -> Bool {
    guard !busy, rows.contains(where: { $0.path == path && $0.directory }) else { return false }
    directory = path; rebuildRows(); return true
  }

  @discardableResult
  static func present(archive: URL, parent: NSWindow, onExtracted: @escaping (FileActionResult) -> Void) -> NativeArchiveWindow {
    let controller = NativeArchiveWindow(archive: archive, onExtracted: onExtracted)
    guard let window = controller.window else { return controller }
    presentations[ObjectIdentifier(window)] = controller
    window.appearance = parent.appearance
    window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2))
    controller.showWindow(nil)
    if cleanupObserver == nil {
      cleanupObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        preparedDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        preparedDirectories.removeAll()
      }
    }
    return controller
  }

  private init(archive: URL, onExtracted: @escaping (FileActionResult) -> Void) {
    self.archive = archive; self.onExtracted = onExtracted
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    super.init(window: window)
    window.title = archive.lastPathComponent; window.minSize = NSSize(width: 650, height: 380); window.delegate = self; window.contentView = root
    [back, location, all, target, extractAll, extractSelected, scroll, status].forEach(root.addSubview)
    root.onLayout = { [weak self] in self?.layout() }
    back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: NL("上一级")); back.setAccessibilityLabel(NL("上一级")); back.target = self; back.action = #selector(up)
    all.target = self; all.action = #selector(selectAllEntries)
    target.addItems(withTitles: [NL("同名文件夹"), NL("当前文件夹"), NL("选择文件夹…")]); target.setAccessibilityLabel(NL("解压位置"))
    extractAll.target = self; extractAll.action = #selector(extractEverything); extractAll.bezelStyle = .rounded
    extractSelected.target = self; extractSelected.action = #selector(extractSelection); extractSelected.bezelStyle = .rounded
    let check = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check")); check.title = ""; check.width = 32; check.minWidth = 32; check.maxWidth = 32
    let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = NL("名称"); name.width = 450; name.minWidth = 160
    let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size")); size.title = NL("大小"); size.width = 120; size.minWidth = 90
    [check, name, size].forEach(table.addTableColumn)
    table.dataSource = self; table.delegate = self; table.rowHeight = 32; table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.target = self; table.doubleAction = #selector(openEntry); table.setAccessibilityLabel(NL("压缩包内容"))
    table.onToggle = { [weak self] in self?.toggleHighlightedRows() }
    scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.borderType = .bezelBorder
    layout(); setBusy(true)
    Task { @MainActor [weak self] in
      do {
        let preview = try await Task.detached(priority: .userInitiated) { try NativeArchives.preview(archive) }.value
        guard let self, self.window?.isVisible == true else { return }
        self.preview = preview; self.rebuildRows(); self.status.stringValue = NL("{0} 个项目", preview.entries.count); self.setBusy(false)
      } catch { self?.status.stringValue = error.localizedDescription; self?.setBusy(false) }
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  private func layout() {
    let width = root.bounds.width, height = root.bounds.height
    back.frame = NSRect(x: 16, y: 14, width: 30, height: 28)
    location.frame = NSRect(x: 56, y: 17, width: max(0, width - 72), height: 24)
    all.frame = NSRect(x: 18, y: 54, width: 100, height: 28)
    target.frame = NSRect(x: width - 440, y: 52, width: 174, height: 30)
    extractSelected.frame = NSRect(x: width - 256, y: 52, width: 118, height: 30)
    extractAll.frame = NSRect(x: width - 130, y: 52, width: 114, height: 30)
    scroll.frame = NSRect(x: 16, y: 94, width: max(0, width - 32), height: max(0, height - 138))
    status.frame = NSRect(x: 18, y: height - 32, width: max(0, width - 36), height: 22)
  }

  private func rebuildRows() {
    guard let preview else { return }
    let prefix = directory.isEmpty ? "" : directory + "/"
    var items: [String: Row] = [:]
    for entry in preview.entries where entry.path.hasPrefix(prefix) {
      let relative = String(entry.path.dropFirst(prefix.count))
      guard !relative.isEmpty, let name = relative.split(separator: "/").first else { continue }
      let path = prefix + String(name), isDirectory = relative.contains("/") || entry.directory
      let row = Row(path: path, directory: isDirectory, size: isDirectory ? 0 : entry.size)
      if items[path] == nil || isDirectory { items[path] = row }
    }
    rows = items.values.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    location.stringValue = archive.lastPathComponent + (directory.isEmpty ? "" : " / " + directory)
    table.reloadData(); updateSelection()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
    guard rows.indices.contains(index), let tableColumn else { return nil }
    let row = rows[index]
    if tableColumn.identifier.rawValue == "check" {
      let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
      button.tag = index; button.state = selectionState(row.path); button.isEnabled = !busy; button.setAccessibilityLabel(NL("选择 {0}", row.name)); return button
    }
    if tableColumn.identifier.rawValue == "size" { return label(row.directory ? "" : ExplorerFormat.size(row.size), size: 12) }
    let icon = NSImageView(); icon.image = NSWorkspace.shared.icon(for: row.directory ? .folder : UTType(filenameExtension: (row.name as NSString).pathExtension) ?? .data); icon.imageScaling = .scaleProportionallyDown
    let name = label(row.name, size: 13); name.toolTip = row.path
    let stack = NSStackView(views: [icon, name]); stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
    icon.widthAnchor.constraint(equalToConstant: 24).isActive = true; icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
    return stack
  }

  private func selectionState(_ path: String) -> NSControl.StateValue {
    if selected.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .on }
    return selected.contains(where: { $0.hasPrefix(path + "/") }) ? .mixed : .off
  }
  private func updateSelection() {
    let states = rows.map { selectionState($0.path) }
    all.state = !states.isEmpty && states.allSatisfy({ $0 == .on }) ? .on : states.contains(where: { $0 != .off }) ? .mixed : .off
    extractSelected.isEnabled = !busy && !selected.isEmpty; extractAll.isEnabled = !busy && preview != nil
    all.isEnabled = !busy && !rows.isEmpty; back.isEnabled = !busy && !directory.isEmpty
  }
  private func toggle(_ path: String) {
    let state = selectionState(path)
    // Expand an ancestor before unchecking a descendant, preserving its siblings.
    if state == .on, let ancestor = selected.first(where: { path.hasPrefix($0 + "/") }), let preview {
      selected.remove(ancestor)
      for entry in preview.entries where !entry.directory && entry.path.hasPrefix(ancestor + "/") && entry.path != path && !entry.path.hasPrefix(path + "/") { selected.insert(entry.path) }
      for entry in preview.entries where entry.directory && entry.path.hasPrefix(ancestor + "/") && entry.path != path && !entry.path.hasPrefix(path + "/") && !path.hasPrefix(entry.path + "/") { selected.insert(entry.path) }
    }
    selected = selected.filter { $0 != path && !$0.hasPrefix(path + "/") }
    if state != .on { selected.insert(path) }
  }
  @objc private func toggleCheck(_ sender: NSButton) { guard !busy, rows.indices.contains(sender.tag) else { return }; toggle(rows[sender.tag].path); table.reloadData(); updateSelection() }
  private func toggleHighlightedRows() { guard !busy else { return }; for index in table.selectedRowIndexes where rows.indices.contains(index) { toggle(rows[index].path) }; table.reloadData(); updateSelection() }
  @objc private func selectAllEntries() {
    guard !busy else { return }
    let clear = !rows.isEmpty && rows.allSatisfy { selectionState($0.path) == .on }
    for row in rows where (selectionState(row.path) == .on) == clear { toggle(row.path) }
    table.reloadData(); updateSelection()
  }
  @objc private func up() { guard !busy else { return }; directory = (directory as NSString).deletingLastPathComponent; if directory == "." { directory = "" }; rebuildRows() }
  @objc private func openEntry() {
    guard !busy, rows.indices.contains(table.clickedRow) else { return }
    let row = rows[table.clickedRow]
    if row.directory { enterDirectory(row.path); return }
    setBusy(true); status.stringValue = NL("正在打开…")
    let archive = archive
    Task { @MainActor [weak self] in
      do {
        let prepared = try await Task.detached(priority: .userInitiated) { try NativeArchives.prepareFile(archive, member: row.path) }.value
        Self.preparedDirectories.append(prepared.directory)
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open(prepared.file, configuration: configuration) { [weak self] _, error in
          DispatchQueue.main.async { self?.status.stringValue = error?.localizedDescription ?? row.name; self?.setBusy(false) }
        }
      } catch { self?.status.stringValue = error.localizedDescription; self?.setBusy(false) }
    }
  }
  @objc private func extractEverything() { extract(nil) }
  @objc private func extractSelection() { guard !selected.isEmpty else { return }; extract(selected.sorted()) }
  private func extract(_ selected: [String]?) {
    guard !busy, let window else { return }
    if target.indexOfSelectedItem == 2 {
      let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = archive.deletingLastPathComponent(); panel.prompt = NL("解压")
      panel.beginSheetModal(for: window) { [weak self] response in
        guard response == .OK, let directory = panel.url else { return }; self?.performExtraction(to: directory, selected: selected, namedFolder: false)
      }
    } else { performExtraction(to: archive.deletingLastPathComponent(), selected: selected, namedFolder: target.indexOfSelectedItem == 0) }
  }
  private func performExtraction(to destination: URL, selected: [String]?, namedFolder: Bool) {
    setBusy(true); status.stringValue = NL("正在解压…")
    let archive = archive, onExtracted = onExtracted
    Task { @MainActor [weak self] in
      do {
        let result = try await Task.detached(priority: .userInitiated) { try NativeArchives.extract(archive, to: destination, selected: selected, namedFolder: namedFolder) }.value
        onExtracted(result); self?.status.stringValue = result.errors.isEmpty ? NL("已解压 {0} 个项目", result.succeeded.count) : result.errors.joined(separator: "\n"); self?.status.toolTip = self?.status.stringValue; self?.setBusy(false)
      } catch { self?.status.stringValue = error.localizedDescription; self?.status.toolTip = error.localizedDescription; self?.setBusy(false) }
    }
  }
  private func setBusy(_ value: Bool) { busy = value; target.isEnabled = !value; table.isEnabled = !value; updateSelection(); table.reloadData() }
  func windowWillClose(_ notification: Notification) { if let window { Self.presentations.removeValue(forKey: ObjectIdentifier(window)) } }
}

private final class ArchiveTable: NSTableView {
  var onToggle: (() -> Void)?
  override func keyDown(with event: NSEvent) { if event.keyCode == 49 { onToggle?() } else { super.keyDown(with: event) } }
}
