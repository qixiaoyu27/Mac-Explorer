import AppKit
import ExplorerCore

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
}

private final class MenuPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

final class ExplorerMenu: NSObject {
  private static var current: ExplorerMenu?
  private let panel: MenuPanel
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

  static func fittedWidth(_ items: [ExplorerMenuItem], submenu: Bool, quickActions: [ExplorerMenuItem] = []) -> CGFloat {
    let font = ExplorerTypography.font()
    let contentWidth = items.map { item -> CGFloat in
      let title = (item.title as NSString).size(withAttributes: [.font: font]).width
      let trailing: CGFloat = !item.children.isEmpty || item.loadChildren != nil ? 34 : item.shortcut.isEmpty ? 12 : (item.shortcut as NSString).size(withAttributes: [.font: font]).width + 28
      return ceil(10 + 56 + title + trailing)
    }.max() ?? 0
    let quickWidth = quickActions.map { ceil(($0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width) + 12 }.max() ?? 0
    let quickRowWidth = quickActions.isEmpty ? 0 : quickWidth * CGFloat(quickActions.count) + 12 + CGFloat(quickActions.count - 1) * 2
    return max(max(submenu ? 180 : 235, min(max(350, ExplorerTypography.baseSize * 27), contentWidth)), quickRowWidth)
  }

  private init(items: [ExplorerMenuItem], at point: NSPoint, owner: NSWindow, parent: ExplorerMenu? = nil, quickActions: [ExplorerMenuItem] = []) {
    self.owner = owner; self.parent = parent
    let width = Self.fittedWidth(items, submenu: parent != nil, quickActions: quickActions)
    let rowHeight = max(33, ExplorerTypography.lineHeight + 12)
    let fullHeight = CGFloat(items.count) * rowHeight + CGFloat( items.filter(\.divider).count * 11 + 12 + (quickActions.isEmpty ? 0 : 63))
    let screen = owner.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
    let viewport = owner.contentView.map { owner.convertToScreen($0.convert($0.bounds, to: nil)) } ?? owner.frame
    let region = viewport.intersection(screen)
    let height = min(fullHeight, max(50, region.height - 8))
    let proposedX = parent != nil && point.x + width > region.maxX ? parent!.panel.frame.minX - width - 5 : point.x
    let origin = NSPoint(x: max(region.minX + 4, min(proposedX, region.maxX - width - 4)), y: max(region.minY + 4, min(point.y - height, region.maxY - height - 4)))
    panel = MenuPanel(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
    panel.level = .popUpMenu; panel.isReleasedWhenClosed = false
    let background = MenuSurface(frame: NSRect(x: 0, y: 0, width: width, height: height))
    panel.contentView = background
    let scroll = ExplorerScrollView(frame: background.bounds.insetBy(dx: 1, dy: 5))
    scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
    let surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: width - 2, height: fullHeight - 10)); surface.color = ExplorerPalette.toolbar
    scroll.documentView = surface; background.addSubview(scroll)
    let contentWidth = scroll.contentSize.width
    surface.frame.size.width = contentWidth
    var y: CGFloat = 0
    if !quickActions.isEmpty {
      let itemWidth = (contentWidth - 10 - CGFloat(quickActions.count - 1) * 2) / CGFloat(quickActions.count)
      for (index, item) in quickActions.enumerated() {
        let button = MenuQuickAction(item: item); button.frame = NSRect(x: 5 + CGFloat(index) * (itemWidth + 2), y: 0, width: itemWidth, height: 52); surface.addSubview(button)
      }
      let line = SurfaceView(frame: NSRect(x: 5, y: 57, width: contentWidth - 10, height: 1)); line.color = ExplorerPalette.border; surface.addSubview(line); y += 63
    }
    for item in items {
      if item.divider {
        let separator = SurfaceView(frame: NSRect(x: 8, y: y + 4, width: contentWidth - 14, height: 1)); separator.color = ExplorerPalette.border
        surface.addSubview(separator); y += 11
      }
      let row = MenuRow(item: item, frame: NSRect(x: 5, y: y, width: contentWidth - 8, height: rowHeight))
      let index = rows.count
      row.hover = { [weak self] in self?.highlight(index) }
      row.perform = { [weak self] in self?.activate(index) }
      surface.addSubview(row); rows.append(row); y += rowHeight
    }
    owner.addChildWindow(panel, ordered: .above)
  }
  private func contains(_ window: NSWindow?) -> Bool { window === panel || child?.contains(window) == true }
  private func close() {
    loadingChildren?.cancel(); loadingChildren = nil
    child?.close(); child = nil
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    owner?.removeChildWindow(panel); panel.orderOut(nil)
  }
  private func highlight(_ index: Int) {
    guard rows.indices.contains(index), rows[index].item.enabled else { return }
    if selected == index, child != nil { return }
    loadingChildren?.cancel(); loadingChildren = nil
    selected = index
    rows[index].scrollToVisible(rows[index].bounds)
    for (i, row) in rows.enumerated() { row.highlighted = i == index }
    child?.close(); child = nil
    let item = rows[index].item
    if !item.children.isEmpty || item.loadChildren != nil, let owner {
      let rect = panel.convertToScreen(rows[index].convert(rows[index].bounds, to: nil))
      child = ExplorerMenu(items: item.children, at: NSPoint(x: rect.maxX + 5, y: rect.maxY + 5), owner: owner, parent: self)
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
    if !item.children.isEmpty || item.loadChildren != nil { highlight(index); return }
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
      if let parent { parent.panel.makeKeyAndOrderFront(nil); close(); parent.child = nil } else { Self.dismiss() }
    case 36, 49: activate(selected)
    default: return false
    }
    return true
  }
}

