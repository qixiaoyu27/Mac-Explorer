import AppKit
import ExplorerCore

@MainActor
enum NativeParityChecks {
  static func run(source: BrowserController, output: URL) async throws -> [String] {
    var checks: [String] = []
    func expect(_ value: Bool, _ message: String) throws {
      guard value else { throw NativeSmoke.Failure(description: message) }; checks.append(message)
    }
    let iconSheet = NSImage(size: NSSize(width: 720, height: 240))
    iconSheet.lockFocusFlipped(true)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 720, height: 240).fill()
    let names = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Public", "Sites", "Library", "Applications", "workplace"]
    for (index, name) in names.enumerated() {
      let x = CGFloat(index % 6) * 120, y = CGFloat(index / 6) * 120
      ExplorerIcons.folder(size: 80, url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)).draw(in: NSRect(x: x + 20, y: y + 4, width: 80, height: 80), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      (name as NSString).draw(at: NSPoint(x: x + 12, y: y + 88), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }
    iconSheet.unlockFocus()
    if let data = iconSheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
      try png.write(to: output.appendingPathComponent("special-folder-icons.png"))
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    for (name, badge) in [("Desktop", "desktop"), ("Documents", "document"), ("Downloads", "download"), ("Pictures", "image"), ("Music", "music"), ("Movies", "video"), ("Public", "public"), ("Sites", "network"), ("Library", "library"), ("Applications", "applications")] {
      let url = home.appendingPathComponent(name)
      try expect(ExplorerIcons.folderBadge(for: url) == badge, "Special folder badge: \(name)")
      try expect(ExplorerIcons.folder(size: 64, url: url).tiffRepresentation != ExplorerIcons.folder(size: 64).tiffRepresentation, "Special folder artwork differs from ordinary folder: \(name)")
      try expect(ExplorerIcons.folderBadge(for: home.appendingPathComponent("workplace").appendingPathComponent(name)) == nil, "Ordinary namesake folder stays unbadged: \(name)")
    }
    try expect(ExplorerIcons.folderBadge(for: URL(fileURLWithPath: "/Applications")) == "applications", "System Applications folder has an application badge")
    guard let window = source.view.window, let folder = source.entries.first(where: { $0.isDirectory }), let file = source.entries.first(where: { !$0.isDirectory }) else { throw NativeSmoke.Failure(description: "Parity fixture requires a folder and file") }
    let selection = source.selectedPaths
    defer { source.selectedPaths = selection }
    source.selectedPaths = []
    let empty = source.contextItems()
    try expect(empty.map(\.title) == ["新建", "粘贴", "将项目移到这里", "撤销", "重做", "刷新", "显示隐藏的项目", "打开文件夹…", "在终端中打开"], "Empty-area context menu matches Electron action order")
    source.selectedPaths = [folder.id]
    var menu = source.contextItems()
    try expect(menu.contains { $0.title == "在终端中打开" } && menu.contains { $0.title.contains("快速访问") }, "Folder context includes terminal and Quick Access pinning")
    try expect(!menu.contains { $0.title == "使用文本编辑" || $0.title == "快速查看" }, "Folder context excludes file-only actions")
    source.selectedPaths = [file.id]
    menu = source.contextItems()
    try expect(Array(menu.prefix(3).map(\.title)) == ["打开", "打开方式", "使用文本编辑"], "File context preserves Open and Open With ordering")
    try expect(menu.first { $0.title == "重命名" }?.shortcut == ExplorerShortcuts.display("Enter"), "Context shortcut hints use the effective binding rather than hardcoded F2")
    menu.first { $0.title == "复制文件地址" }?.action?()
    try expect(source.filePasteboard.string(forType: .string) == file.url.path, "Copy file address writes the selected fixture path")
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func views() -> [NSView] {
      func windows(_ parent: NSWindow) -> [NSWindow] { (parent.childWindows ?? []).flatMap { [$0] + windows($0) } }
      return windows(window).compactMap(\.contentView).flatMap(descendants)
    }
    func button(_ title: String) throws -> NSButton {
      guard let value = views().compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeSmoke.Failure(description: "Missing settings button: \(title)") }; return value
    }
    source.executeAction("details-pane")
    let deadline = Date().addingTimeInterval(5)
    while !descendants(source.pane).contains(where: { $0 is NSTextView }), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    let paneText = descendants(source.pane).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
    try expect(paneText.contains("创建日期") && descendants(source.pane).contains { ($0 as? ExplorerButton)?.title == "快速查看" }, "Details pane includes creation date and Quick Look")
    try expect(descendants(source.pane).contains { ($0 as? NSTextView)?.string.contains("Native fixture") == true }, "Details pane restores bounded text preview")
    guard let location = descendants(source.pane).first(where: { $0.identifier?.rawValue == "value-2" }) as? NSTextField else { throw NativeSmoke.Failure(description: "Details location field") }
    try expect(location.lineBreakMode == .byWordWrapping && location.maximumNumberOfLines == 0, "Details location wraps instead of truncating long paths")
    source.executeAction("details-pane")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("native-preview-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Data(repeating: 65, count: 20_000).write(to: temporary)
    let entry = FileEntry(url: temporary, name: temporary.lastPathComponent, isDirectory: false, isSymbolicLink: false, isPackage: false, size: 20_000, modified: nil, isHidden: false)
    let preview = try NativeFilePreview.read(entry)
    try expect(preview.text?.utf8.count == 16_384 && preview.truncated, "Text previews stop at 16 KiB and report truncation")
    try Data([65, 0, 66]).write(to: temporary)
    try expect(try NativeFilePreview.read(entry).text == nil, "Binary files are excluded from text previews")
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent("native-tree-parity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
    defer { source.togglePin(tree); try? FileManager.default.removeItem(at: tree) }
    for index in 0...150 { try FileManager.default.createDirectory(at: tree.appendingPathComponent("dir-\(index)"), withIntermediateDirectories: false) }
    let hiddenFolder = tree.appendingPathComponent(".hidden-folder")
    try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: false)
    var nested = tree
    var levels: [URL] = []
    for _ in 0..<8 { nested.appendPathComponent("deep"); levels.append(nested); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false) }
    source.togglePin(tree)
    func treeRow(_ url: URL) -> ExplorerSidebarRow? { descendants(source.sidebar).compactMap { $0 as? ExplorerSidebarRow }.first { $0.toolTip == url.path } }
    func waitForRow(_ url: URL) async throws {
      let deadline = Date().addingTimeInterval(5)
      while treeRow(url) == nil { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Sidebar omitted \(url.lastPathComponent)") }; try await Task.sleep(nanoseconds: 20_000_000) }
    }
    treeRow(tree)?.onExpand?()
    try await waitForRow(tree.appendingPathComponent("dir-150"))
    try expect(treeRow(tree.appendingPathComponent("dir-150")) != nil, "Sidebar retains folders beyond the old 150-item cutoff")
    for level in levels.dropLast() { try await waitForRow(level); treeRow(level)?.onExpand?() }
    try await waitForRow(levels.last!)
    checks.append("Sidebar can expand beyond six directory levels")
    source.toggleHidden(); try await waitForRow(hiddenFolder)
    try expect(treeRow(hiddenFolder) != nil, "Hidden toggle reloads already expanded sidebar directories")
    source.toggleHidden()
    let originalDirectory = source.directory
    source.navigate(to: URL(string: "explorer://network")!)
    source.search.stringValue = "no-such-network-parity-fixture"
    source.search.sendAction(source.search.action, to: source.search.target)
    try expect(!source.loading, "Submitting network search does not enter filesystem search")
    let networkText = descendants(source.specialView).compactMap { ($0 as? NSTextField)?.stringValue }
    try expect(networkText.contains("没有找到匹配的项目") && networkText.contains("服务器地址") && networkText.contains("附近的共享电脑"), "Network search and section labels match the reference")
    let networkViews = descendants(source.specialView)
    guard let address = networkViews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }), let connect = networkViews.compactMap({ $0 as? EDButton }).first(where: { $0.title == "连接" }) else { throw NativeSmoke.Failure(description: "Network connection controls") }
    try expect(!connect.isEnabled, "Bare smb scheme disables Connect")
    address.stringValue = "smb://fixture.invalid/share"
    source.specialView.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: address))
    try expect(connect.isEnabled, "Entering a server enables Connect without mounting it")
    source.navigate(to: originalDirectory)
    let returnDeadline = Date().addingTimeInterval(10)
    while source.loading, Date() < returnDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
    source.executeAction("settings")
    try await Task.sleep(nanoseconds: 100_000_000)
    defer { try? button("关闭").performClick(nil) }
    try expect(!views().contains { $0 is NativeWakeSettingsView }, "Wake shortcut is absent from General settings")
    try button("键盘快捷键").performClick(nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    guard let wake = views().first(where: { $0 is NativeWakeSettingsView }), let recorder = descendants(wake).compactMap({ $0 as? EDShortcutRecorder }).first, let integration = source.systemIntegration else { throw NativeSmoke.Failure(description: "Wake shortcut appears in Keyboard shortcuts") }
    let original = integration.wakeShortcut
    _ = recorder.onRecord?("Command+Alt+F12")
    let clear = descendants(wake).compactMap { $0 as? NSButton }.first { $0.title == "清除" }!
    clear.performClick(nil)
    try expect(recorder.value.isEmpty && integration.wakeShortcut == original, "Clearing a wake shortcut only edits the draft until Save")
    try button("关于").performClick(nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    let text = views().compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
    try expect(text.contains("尚未检查更新") && text.contains("GPL-3.0-only") && !text.contains("当前版本："), "About restores update status and copyright without duplicate version")
    try expect(text.contains("自动检查更新") && views().compactMap { $0 as? NSButton }.contains { $0.title == "每天" }, "About shows automatic update frequency with daily default")
    for title in ["项目主页", "GitHub 发布页", "问题反馈", "开源许可"] { _ = try button(title) }
    checks.append("All four About project links are present")
    let updates = NativeUpdateView()
    var update = NativeUpdateState(currentVersion: "1.1.0"); update.latestVersion = "1.2.0"; update.status = "available"
    updates.render(update)
    let updateButtons = updates.subviews.compactMap { $0 as? NSButton }
    try expect(updateButtons.contains { $0.title == "检查更新" && !$0.isHidden } && updateButtons.contains { $0.title == "下载更新" && !$0.isHidden }, "Available updates retain both Check and Download actions")
    update.status = "error"; updates.render(update)
    try expect(updateButtons.contains { $0.title == "下载更新" && !$0.isHidden }, "Failed downloads retain the retry action")
    update.status = "downloading"; update.downloaded = 1_048_576; update.total = 2_097_152; updates.render(update)
    try expect(updates.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("1.0 / 2.0 MiB"), "Download progress includes transferred and total bytes")
    return checks
  }
}
