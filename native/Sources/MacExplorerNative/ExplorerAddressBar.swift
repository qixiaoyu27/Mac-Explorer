import AppKit
import ExplorerCore

struct AddressNavigationState: Equatable {
  let location: URL
  var title: String? = nil
  var tab: UUID? = nil
}

final class AddressBand: NSView {
  private let control = AddressBarControl()
  var breadcrumbBar: BreadcrumbBar { control.PART_BreadcrumbBar }
  var editBox: AddressEditBox { control.PART_AutoSuggestBox }
  private var pointerMonitor: Any?
  private(set) var navigation = AddressNavigationState(location: FileManager.default.homeDirectoryForCurrentUser)
  private(set) var editing = false
  var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
  var showHidden = false
  var recentPaths: [String] = []
  var onHistoryChanged: (([String]) -> Void)?
  var onAddressDestination: ((AddressDestination) throws -> Void)?
  var onCopyAddress: ((URL, Bool) -> Void)?
  var onFileDragValidate: ((NSDraggingInfo, URL) -> NSDragOperation)?
  var onFileDrop: ((NSDraggingInfo, URL) -> Bool)?
  var onError: ((Error) -> Void)?
  var labelForPath: ((URL) -> String)?

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 35) }
  override init(frame: NSRect) {
    super.init(frame: frame)
    breadcrumbBar.SetOwner(self)
    editBox.SetOwner(self)
    control.SetOwner(self)
    addSubview(control)
    breadcrumbBar.SetNavigationState(navigation)
    pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      self.breadcrumbBar.CancelDropDownRequest()
      return event
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  func SetNavigationState(_ state: AddressNavigationState) {
    if state != navigation {
      navigation = state
      editBox._CancelPreviousParse()
      SetEditMode(false)
      Refresh()
    }
    breadcrumbBar.SetNavigationState(state)
    control.needsDisplay = true
  }

  func Refresh() { editBox.Refresh() }

  func GetText() -> (text: String, dirty: Bool) { editBox.GetText() }

  func SetEditMode(_ edit: Bool) {
    guard editing != edit else { return }
    editing = edit
    breadcrumbBar.CancelDropDownRequest()
    if edit {
      ExplorerMenu.dismiss()
      Refresh()
    } else {
      editBox.RevertEditChanges()
      if editBox.field.currentEditor() != nil { window?.makeFirstResponder(nil) }
    }
    control.SetEditMode(edit)
  }

  func _SetFocusAndEditMode() {
    SetEditMode(true)
    layoutSubtreeIfNeeded()
    control.FocusEditor()
  }

  func ShowAddressHistory() {
    if !editing || editBox.field.currentEditor() == nil { _SetFocusAndEditMode() }
    editBox.ToggleDropDown()
  }

  func RevertEditChanges() {
    breadcrumbBar.CancelDropDownRequest()
    editBox._CancelPreviousParse()
    SetEditMode(false)
  }

  func NavigateToPidl(_ location: URL) {
    editBox._CancelPreviousParse()
    do { try onAddressDestination?(.location(location)) }
    catch { onError?(error) }
  }

  func rememberAddress(_ path: String) {
    recentPaths = Array(([path] + recentPaths.filter { $0 != path }).prefix(25))
    onHistoryChanged?(recentPaths)
  }

  func DeleteHistory() {
    recentPaths.removeAll()
    onHistoryChanged?(recentPaths)
  }

  func virtualLocation(for input: String) -> URL? {
    let locations = ["computer": NL("此电脑"), "network": NL("网络"), "airdrop": NL("隔空投送"), "trash": NL("回收站")]
    return locations.first(where: {
      input.caseInsensitiveCompare($0.value) == .orderedSame || input.lowercased() == "explorer://\($0.key)"
    }).flatMap { URL(string: "explorer://\($0.key)") }
  }

  override func layout() {
    super.layout()
    control.frame = bounds
  }

  deinit { if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) } }
}

final class AddressBarControl: NSView {
  let PART_BreadcrumbBar = BreadcrumbBar()
  let PART_AutoSuggestBox = AddressEditBox()
  private weak var owner: AddressBand?

  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    addSubview(PART_BreadcrumbBar)
    addSubview(PART_AutoSuggestBox)
    SetEditMode(false)
  }
  required init?(coder: NSCoder) { fatalError() }

  func SetOwner(_ owner: AddressBand) { self.owner = owner }

  func SetEditMode(_ editing: Bool) {
    PART_BreadcrumbBar.isHidden = editing
    PART_AutoSuggestBox.isHidden = !editing
    needsLayout = true
    needsDisplay = true
  }

  func FocusEditor() {
    let field = PART_AutoSuggestBox.field
    if let editor = field.currentEditor() as? NSTextView {
      editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    } else {
      field.selectText(nil)
    }
  }

  override func layout() {
    super.layout()
    let trailingInset: CGFloat = 24 + 4
    PART_BreadcrumbBar.frame = NSRect(x: 2, y: 0, width: max(0, bounds.width - 2 - trailingInset), height: bounds.height)
    PART_AutoSuggestBox.frame = NSRect(x: 11, y: 0, width: max(0, bounds.width - 22), height: bounds.height)
    PART_AutoSuggestBox.CloseDropDownOnResize(to: bounds.width)
  }

  override func mouseDown(with event: NSEvent) { owner?._SetFocusAndEditMode() }
  override func rightMouseDown(with event: NSEvent) {
    if owner?.editing == true { super.rightMouseDown(with: event) }
    else { PART_BreadcrumbBar._OnContextMenu(event) }
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
    let editing = owner?.editing == true
    (editing ? ExplorerPalette.surface : ExplorerPalette.input).setFill()
    path.fill()
    ExplorerPalette.border.setStroke()
    path.lineWidth = 1
    path.stroke()
    if editing {
      ExplorerPalette.accent.setFill()
      NSRect(x: 2, y: bounds.height - 2, width: bounds.width - 4, height: 2).fill()
    }
  }
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