private final class MenuSurface: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    ExplorerPalette.toolbar.setFill(); path.fill()
    ExplorerPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
  }
}

private final class MenuQuickAction: NSButton {
  private let item: ExplorerMenuItem
  private var hovered = false
  init(item: ExplorerMenuItem) {
    self.item = item; super.init(frame: .zero); title = item.title; isEnabled = item.enabled; isBordered = false; target = self; action = #selector(invoke); toolTip = item.title + (item.shortcut.isEmpty ? "" : "（\(item.shortcut)）")
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  @objc private func invoke() { ExplorerMenu.dismiss(); item.action?() }
  override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    if hovered && isEnabled { ExplorerPalette.hover.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    if let icon = item.icon { ExplorerIcons.image(icon, size: 18).draw(in: NSRect(x: bounds.midX - 9, y: 8, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil) }
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ExplorerPalette.text.withAlphaComponent(isEnabled ? 1 : 0.35)]
    let text = title as NSString; text.draw(at: NSPoint(x: bounds.midX - text.size(withAttributes: attrs).width / 2, y: 32), withAttributes: attrs)
  }
}

private final class MenuRow: NSView {
  let item: ExplorerMenuItem
  var hover: (() -> Void)?
  var perform: (() -> Void)?
  var highlighted = false { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  init(item: ExplorerMenuItem, frame: NSRect) { self.item = item; super.init(frame: frame); setAccessibilityRole(.menuItem); setAccessibilityLabel(item.title) }
  required init?(coder: NSCoder) { fatalError() }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseEntered(with event: NSEvent) { hover?() }
  override func mouseUp(with event: NSEvent) { if item.enabled { perform?() } }
  override func draw(_ dirtyRect: NSRect) {
    if highlighted { ExplorerPalette.hover.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    let color = ExplorerPalette.text.withAlphaComponent(item.enabled ? 1 : 0.35)
    if item.checked {
      if item.radio { color.setFill(); NSBezierPath(ovalIn: NSRect(x: 12, y: 14, width: 5, height: 5)).fill() }
      else { ExplorerIcons.image("check", size: 12, color: color).draw(in: NSRect(x: 8, y: 10, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    }
    if let icon = item.icon { ExplorerIcons.image(icon, size: 16, color: color).draw(in: NSRect(x: 30, y: 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    if let image = item.applicationImage { image.draw(in: NSRect(x: 30, y: 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    let font = ExplorerTypography.font()
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    let line = ceil(font.ascender - font.descender)
    let trailing: CGFloat = item.shortcut.isEmpty ? 28 : (item.shortcut as NSString).size(withAttributes: attrs).width + 28
    (item.title as NSString).draw(in: NSRect(x: 56, y: bounds.midY - line / 2, width: max(0, bounds.width - 56 - trailing), height: line + 2), withAttributes: attrs)
    if !item.children.isEmpty || item.loadChildren != nil { ExplorerIcons.image("chevronRight", size: 12, color: color).draw(in: NSRect(x: bounds.width - 22, y: 10, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    else if !item.shortcut.isEmpty {
      let text = item.shortcut as NSString
      text.draw(at: NSPoint(x: bounds.width - text.size(withAttributes: attrs).width - 12, y: bounds.midY - line / 2), withAttributes: attrs)
    }
  }
}
