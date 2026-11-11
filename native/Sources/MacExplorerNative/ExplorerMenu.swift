import AppKit
import ExplorerCore
import QuartzCore

struct ExplorerMenuItem {
  var title: String
  var icon: String? = nil
  var checked = false
  var radio = false
  var enabled = true
  var divider = false
  var shortcut = ""
  var children: [ExplorerMenuItem] = []
  var loadChildren: (() async -> [ExplorerMenuItem])? = nil
  var applicationImage: NSImage? = nil
  var action: (() -> Void)? = nil

  var hasSubmenu: Bool { !children.isEmpty || loadChildren != nil }
}

private enum MenuAppearance {
  static let background = ExplorerPalette.dynamic(0xfcfcfc, 0x2c2c2c)
  static let border = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 15.0 / 255, darkAlpha: 18.0 / 255)
  static let divider = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 15.0 / 255, darkAlpha: 21.0 / 255)
  static let hover = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 9.0 / 255, darkAlpha: 15.0 / 255)
  static let pressed = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 6.0 / 255, darkAlpha: 10.0 / 255)
  static let secondary = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 158.0 / 255, darkAlpha: 197.0 / 255)
  static let tertiary = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 114.0 / 255, darkAlpha: 135.0 / 255)
  static let disabled = ExplorerPalette.dynamic(0, 0xffffff, lightAlpha: 92.0 / 255, darkAlpha: 93.0 / 255)
}

private struct MenuLayout {
  static let inset: CGFloat = 3
  static let captionFontSize: CGFloat = 12
  static let separatorWidth: CGFloat = 5
  let iconX: CGFloat
  let titleX: CGFloat
  let shortcutFont: NSFont
  let shortcutWidth: CGFloat
  let contentWidth: CGFloat

  init(_ items: [ExplorerMenuItem], hasQuickActions: Bool = false) {
    let hasIcons = items.contains { $0.icon != nil || $0.applicationImage != nil }
    let hasChecks = items.contains { $0.checked || $0.radio }
    iconX = hasChecks ? 39 : 12
    let titleX: CGFloat = hasIcons && hasChecks ? 67 : hasIcons || hasChecks ? 39 : 12
    self.titleX = titleX
    let caption = hasQuickActions ? ExplorerTypography.font(ofSize: Self.captionFontSize) : ExplorerTypography.font()
    shortcutFont = caption
    let shortcutWidth = ceil(items.map { ($0.shortcut as NSString).size(withAttributes: [.font: caption]).width }.max() ?? 0)
    self.shortcutWidth = shortcutWidth
    let titleFont = ExplorerTypography.font()
    contentWidth = items.map { item in
      let titleWidth = ceil((item.title as NSString).size(withAttributes: [.font: titleFont]).width)
      return titleX + titleWidth + Self.trailingWidth(for: item, shortcutWidth: shortcutWidth)
    }.max() ?? 0
  }

  private static func trailingWidth(for item: ExplorerMenuItem, shortcutWidth: CGFloat) -> CGFloat {
    let accelerator = item.shortcut.isEmpty ? 0 : 24 + shortcutWidth
    return 12 + accelerator + (item.hasSubmenu ? 36 : 0)
  }

  func trailingWidth(for item: ExplorerMenuItem) -> CGFloat {
    Self.trailingWidth(for: item, shortcutWidth: shortcutWidth)
  }

  func fittedWidth(quickWidth: CGFloat = 0) -> CGFloat {
    let outerInsets = 2 * (Self.inset + 1)
    return max(136, min(440, contentWidth + outerInsets), quickWidth + outerInsets)
  }
}

private final class MenuPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

final class ExplorerPopUpButton: NSPopUpButton {
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    window?.makeFirstResponder(self)
    performClick(nil)
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 49, 76, 125, 126: performClick(nil)
    default: super.keyDown(with: event)
    }
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, window != nil else { return false }
    performClick(nil)
    return true
  }

  override func performClick(_ sender: Any?) {
    guard isEnabled, !itemArray.isEmpty else { return }
    let items = itemArray.map { item in
      ExplorerMenuItem(title: item.title, checked: item === selectedItem, radio: true, enabled: item.isEnabled, action: { [weak self] in
        guard let self else { return }
        self.select(item)
        self.sendAction(self.action, to: self.target)
      })
    }
    ExplorerMenu.present(items, below: self)
  }
}

