import AppKit
import ExplorerCore

struct BreadcrumbBarItemVM: Equatable {
  let Folder: URL
  let title: String
}

final class FirstCrumbStackPanelControl: NSView {
  let icon = ExplorerButton(icon: "computer")
  let chevron = ExplorerButton(icon: "chevronRight")

  override init(frame: NSRect) {
    super.init(frame: frame)
    icon.iconDimension = 17
    chevron.iconDimension = 13
    addSubview(icon)
    addSubview(chevron)
    setAccessibilityRole(NSAccessibility.Role(rawValue: "AXSplitButton"))
    setAccessibilityElement(true)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 0, y: 0, width: 27, height: bounds.height)
    chevron.frame = NSRect(x: 27, y: 0, width: 18, height: bounds.height)
  }

  override func accessibilityPerformPress() -> Bool {
    icon.performClick(nil)
    return true
  }
}

final class BreadcrumbBarItemControl: NSView {
  let name: ExplorerButton
  let arrow = ExplorerButton(icon: "chevronRight")

  init(title: String, icon: String? = nil) {
    name = ExplorerButton(title: title, icon: icon)
    super.init(frame: .zero)
    name.alignment = title.isEmpty ? .center : .left
    arrow.iconDimension = 13
    arrow.isHidden = true
    addSubview(name)
    addSubview(arrow)
    setAccessibilityRole(NSAccessibility.Role(rawValue: "AXSplitButton"))
    setAccessibilityElement(true)
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let arrowWidth: CGFloat = arrow.isHidden ? 0 : 18
    name.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - arrowWidth), height: bounds.height)
    arrow.frame = NSRect(x: bounds.width - arrowWidth, y: 0, width: arrowWidth, height: bounds.height)
  }

  override func accessibilityPerformPress() -> Bool {
    name.performClick(nil)
    return true
  }
}

