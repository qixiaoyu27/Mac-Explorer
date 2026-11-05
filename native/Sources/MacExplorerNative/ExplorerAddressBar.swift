import AppKit
import ExplorerCore

struct NativeAddressMetadata: Sendable {
  let url: URL
  let isFolder: Bool
}
enum NativeAddressPath {
  static func resolve(_ value: String, current: URL, home: URL) throws -> URL {
    var input = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, !input.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
    if input == "~" || input.hasPrefix("~/") { input = home.path + input.dropFirst() }
    let result: URL
    if input.lowercased().hasPrefix("file:") {
      guard let parsed = URL(string: input), parsed.isFileURL, [nil, "", "localhost"].contains(parsed.host), parsed.user == nil, parsed.password == nil, parsed.port == nil, parsed.query == nil, parsed.fragment == nil else { throw NativeNetwork.failure("文件地址格式不正确。") }; result = parsed
    } else { result = input.hasPrefix("/") ? URL(fileURLWithPath: input) : (current.isFileURL ? current : home).appendingPathComponent(input) }
    return result.standardizedFileURL
  }
  static func metadata(_ url: URL) throws -> NativeAddressMetadata {
    let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    return NativeAddressMetadata(url: url, isFolder: values.isDirectory == true && values.isPackage != true)
  }
  static func prefix(_ input: String) -> (parent: String, name: String)? {
    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("smb:"), !input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("file:"), let slash = input.lastIndex(of: "/") else { return nil }
    return (String(input[...slash]), String(input[input.index(after: slash)...]))
  }
  static func suggestions(_ entries: [FileEntry], prefix: String, name: String) -> [String] {
    Array(entries.filter { $0.isDirectory && !$0.name.hasSuffix(".app") && $0.name.lowercased().hasPrefix(name.lowercased()) }.prefix(5)).map { prefix + $0.name }
  }
}