final class ExplorerMenu: NSObject {
  private static var current: ExplorerMenu?
  private let panel: MenuPanel
  private let shadowPanel: NSPanel
  private var child: ExplorerMenu?
  private var monitor: Any?
  private var rows: [MenuRow] = []
  private var selected = -1
  private var loadingChildren: Task<Void, Never>?
  private weak var parent: ExplorerMenu?
  private weak var owner: NSWindow?

  static func present(_ items: [ExplorerMenuItem], below view: NSView) {
    guard let window = view.window else { return }
    let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
    show(items, at: NSPoint(x: rect.minX, y: rect.minY - 5), owner: window)
  }
  static func show(_ items: [ExplorerMenuItem], at point: NSPoint, owner: NSWindow, quickActions: [ExplorerMenuItem] = []) {
    dismiss()
    let menu = ExplorerMenu(items: items, at: point, owner: owner, quickActions: quickActions)
    current = menu
    menu.panel.makeKeyAndOrderFront(nil)
    menu.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak menu] event in
      guard let menu else { return event }
      if event.type == .keyDown { return menu.handleKey(event) ? nil : event }
      if !menu.contains(event.window) { dismiss() }
      return event
    }
  }
  static func dismiss() { current?.close(); current = nil }

  static func fittedWidth(_ items: [ExplorerMenuItem]) -> CGFloat {
    MenuLayout(items).fittedWidth()
  }

  private init(items: [ExplorerMenuItem], at point: NSPoint, owner: NSWindow, parent: ExplorerMenu? = nil, quickActions: [ExplorerMenuItem] = []) {
    self.owner = owner; self.parent = parent
    let hasQuickActions = !quickActions.isEmpty
    let layout = MenuLayout(items, hasQuickActions: hasQuickActions)
    let quickSizes = quickActions.map { MenuQuickAction.fittedSize($0.title) }
    let inset = MenuLayout.inset
    let buttonHeight = quickSizes.map(\.height).max() ?? 0
    let quickWidth = quickSizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, quickSizes.count - 1)) * MenuLayout.separatorWidth
    let width = layout.fittedWidth(quickWidth: quickWidth)
    let topInset = hasQuickActions ? buttonHeight + 2 * inset + 2 : 1
    let rowHeight = max(32, ExplorerTypography.lineHeight + 13)
    let dividerHeight: CGFloat = 9
    let documentHeight = CGFloat(items.count) * rowHeight + CGFloat(items.filter(\.divider).count) * dividerHeight + 2 * inset
    let fullHeight = topInset + documentHeight + 1
    let screen = owner.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
    let viewport = owner.contentView.map { owner.convertToScreen($0.convert($0.bounds, to: nil)) } ?? owner.frame
    let region = viewport.intersection(screen)
    let height = min(fullHeight, max(50, region.height - 8))
    let proposedX = parent != nil && point.x + width > region.maxX ? parent!.panel.frame.minX - width - 5 : point.x
    let origin = NSPoint(x: max(region.minX + 4, min(proposedX, region.maxX - width - 4)), y: max(region.minY + 4, min(point.y - height, region.maxY - height - 4)))
    panel = MenuPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    shadowPanel = NSPanel(contentRect: panel.frame.insetBy(dx: -MenuShadowSurface.padding, dy: -MenuShadowSurface.padding), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
    panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
    shadowPanel.backgroundColor = .clear; shadowPanel.isOpaque = false; shadowPanel.hasShadow = false
    shadowPanel.level = panel.level; shadowPanel.isReleasedWhenClosed = false
    shadowPanel.ignoresMouseEvents = true
    shadowPanel.contentView = MenuShadowSurface(frame: NSRect(origin: .zero, size: shadowPanel.frame.size))
    panel.addChildWindow(shadowPanel, ordered: .below)
    let background = MenuSurface(frame: NSRect(x: 0, y: 0, width: width, height: height))
    panel.contentView = background
    let scroll = ExplorerScrollView(frame: NSRect(x: 1, y: topInset, width: width - 2, height: max(0, height - topInset - 1)))
    scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
    let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: width - 2, height: documentHeight))
    surface.color = .clear
    scroll.documentView = surface; background.addSubview(scroll)
    let contentWidth = scroll.contentSize.width
    surface.frame.size.width = contentWidth
    if hasQuickActions {
      var x = 1 + inset
      for (index, (item, size)) in zip(quickActions, quickSizes).enumerated() {
        if index > 0 {
          let separator = SurfaceView(frame: NSRect(x: x + 2, y: 1 + inset + 8, width: 1, height: buttonHeight - 16))
          separator.color = MenuAppearance.divider
          background.addSubview(separator)
          x += MenuLayout.separatorWidth
        }
        let button = MenuQuickAction(item: item)
        button.frame = NSRect(x: x, y: 1 + inset, width: size.width, height: buttonHeight)
        button.fill.install(behind: button, in: background)
        x += size.width
      }
      let line = SurfaceView(frame: NSRect(x: 1, y: topInset - 1, width: width - 2, height: 1))
      line.color = MenuAppearance.divider
      background.addSubview(line)
    }
    let rowWidth = contentWidth - 2 * inset
    var y = inset
    for item in items {
      if item.divider {
        let separator = SurfaceView(frame: NSRect(x: inset, y: y + 4, width: rowWidth, height: 1))
        separator.color = MenuAppearance.divider
        surface.addSubview(separator); y += dividerHeight
      }
      let row = MenuRow(item: item, frame: NSRect(x: inset, y: y, width: rowWidth, height: rowHeight), menuLayout: layout)
      let index = rows.count
      row.hover = { [weak self] in self?.highlight(index) }
      row.perform = { [weak self] in self?.activate(index) }
      row.fill.install(behind: row, in: surface); rows.append(row); y += rowHeight
    }
    owner.addChildWindow(panel, ordered: .above)
  }
  private func contains(_ window: NSWindow?) -> Bool { window === panel || child?.contains(window) == true }
  private func closeChild() {
    loadingChildren?.cancel(); loadingChildren = nil
    child?.close(); child = nil
    if rows.indices.contains(selected) { rows[selected].submenuOpen = false }
  }
  private func close() {
    closeChild()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    panel.removeChildWindow(shadowPanel); shadowPanel.orderOut(nil)
    owner?.removeChildWindow(panel); panel.orderOut(nil)
  }
  private func highlight(_ index: Int) {
    guard rows.indices.contains(index), rows[index].item.enabled else { return }
    if selected == index, child != nil { return }
    closeChild()
    selected = index
    rows[index].scrollToVisible(rows[index].bounds)
    for (i, row) in rows.enumerated() { row.highlighted = i == index }
    let item = rows[index].item
    if item.hasSubmenu, let owner {
      let rect = panel.convertToScreen(rows[index].convert(rows[index].bounds, to: nil))
      child = ExplorerMenu(items: item.children, at: NSPoint(x: rect.maxX + 5, y: rect.maxY + 5), owner: owner, parent: self)
      rows[index].submenuOpen = true
      child?.panel.orderFront(nil)
      if let load = item.loadChildren {
        loadingChildren = Task { @MainActor [weak self, weak owner] in
          let items = await load()
          guard let self, let owner, !Task.isCancelled, self.selected == index, self.panel.isVisible else { return }
          let focused = self.child?.panel.isKeyWindow == true
          self.child?.close()
          self.child = ExplorerMenu(items: items, at: NSPoint(x: rect.maxX + 5, y: rect.maxY + 5), owner: owner, parent: self)
          if focused { self.child?.panel.makeKeyAndOrderFront(nil); self.child?.highlight(0) } else { self.child?.panel.orderFront(nil) }
        }
      }
    }
  }
  private func activate(_ index: Int) {
    guard rows.indices.contains(index), rows[index].item.enabled else { return }
    let item = rows[index].item
    if item.hasSubmenu { highlight(index); return }
    Self.dismiss(); item.action?()
  }
  private func handleKey(_ event: NSEvent) -> Bool {
    if let child, child.panel.isKeyWindow { return child.handleKey(event) }
    switch event.keyCode {
    case 53: Self.dismiss()
    case 125, 126:
      let delta = event.keyCode == 125 ? 1 : -1
      var index = selected
      for _ in rows.indices {
        index = (index + delta + rows.count) % rows.count
        if rows[index].item.enabled { highlight(index); break }
      }
    case 124: child?.panel.makeKeyAndOrderFront(nil); child?.highlight(0)
    case 123:
      if let parent {
        parent.panel.makeKeyAndOrderFront(nil)
        parent.closeChild()
        parent.rows[parent.selected].highlighted = true
      } else { Self.dismiss() }
    case 36, 49: activate(selected)
    default: return false
    }
    return true
  }
}