final class BreadcrumbBar: NSView {
  private weak var owner: AddressBand?
  private let firstCrumb = FirstCrumbStackPanelControl()
  private let overflow = BreadcrumbBarItemControl(title: "", icon: "more")
  private var items: [BreadcrumbBarItemVM] = []
  private var buttons: [BreadcrumbBarItemControl] = []
  private var currentContainsSubFolders = true
  private var hiddenCount = 0
  private var dropDown: Task<Void, Never>?

  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    firstCrumb.icon.onPress = { [weak self] in self?._OnDropDown(nil, anchor: self?.firstCrumb) }
    firstCrumb.chevron.onPress = firstCrumb.icon.onPress
    overflow.name.onPress = { [weak self] in self?._OnDropDown(nil, anchor: self?.overflow) }
    for button in [firstCrumb.icon, firstCrumb.chevron, overflow.name] {
      button.onContextMenu = { [weak self] in self?._OnContextMenu($0) }
    }
    addSubview(firstCrumb)
    addSubview(overflow)
    overflow.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }

  func SetOwner(_ owner: AddressBand) { self.owner = owner }

  func SetNavigationState(_ state: AddressNavigationState) {
    let location = state.location
    let icon = location.isFileURL ? "computer" : location.host ?? "computer"
    if firstCrumb.icon.iconName != icon { firstCrumb.icon.iconName = icon }
    firstCrumb.icon.iconColor = ExplorerPalette.place(icon)
    firstCrumb.setAccessibilityLabel(NL("此电脑"))
    firstCrumb.chevron.setAccessibilityLabel(NL("{0} 的子文件夹", NL("此电脑")))
    overflow.setAccessibilityLabel(NL("隐藏的上级文件夹"))
    let path: [BreadcrumbBarItemVM]
    if location.isFileURL {
      var urls = [URL(fileURLWithPath: "/", isDirectory: true)]
      for part in location.pathComponents.dropFirst() {
        urls.append(urls[urls.count - 1].appendingPathComponent(part, isDirectory: true))
      }
      path = urls.map { BreadcrumbBarItemVM(Folder: $0, title: owner?.labelForPath?($0) ?? ($0.path == "/" ? "Macintosh HD" : $0.lastPathComponent)) }
    } else {
      path = [BreadcrumbBarItemVM(Folder: location, title: state.title ?? location.absoluteString)]
    }
    guard path != items else { return }
    CancelDropDownRequest()
    currentContainsSubFolders = items.last?.Folder == path.last?.Folder ? currentContainsSubFolders : true
    items = path
    _RebuildToolbar()
  }

  func SetCurrentFolderContainsSubFolders(_ value: Bool) {
    guard value != currentContainsSubFolders else { return }
    currentContainsSubFolders = value
    needsLayout = true
  }

  func FocusFirstCrumb() { window?.makeFirstResponder(firstCrumb.icon) }

  private func _RebuildToolbar() {
    for button in buttons { button.removeFromSuperview() }
    buttons = items.enumerated().map { index, item in
      let button = BreadcrumbBarItemControl(title: item.title)
      button.name.onPress = { [weak self] in self?._OnButtonPressNavigate(index) }
      button.name.toolTip = item.title
      button.name.onContextMenu = { [weak self] in self?._OnContextMenu($0) }
      button.arrow.setAccessibilityLabel(NL("{0} 的子文件夹", item.title))
      button.arrow.onPress = { [weak self, weak button] in self?._OnDropDown(item.Folder, anchor: button?.arrow) }
      button.arrow.onContextMenu = button.name.onContextMenu
      if item.Folder.isFileURL {
        button.name.onFileDragValidate = { [weak self] info in self?.owner?.onFileDragValidate?(info, item.Folder) ?? [] }
        button.name.onFileDrop = { [weak self] info in self?.owner?.onFileDrop?(info, item.Folder) ?? false }
      }
      addSubview(button)
      return button
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    _ShowHideTBButtons()
  }

  private func _ShowHideTBButtons() {
    let rootWidth: CGFloat = 47, overflowWidth: CGFloat = 25, arrowWidth: CGFloat = 18
    let available = max(0, bounds.width - rootWidth)
    let dropdowns = items.enumerated().map { index, item in
      item.Folder.isFileURL && (index < items.count - 1 || currentContainsSubFolders)
    }
    let desired = buttons.enumerated().map { index, button in
      button.name.intrinsicContentSize.width + (dropdowns[index] ? arrowWidth : 0)
    }
    var widths = desired
    hiddenCount = 0
    if desired.reduce(0, +) > available, let last = desired.indices.last {
      var remaining = max(0, available - (last > 0 ? overflowWidth : 0))
      widths[last] = min(desired[last], remaining)
      remaining -= widths[last]
      for index in desired.indices.dropLast().reversed() {
        if desired[index] > remaining {
          hiddenCount = index + 1
          break
        }
        remaining -= desired[index]
      }
    }

    let height = bounds.height - 4
    firstCrumb.frame = NSRect(x: 2, y: 2, width: rootWidth - 2, height: height)
    overflow.isHidden = hiddenCount == 0
    overflow.frame = NSRect(x: rootWidth, y: 2, width: overflowWidth, height: height)
    var x = rootWidth + (overflow.isHidden ? 0 : overflowWidth)
    for (index, button) in buttons.enumerated() {
      button.isHidden = index < hiddenCount
      guard !button.isHidden else { continue }
      button.arrow.isHidden = !dropdowns[index] || widths[index] < arrowWidth + 20
      button.frame = NSRect(x: x, y: 2, width: widths[index], height: height)
      button.needsLayout = true
      x += widths[index]
    }
  }

  private func _OnButtonPressNavigate(_ index: Int) {
    if index == items.count - 1 { _GoToEditMode() }
    else { owner?.NavigateToPidl(items[index].Folder) }
  }

  private func _GoToEditMode() { owner?._SetFocusAndEditMode() }

  override func mouseDown(with event: NSEvent) { _GoToEditMode() }
  override func rightMouseDown(with event: NSEvent) { _OnContextMenu(event) }

  func _OnContextMenu(_ event: NSEvent) {
    guard let window else { return }
    CancelDropDownRequest()
    ExplorerMenu.show([
      ExplorerMenuItem(title: NL("复制地址"), icon: "copy", action: { [weak self] in self?._CopyToClipboard(asItem: true) }),
      ExplorerMenuItem(title: NL("将地址复制为文本"), action: { [weak self] in self?._CopyToClipboard(asItem: false) }),
      ExplorerMenuItem(title: NL("编辑地址"), action: { [weak self] in self?._GoToEditMode() }),
      ExplorerMenuItem(title: NL("删除历史记录"), enabled: owner?.recentPaths.isEmpty == false, divider: true, action: { [weak self] in self?.owner?.DeleteHistory() }),
    ], at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
  }

  private func _CopyToClipboard(asItem: Bool) {
    guard let owner else { return }
    owner.onCopyAddress?(owner.navigation.location, asItem)
  }

  func CancelDropDownRequest() {
    dropDown?.cancel()
    dropDown = nil
  }

  private func _OnDropDown(_ directory: URL?, anchor: NSView?) {
    guard let anchor, let owner else { return }
    CancelDropDownRequest()
    let hidden = owner.showHidden
    dropDown = Task { [weak self, weak anchor] in
      do {
        let folders = try await Task.detached { () -> [(String, URL)] in
          if let directory {
            return EntryQuery.apply(try DirectoryReader.read(directory).entries, showHidden: hidden, query: "", sort: .name, ascending: true)
              .filter { $0.isDirectory && !$0.isPackage }.map { ($0.name, $0.url) }
          }
          return (try? NativeVolumes.list())?.map { ($0.name, $0.url) } ?? []
        }.value
        guard !Task.isCancelled, let self, let anchor, anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
        let next = directory.flatMap { path in self.items.first { $0.Folder.deletingLastPathComponent().path == path.path && $0.Folder.path != path.path }?.Folder.path }
        var items: [ExplorerMenuItem]
        if directory == nil { items = self._AddRootDropdownItems(folders) }
        else {
          items = folders.map { name, url in
            self.menuItem(name: self.owner?.labelForPath?(url) ?? name, url: url, icon: "folder", checked: url.path == next)
          }
        }
        if items.isEmpty { items = [ExplorerMenuItem(title: NL("没有子文件夹"), enabled: false)] }
        ExplorerMenu.present(items, below: anchor)
      } catch {
        guard !Task.isCancelled else { return }
        self?.owner?.onError?(error)
      }
    }
  }

  private func _AddRootDropdownItems(_ volumes: [(String, URL)]) -> [ExplorerMenuItem] {
    var locations = Set<String>()
    var items: [ExplorerMenuItem] = []
    for crumb in self.items.prefix(hiddenCount).reversed() {
      locations.insert(crumb.Folder.path)
      items.append(menuItem(name: crumb.title, url: crumb.Folder, icon: crumb.Folder.path == "/" ? "drive" : "folder"))
    }
    items.append(menuItem(name: NL("此电脑"), url: URL(string: "explorer://computer")!, icon: "computer"))
    for (name, url) in volumes where locations.insert(url.path).inserted {
      items.append(menuItem(name: name, url: url, icon: "drive"))
    }
    items.append(menuItem(name: NL("网络"), url: URL(string: "explorer://network")!, icon: "network"))
    return items
  }

  private func menuItem(name: String, url: URL, icon: String, checked: Bool = false) -> ExplorerMenuItem {
    ExplorerMenuItem(title: name, icon: icon, checked: checked, action: { [weak self] in self?.owner?.NavigateToPidl(url) })
  }

  deinit { dropDown?.cancel() }
}