final class ExplorerAddressBar: NSView, NSTextFieldDelegate {
  let field = ExplorerTextField()
  private let crumbs = NSView()
  private var url = FileManager.default.homeDirectoryForCurrentUser
  private(set) var editing = false
  var onNavigate: ((URL) -> Void)?
  var onSubmit: ((String) -> Void)?
  var onCopyAddress: ((String) -> Void)?
  var onFileDragValidate: ((NSDraggingInfo, URL) -> NSDragOperation)?
  var onFileDrop: ((NSDraggingInfo, URL) -> Bool)?
  var onError: ((Error) -> Void)?
  var labelForPath: ((URL) -> String)?
  var showHidden = false
  var virtualTitle: String?
  var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
  var recentPaths: [String] = []
  private var suggestions: [String] = []
  private var selectedSuggestion = -1
  private var suggestionPanel: NSPanel?
  private var suggestionRows: [ExplorerButton] = []
  private var request = 0, crumbRequest = 0
  private var pointerMonitor: Any?
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 35) }
  override init(frame: NSRect) {
    super.init(frame: frame)
    field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
    field.font = ExplorerTypography.font(); field.textColor = ExplorerPalette.text
    field.target = self; field.action = #selector(submit); field.delegate = self
    field.setAccessibilityLabel(NL("文件夹地址"))
    crumbs.wantsLayer = true; crumbs.layer?.masksToBounds = true
    addSubview(crumbs); addSubview(field); field.isHidden = true
    pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in self?.crumbRequest += 1; return event }
  }
  required init?(coder: NSCoder) { fatalError() }
  func setDirectory(_ directory: URL, title: String? = nil) {
    crumbRequest += 1; url = directory; virtualTitle = title
    if !editing { field.stringValue = url.path; rebuild() }
  }
  func beginEditing() {
    crumbRequest += 1; editing = true; crumbs.isHidden = true; field.isHidden = false; field.stringValue = url.isFileURL ? url.path : homeDirectory.path
    field.selectText(nil); needsDisplay = true
    showSuggestions(recentPaths, history: true)
  }
  override func mouseDown(with event: NSEvent) { beginEditing() }
  override func rightMouseDown(with event: NSEvent) { if !editing, url.isFileURL { addressMenu(url, event: event) } else { super.rightMouseDown(with: event) } }
  func controlTextDidEndEditing(_ obj: Notification) { finishEditing() }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(); window?.makeFirstResponder(superview); return true }
    if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
      guard !suggestions.isEmpty else { return false }
      let down = commandSelector == #selector(NSResponder.moveDown(_:))
      selectedSuggestion = down ? (selectedSuggestion + 1) % suggestions.count : selectedSuggestion <= 0 ? suggestions.count - 1 : selectedSuggestion - 1
      field.stringValue = suggestions[selectedSuggestion]; textView.string = field.stringValue; textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
      for (index, row) in suggestionRows.enumerated() { row.active = index == selectedSuggestion; row.setAccessibilityValue(index == selectedSuggestion ? 1 : 0) }
      suggestionRows[selectedSuggestion].scrollToVisible(suggestionRows[selectedSuggestion].bounds)
      return true
    }
    return false
  }
  @objc private func submit() { let value = field.stringValue; onSubmit?(value); finishEditing() }
  private func finishEditing() { request += 1; crumbRequest += 1; closeSuggestions(); editing = false; field.isHidden = true; crumbs.isHidden = false; rebuild(); needsDisplay = true }
  func controlTextDidChange(_ obj: Notification) { updateSuggestions() }
  private func updateSuggestions() {
    request += 1; let token = request, input = field.stringValue
    guard let prefix = NativeAddressPath.prefix(input), let directory = try? NativeAddressPath.resolve(prefix.parent, current: url, home: homeDirectory) else { showSuggestions([]); return }
    let hidden = showHidden
    Task { @MainActor [weak self] in
      let entries = try? await Task.detached { EntryQuery.apply(try DirectoryReader.read(directory).entries, showHidden: hidden, query: "", sort: .name, ascending: true) }.value
      guard let self, self.editing, self.request == token else { return }
      self.showSuggestions(NativeAddressPath.suggestions(entries ?? [], prefix: prefix.parent, name: prefix.name))
    }
  }
  private func closeSuggestions() {
    if let suggestionPanel { window?.removeChildWindow(suggestionPanel); suggestionPanel.orderOut(nil) }
    suggestionPanel = nil; suggestionRows = []; suggestions = []; selectedSuggestion = -1
  }
  private func showSuggestions(_ values: [String], history: Bool = false) {
    closeSuggestions()
    guard editing, let window, !values.isEmpty else { return }
    suggestions = Array(values.prefix(25)); let fullHeight = CGFloat(suggestions.count * 32 + 10), height = min(fullHeight, 266)
    let anchor = window.convertToScreen(convert(bounds, to: nil))
    let panel = NSPanel(contentRect: NSRect(x: anchor.minX, y: anchor.minY - height - 3, width: bounds.width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.level = .popUpMenu
    let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: fullHeight)); surface.color = ExplorerPalette.toolbar
    surface.setAccessibilityRole(.list); surface.setAccessibilityLabel(history ? NL("最近输入的地址") : NL("匹配的文件夹"))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: height)); scroll.documentView = surface; scroll.hasVerticalScroller = fullHeight > height; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false; panel.contentView = scroll
    for (index, value) in suggestions.enumerated() {
      let row = ExplorerButton(title: value) { [weak self] in self?.onSubmit?(value); self?.finishEditing() }
      row.alignment = .left; row.toolTip = value
      row.frame = NSRect(x: 5, y: 5 + CGFloat(index) * 32, width: bounds.width - 18, height: 32); surface.addSubview(row); suggestionRows.append(row)
    }
    suggestionPanel = panel; window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
  }
  override func layout() {
    super.layout(); field.frame = NSRect(x: 42, y: (bounds.height - ExplorerTypography.lineHeight) / 2, width: max(0, bounds.width - 50), height: ExplorerTypography.lineHeight)
    crumbs.frame = NSRect(x: 38, y: 0, width: max(0, bounds.width - 42), height: bounds.height); rebuild()
  }
  private func pathLabel(_ directory: URL) -> String {
    if let labelForPath { return labelForPath(directory) }
    if directory.path == "/" { return "Macintosh HD" }; if directory.path == homeDirectory.path { return NL("个人文件夹") }
    if directory.deletingLastPathComponent().path == homeDirectory.path || directory.path == "/Applications" {
      return ["Desktop": NL("桌面"), "Downloads": NL("下载"), "Documents": NL("文档"), "Pictures": NL("图片"), "Applications": NL("应用程序"), "Music": NL("音乐"), "Movies": NL("视频")][directory.lastPathComponent] ?? directory.lastPathComponent
    }
    return directory.lastPathComponent
  }
  private func rebuild() {
    crumbs.subviews.forEach { $0.removeFromSuperview() }
    if let virtualTitle {
      let item = ExplorerButton(title: virtualTitle) { [weak self] in self?.beginEditing() }; item.frame = NSRect(x: 0, y: 0, width: max(100, item.intrinsicContentSize.width), height: crumbs.bounds.height); crumbs.addSubview(item); return
    }
    var urls = [URL(fileURLWithPath: "/")]
    for part in url.pathComponents.dropFirst() { urls.append(urls.last!.appendingPathComponent(part)) }
    let root = ExplorerButton(icon: "chevronRight")
    root.onPress = { [weak self, weak root] in self?.showFolders(nil, anchor: root) }; root.setAccessibilityLabel(NL("{0} 的子文件夹", NL("此电脑")))
    root.iconDimension = 13; root.frame = NSRect(x: 0, y: 0, width: 18, height: crumbs.bounds.height); crumbs.addSubview(root)
    var x: CGFloat = 18
    for target in urls {
      let name = pathLabel(target)
      let item = ExplorerButton(title: name) { [weak self] in guard let self else { return }; if target == self.url { self.beginEditing() } else { self.onNavigate?(target) } }
      item.onContextMenu = { [weak self] in self?.addressMenu(target, event: $0) }; item.toolTip = target == url ? NL("单击编辑路径") : target.path
      item.onFileDragValidate = { [weak self] info in self?.onFileDragValidate?(info, target) ?? [] }
      item.onFileDrop = { [weak self] info in self?.onFileDrop?(info, target) ?? false }
      let width = (name as NSString).size(withAttributes: [.font: ExplorerTypography.font()]).width + 16
      item.horizontalPadding = 8; item.frame = NSRect(x: x, y: 0, width: width, height: crumbs.bounds.height); crumbs.addSubview(item); x += width
      let arrow = ExplorerButton(icon: "chevronRight"); arrow.iconDimension = 13; arrow.setAccessibilityLabel(NL("{0} 的子文件夹", name)); arrow.frame = NSRect(x: x, y: 0, width: 18, height: 27)
      arrow.onPress = { [weak self, weak arrow] in self?.showFolders(target, anchor: arrow) }; crumbs.addSubview(arrow); x += 18
    }
  }
  private func addressMenu(_ directory: URL, event: NSEvent) {
    guard let window else { return }; crumbRequest += 1
    ExplorerMenu.show([ExplorerMenuItem(title: NL("复制地址"), icon: "copy", action: { [weak self] in self?.onCopyAddress?(directory.path) })], at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
  }
  private func showFolders(_ directory: URL?, anchor: NSView?) {
    guard let anchor else { return }; crumbRequest += 1; let token = crumbRequest, hidden = showHidden
    Task { @MainActor [weak self, weak anchor] in
      do {
        let folders = try await Task.detached { () -> [(String, URL)] in
          if let directory { return EntryQuery.apply(try DirectoryReader.read(directory).entries, showHidden: hidden, query: "", sort: .name, ascending: true).filter { $0.isDirectory && !$0.name.hasSuffix(".app") }.map { ($0.name, $0.url) } }
          return try NativeVolumes.list().map { ($0.name, $0.url) }
        }.value
        guard let self, self.crumbRequest == token, let anchor, anchor.window != nil else { return }
        let items = folders.map { name, url in ExplorerMenuItem(title: name, icon: "folder", action: { [weak self] in self?.onNavigate?(url) }) }
        ExplorerMenu.present(items.isEmpty ? [ExplorerMenuItem(title: NL("没有子文件夹"), enabled: false)] : items, below: anchor)
      } catch { guard let self, self.crumbRequest == token else { return }; self.onError?(error) }
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    (editing ? ExplorerPalette.surface : ExplorerPalette.input).setFill(); path.fill(); ExplorerPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
    let places = ["Documents": "document", "Desktop": "desktop", "Downloads": "download", "Pictures": "image", "Applications": "applications", "Music": "music", "Movies": "video"]
    let name = url.scheme == "explorer" ? (url.host == "computer" ? "computer" : url.host ?? "folder") : url.deletingLastPathComponent().path == homeDirectory.path || url.path == "/Applications" ? places[url.lastPathComponent] ?? "folder" : "folder"
    ExplorerIcons.image(name, size: 17, color: ExplorerPalette.place(name)).draw(in: NSRect(x: 13, y: 9, width: 17, height: 17), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    if editing { ExplorerPalette.accent.setFill(); NSRect(x: 2, y: bounds.height - 2, width: bounds.width - 4, height: 2).fill() }
  }
  deinit { if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; suggestionPanel?.orderOut(nil) }
}
final class ExplorerSearchBox: NSView {
  let field = ExplorerTextField()
  private let icon = ExplorerButton(icon: "search")
  private let filters = ExplorerButton(icon: "sort")
  var onSearch: (() -> Void)?
  var onClear: (() -> Void)?
  var onFilters: (() -> Void)?
  var filtersActive = false { didSet { filters.active = filtersActive; filters.toolTip = filtersActive ? NL("已启用筛选") : NL("筛选") } }
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 245, height: 35) }
  override init(frame: NSRect) {
    super.init(frame: frame)
    field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
    field.font = ExplorerTypography.font(); field.textColor = ExplorerPalette.text
    field.target = self; field.action = #selector(submit)
    field.setAccessibilityLabel(NL("搜索文件"))
    filters.setAccessibilityLabel(NL("筛选")); filters.toolTip = NL("筛选")
    addSubview(field); addSubview(icon); addSubview(filters)
    icon.onPress = { [weak self] in
      guard let self else { return }
      if self.field.stringValue.isEmpty { self.onSearch?() } else { self.field.stringValue = ""; self.onClear?(); self.update() }
    }
    filters.onPress = { [weak self] in self?.onFilters?() }
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func submit() { onSearch?(); update() }
  func update() { icon.iconName = field.stringValue.isEmpty ? "search" : "close"; needsDisplay = true }
  override func layout() { super.layout(); field.frame = NSRect(x: 10, y: (bounds.height - ExplorerTypography.lineHeight) / 2, width: max(0, bounds.width - 68), height: ExplorerTypography.lineHeight); filters.frame = NSRect(x: bounds.width - 58, y: 5, width: 25, height: 25); icon.frame = NSRect(x: bounds.width - 31, y: 5, width: 25, height: 25) }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    ExplorerPalette.input.setFill(); path.fill(); ExplorerPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
    if field.currentEditor() != nil { ExplorerPalette.accent.setFill(); NSRect(x: 2, y: bounds.height - 2, width: bounds.width - 4, height: 2).fill() }
  }
}