private final class MenuShadowSurface: NSView {
  static let padding: CGFloat = 32
  private static let color = ExplorerPalette.dynamic(0, 0, lightAlpha: 35.0 / 255, darkAlpha: 66.0 / 255)

  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.clear(bounds)
    let caster = bounds.insetBy(dx: Self.padding, dy: Self.padding)
    let hole = CGPath(roundedRect: caster, cornerWidth: 8, cornerHeight: 8, transform: nil)
    context.saveGState()
    context.addRect(bounds); context.addPath(hole); context.clip(using: .evenOdd)
    let displacement = bounds.width + Self.padding
    context.setShadow(offset: CGSize(width: -displacement, height: -8), blur: 16, color: Self.color.cgColor)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.addPath(CGPath(roundedRect: caster.offsetBy(dx: displacement, dy: 0), cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.fillPath()
    context.restoreGState()
  }
}

private final class MenuSurface: NSView {
  override var isFlipped: Bool { true }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    MenuAppearance.background.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
    MenuAppearance.border.setStroke()
    outline.lineWidth = 1
    outline.stroke()
  }
}

private final class MenuItemFill: NSView {
  enum State { case normal, highlighted, pressed }
  var state: State = .normal {
    didSet { if state != oldValue { updateFill(animated: true) } }
  }

