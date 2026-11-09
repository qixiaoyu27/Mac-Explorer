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

enum AddressDestination: Sendable {
  case location(URL)
  case item(URL)
  case mountedShare(URL, address: String)
}

final class AddressEditBox: NSView, NSTextFieldDelegate {
  let field = ExplorerTextField()
  private weak var owner: AddressBand?
  private var original = ""
  private var suggestions: [String] = []
  private var selectedSuggestion = -1
  private var popup: NSPanel?
  private var popupDraft = ""
  private var rows: [ExplorerButton] = []
  private var completion: Task<Void, Never>?
  private var parse: Task<Void, Never>?

  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = ExplorerTypography.font()
    field.textColor = ExplorerPalette.text
    field.delegate = self
    field.target = self
    field.action = #selector(submit)
    field.setAccessibilityLabel(NL("文件夹地址"))
    addSubview(field)
  }
  required init?(coder: NSCoder) { fatalError() }

  func SetOwner(_ owner: AddressBand) { self.owner = owner }

  func Refresh() {
    guard let owner else { return }
    original = owner.navigation.location.isFileURL ? owner.navigation.location.path : owner.navigation.title ?? owner.homeDirectory.path
    RevertEditChanges()
  }

  func GetText() -> (text: String, dirty: Bool) {
    let text = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    return (text, text != original)
  }

  func RevertEditChanges() {
    _CloseDropDown()
    field.stringValue = original
    if let editor = field.currentEditor() as? NSTextView { editor.string = original }
  }

  func _CancelPreviousParse() {
    parse?.cancel()
    parse = nil
  }

  func _HandleUserAction(_ value: String) {
    _CloseDropDown()
    var input = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.count >= 2, input.first == "\"", input.last == "\"" { input = String(input.dropFirst().dropLast()) }
    guard !input.isEmpty, !input.contains("\0") else { return }
    _CancelPreviousParse()
    _StartParse(input)
  }

  private func _StartParse(_ input: String) {
    guard let owner else { return }
    let current = owner.navigation.location, home = owner.homeDirectory
    let virtual = owner.virtualLocation(for: input)
    parse = Task { [weak self] in
      do {
        let destination: AddressDestination
        if let virtual {
          destination = .location(virtual)
        } else if input.lowercased().hasPrefix("smb:") {
          guard let mounted = try await NativeNetwork.shared.connection(input), !Task.isCancelled else { return }
          destination = .mountedShare(mounted, address: input)
        } else {
          destination = try await Task.detached {
            let target = try NativeAddressPath.metadata(NativeAddressPath.resolve(input, current: current, home: home))
            return target.isFolder ? .location(target.url) : .item(target.url)
          }.value
        }
        guard !Task.isCancelled else { return }
        try self?._FinishNavigate(destination)
      } catch {
        guard !Task.isCancelled else { return }
        self?.owner?.onError?(error)
      }
    }
  }

  private func _FinishNavigate(_ destination: AddressDestination) throws {
    try owner?.onAddressDestination?(destination)
    owner?.SetEditMode(false)
    if case .location(let url) = destination, url.isFileURL { owner?.rememberAddress(url.path) }
    if case .item(let url) = destination { owner?.rememberAddress(url.path) }
  }

  func ToggleDropDown() {
    if popup != nil { _CloseDropDown() }
    else { _ShowDropDown(owner?.recentPaths ?? [], history: true) }
  }

  func _CloseDropDown() {
    completion?.cancel()
    completion = nil
    if let popup {
      popup.parent?.removeChildWindow(popup)
      popup.orderOut(nil)
    }
    popup = nil
    rows.removeAll()
    suggestions.removeAll()
    selectedSuggestion = -1
  }

  func CloseDropDownOnResize(to width: CGFloat) {
    if let popup, popup.frame.width != width { _CloseDropDown() }
  }

  @objc private func submit() { _HandleUserAction(owner?.GetText().text ?? GetText().text) }

  func controlTextDidEndEditing(_ notification: Notification) {
    owner?.SetEditMode(false)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      if popup != nil {
        if selectedSuggestion >= 0 { textView.string = popupDraft }
        _CloseDropDown()
      } else {
        owner?.RevertEditChanges()
        owner?.breadcrumbBar.FocusFirstCrumb()
      }
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      submit()
      return true
    }
    let down = commandSelector == #selector(NSResponder.moveDown(_:))
    guard down || commandSelector == #selector(NSResponder.moveUp(_:)) else { return false }
    if popup == nil {
      guard down, owner?.recentPaths.isEmpty == false else { return false }
      ToggleDropDown()
    }
    guard !suggestions.isEmpty else { return false }
    if down { selectedSuggestion = (selectedSuggestion + 1) % suggestions.count }
    else { selectedSuggestion = selectedSuggestion <= 0 ? suggestions.count - 1 : selectedSuggestion - 1 }
    textView.string = suggestions[selectedSuggestion]
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    for (index, row) in rows.enumerated() {
      row.active = index == selectedSuggestion
      row.setAccessibilityValue(index == selectedSuggestion ? 1 : 0)
    }
    rows[selectedSuggestion].scrollToVisible(rows[selectedSuggestion].bounds)
    return true
  }

  func controlTextDidChange(_ notification: Notification) {
    _CloseDropDown()
    guard let owner else { return }
    let input = GetText().text, hidden = owner.showHidden
    guard let prefix = NativeAddressPath.prefix(input),
          let directory = try? NativeAddressPath.resolve(prefix.parent, current: owner.navigation.location, home: owner.homeDirectory) else { return }
    completion = Task { [weak self] in
      let entries = try? await Task.detached {
        EntryQuery.apply(try DirectoryReader.read(directory).entries, showHidden: hidden, query: "", sort: .name, ascending: true)
      }.value
      guard !Task.isCancelled, self?.owner?.editing == true else { return }
      self?._ShowDropDown(NativeAddressPath.suggestions(entries ?? [], prefix: prefix.parent, name: prefix.name), history: false)
    }
  }

  private func _ShowDropDown(_ values: [String], history: Bool) {
    _CloseDropDown()
    guard let owner, owner.editing, let window, !values.isEmpty else { return }
    popupDraft = GetText().text
    suggestions = Array(values.prefix(25))
    let fullHeight = CGFloat(suggestions.count * 32 + 10), height = min(fullHeight, 266)
    let anchor = window.convertToScreen(owner.convert(owner.bounds, to: nil))
    let screen = window.screen?.visibleFrame ?? window.frame
    let y = anchor.minY - height - 3 >= screen.minY ? anchor.minY - height - 3 : min(anchor.maxY + 3, screen.maxY - height)
    let width = owner.bounds.width
    let panel = NSPanel(contentRect: NSRect(x: anchor.minX, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.level = .popUpMenu
    let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: width, height: fullHeight))
    surface.color = ExplorerPalette.toolbar
    surface.setAccessibilityRole(.list)
    surface.setAccessibilityLabel(history ? NL("最近输入的地址") : NL("匹配的文件夹"))
    let scroll = ExplorerScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    scroll.documentView = surface
    scroll.hasVerticalScroller = fullHeight > height
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    panel.contentView = scroll
    surface.frame.size.width = scroll.contentSize.width
    for (index, value) in suggestions.enumerated() {
      let row = ExplorerButton(title: value) { [weak self] in self?._HandleUserAction(value) }
      row.alignment = .left
      row.refusesFirstResponder = true
      row.toolTip = value
      row.frame = NSRect(x: 5, y: 5 + CGFloat(index) * 32, width: surface.bounds.width - 18, height: 32)
      surface.addSubview(row)
      rows.append(row)
    }
    popup = panel
    window.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
  }

  override func layout() {
    super.layout()
    let height = ExplorerTypography.lineHeight
    field.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
  }

  deinit {
    completion?.cancel()
    parse?.cancel()
    popup?.orderOut(nil)
  }
}