  func install(behind item: NSView, in container: NSView) {
    frame = item.frame.insetBy(dx: 2, dy: 2)
    wantsLayer = true
    layer?.cornerRadius = 4
    container.addSubview(self)
    container.addSubview(item)
    updateFill(animated: false)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateFill(animated: false)
  }

  private func updateFill(animated: Bool) {
    guard let layer else { return }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let color: NSColor
      switch state {
      case .normal: color = MenuAppearance.hover.withAlphaComponent(0)
      case .highlighted: color = MenuAppearance.hover
      case .pressed: color = MenuAppearance.pressed
      }
      let previous = (layer.presentation() ?? layer).backgroundColor
      let next = color.cgColor
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.backgroundColor = next
      layer.removeAnimation(forKey: "backgroundColor")
      if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let transition = CABasicAnimation(keyPath: "backgroundColor")
        transition.fromValue = previous
        transition.toValue = next
        transition.duration = 0.083
        layer.add(transition, forKey: "backgroundColor")
      }
      CATransaction.commit()
    }
  }
}

private final class MenuQuickAction: NSButton {
  let fill = MenuItemFill()
  private let item: ExplorerMenuItem
  private var hovered = false { didSet { updateFill() } }
  private var pressed = false { didSet { updateFill() } }
  private static let titleY: CGFloat = 9 + 16 + 6
  private static var labelAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    return [.font: ExplorerTypography.font(ofSize: MenuLayout.captionFontSize), .paragraphStyle: paragraph]
  }

  static func fittedSize(_ title: String) -> NSSize {
    let attributes = labelAttributes
    let text = title as NSString
    let width = min(120, max(60, ceil(text.size(withAttributes: attributes).width)))
    let label = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: attributes)
    return NSSize(width: width, height: max(52, titleY + ceil(label.height) + 2))
  }

  init(item: ExplorerMenuItem) {
    self.item = item; super.init(frame: .zero); title = item.title; isEnabled = item.enabled; isBordered = false; target = self; action = #selector(invoke); toolTip = item.title + (item.shortcut.isEmpty ? "" : "（\(item.shortcut)）")
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  @objc private func invoke() { ExplorerMenu.dismiss(); item.action?() }
  override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func mouseDown(with event: NSEvent) {
    pressed = isEnabled
    super.mouseDown(with: event)
    pressed = false
  }
  private func updateFill() {
    fill.state = !isEnabled ? .normal : pressed ? .pressed : hovered ? .highlighted : .normal
  }
  override func draw(_ dirtyRect: NSRect) {
    if let icon = item.icon { ExplorerIcons.image(icon, size: 16).draw(in: NSRect(x: bounds.midX - 8, y: 9, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil) }
    var attributes = Self.labelAttributes
    attributes[.foregroundColor] = ExplorerPalette.text.withAlphaComponent(isEnabled ? 1 : 0.35)
    let label = NSRect(x: 0, y: Self.titleY, width: bounds.width, height: bounds.height - Self.titleY)
    (title as NSString).draw(with: label, options: .usesLineFragmentOrigin, attributes: attributes)
  }
}

private final class MenuRow: NSView {
  let item: ExplorerMenuItem
  let fill = MenuItemFill()
  private let menuLayout: MenuLayout
  var hover: (() -> Void)?
  var perform: (() -> Void)?
  var highlighted = false { didSet { updateFill() } }
  var submenuOpen = false { didSet { updateFill() } }
  private var pressed = false { didSet { updateFill(); needsDisplay = true } }
  override var isFlipped: Bool { true }
  init(item: ExplorerMenuItem, frame: NSRect, menuLayout: MenuLayout) {
    self.item = item
    self.menuLayout = menuLayout
    super.init(frame: frame)
    setAccessibilityRole(.menuItem)
    setAccessibilityLabel(item.title)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseEntered(with event: NSEvent) { hover?() }
  override func mouseExited(with event: NSEvent) { highlighted = false }
  override func mouseDown(with event: NSEvent) { pressed = item.enabled }
  override func mouseDragged(with event: NSEvent) { pressed = item.enabled && bounds.contains(convert(event.locationInWindow, from: nil)) }
  override func mouseUp(with event: NSEvent) {
    pressed = false
    if item.enabled && bounds.contains(convert(event.locationInWindow, from: nil)) { perform?() }
  }
  private func updateFill() {
    fill.state = pressed ? .pressed : highlighted || submenuOpen ? .highlighted : .normal
  }
  override func draw(_ dirtyRect: NSRect) {
    let color = ExplorerPalette.text.withAlphaComponent(item.enabled ? 1 : 0.35)
    let secondary = !item.enabled ? MenuAppearance.disabled : pressed ? MenuAppearance.tertiary : MenuAppearance.secondary
    if item.checked {
      if item.radio { color.setFill(); NSBezierPath(ovalIn: NSRect(x: 12, y: bounds.midY - 2.5, width: 5, height: 5)).fill() }
      else { ExplorerIcons.image("check", size: 12, color: color).draw(in: NSRect(x: 8, y: bounds.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    }
    let iconFrame = NSRect(x: menuLayout.iconX, y: bounds.midY - 8, width: 16, height: 16)
    if let icon = item.icon { ExplorerIcons.image(icon, size: 16, color: color).draw(in: iconFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    if let image = item.applicationImage { image.draw(in: iconFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    let font = ExplorerTypography.font()
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    let line = ceil(font.ascender - font.descender)
    let titleX = menuLayout.titleX
    let trailing = menuLayout.trailingWidth(for: item)
    (item.title as NSString).draw(in: NSRect(x: titleX, y: bounds.midY - line / 2, width: max(0, bounds.width - titleX - trailing), height: line + 2), withAttributes: attrs)
    if item.hasSubmenu {
      let arrowFrame = NSRect(x: bounds.width - 24, y: bounds.midY - 6, width: 12, height: 12)
      ExplorerIcons.image("chevronRight", size: 12, color: secondary).draw(in: arrowFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    if !item.shortcut.isEmpty {
      let font = menuLayout.shortcutFont
      let x = bounds.width - trailing + 24
      let y = bounds.midY - ceil(font.ascender - font.descender) / 2
      (item.shortcut as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: secondary])
    }
  }
}
