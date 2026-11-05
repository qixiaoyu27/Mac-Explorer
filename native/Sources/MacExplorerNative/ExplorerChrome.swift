import AppKit
import ExplorerCore

/// CSS tokens and their exact light-mode fallbacks from tokens.css/styles.css.
/// AppKit resolves these against each view's effectiveAppearance, not system-wide state.
enum ExplorerPalette {
  static let text = dynamic(0x242424, 0xf2f2f2)
  static let secondary = dynamic(0x656565, 0xbfbfbf)
  static let surface = dynamic(0xffffff, 0x191919)
  static let mica = dynamic(0xeeeef2, 0x202024)
  static let border = dynamic(0xe5e5e5, 0x383838)
  static let hover = dynamic(0x000000, 0xffffff, lightAlpha: 8.0 / 255, darkAlpha: 13.0 / 255)
  static let pressed = dynamic(0x000000, 0xffffff, lightAlpha: 14.0 / 255, darkAlpha: 22.0 / 255)
  static let accent = dynamic(0x0067c0, 0x70c5ff)
  static let selection = dynamic(0xe5f3ff, 0x29445a)
  static let sidebar = dynamic(0xfcfcfc, 0x202020)
  static let toolbar = dynamic(0xfafafa, 0x242424)
  static let input = dynamic(0xf9f9f9, 0x2c2c2c)
  static let active = dynamic(0xeaeaea, 0x373737)
  static let rowHover = dynamic(0xf3f7fa, 0x292929)
  static let errorSurface = dynamic(0xfff8e9, 0x3b3020)
  static let errorText = dynamic(0x7a592b, 0xf5d89d)
  static let commandAccent = dynamic(0x386c9d, 0x79bbeb)
  static func place(_ name: String) -> NSColor {
    let light: [String: UInt32] = ["desktop": 0x407fa7, "applications": 0x407fa7, "download": 0x31836b, "document": 0x527daa, "image": 0x6583b5, "music": 0xb7759b, "video": 0x9868b4, "folder": 0xb78724, "drive": 0x737f88, "computer": 0x50778f]
    let dark: [String: UInt32] = ["download": 0x74cbb0, "music": 0xe1a2c7, "video": 0xc7a1e2, "folder": 0xe2b84f, "drive": 0xa4b1bc]
    return dynamic(light[name] ?? 0x3d759b, dark[name] ?? 0x83b5d9)
  }
  fileprivate static let tabHover = dynamic(0xe9e9ec, 0x2d2d31)
  fileprivate static let pin = dynamic(0x777777, 0xbfbfbf)
  fileprivate static let chevron = dynamic(0x646464, 0xbfbfbf)

  fileprivate static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
  }

  private static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? rgb(dark, alpha: darkAlpha)
        : rgb(light, alpha: lightAlpha)
    }
  }
}

private var explorerLabelFont: NSFont { ExplorerTypography.font() }

private func drawExplorerText(_ text: String, in rect: NSRect, color: NSColor = ExplorerPalette.text) {
  guard rect.width > 0, rect.height > 0 else { return }
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineBreakMode = .byTruncatingTail
  let height = ceil(explorerLabelFont.ascender - explorerLabelFont.descender)
  let frame = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
  (text as NSString).draw(in: frame, withAttributes: [.font: explorerLabelFont, .foregroundColor: color, .paragraphStyle: paragraph])
}

private func drawExplorerImage(_ image: NSImage, in rect: NSRect, fraction: CGFloat = 1) {
  image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
}

private func drawExplorerFocus(in rect: NSRect) {
  ExplorerPalette.accent.setStroke()
  let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
  path.lineWidth = 2
  path.stroke()
}

/// A native target/action button with Explorer painting instead of an AppKit bezel.
final class ExplorerButton: NSButton {
  var onPress: (() -> Void)?
  var onContextMenu: ((NSEvent) -> Void)?
  var onFileDragValidate: ((NSDraggingInfo) -> NSDragOperation)?
  var onFileDrop: ((NSDraggingInfo) -> Bool)?
  var active = false { didSet { needsDisplay = true } }
  var iconColor: NSColor? { didSet { needsDisplay = true } }
  var iconName: String? { didSet { updateMetrics() } }
  var showsDropdown: Bool { didSet { updateMetrics() } }
  var iconDimension: CGFloat = 18 { didSet { updateMetrics() } }
  var horizontalPadding: CGFloat = 8 { didSet { updateMetrics() } }
  private var hovered = false
  private var fileDropHovered = false
  private var hoverArea: NSTrackingArea?

  init(title: String = "", icon: String? = nil, dropdown: Bool = false, action: (() -> Void)? = nil) {
    iconName = icon
    showsDropdown = dropdown
    onPress = action
    super.init(frame: NSRect(x: 0, y: 0, width: 35, height: 34))
    self.title = title
    font = explorerLabelFont
    isBordered = false
    setButtonType(.momentaryPushIn)
    focusRingType = .none
    target = self
    self.action = #selector(pressed)
    registerForDraggedTypes([.fileURL])
    updateMetrics()
  }

  required init?(coder: NSCoder) { fatalError("Use init(title:icon:dropdown:action:)") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { isEnabled }
  override var mouseDownCanMoveWindow: Bool { false }
  override var title: String { didSet { updateMetrics() } }
  override var isEnabled: Bool { didSet { needsDisplay = true } }

  override var intrinsicContentSize: NSSize {
    if title.isEmpty && !showsDropdown { return NSSize(width: 35, height: 34) }
    let textWidth = ceil((title as NSString).size(withAttributes: [.font: explorerLabelFont]).width)
    let pieces = (iconName == nil ? 0 : 1) + (title.isEmpty ? 0 : 1) + (showsDropdown ? 1 : 0)
    let width = horizontalPadding * 2 + textWidth + (iconName == nil ? 0 : iconDimension) + (showsDropdown ? 12 : 0) + CGFloat(max(0, pieces - 1)) * 6
    return NSSize(width: width, height: 34)
  }

  private func updateMetrics() {
    invalidateIntrinsicContentSize()
    needsDisplay = true
    if !title.isEmpty { setAccessibilityLabel(title) }
    else if let iconName {
      let labels = ["arrowLeft": "Back", "arrowRight": "Forward", "arrowUp": "Up", "panelRight": "Details pane", "panelLeft": "Navigation pane", "more": "More", "chevronDown": "Expand", "chevronRight": "Expand"]
      setAccessibilityLabel(labels[iconName] ?? iconName.prefix(1).uppercased() + iconName.dropFirst())
    }
  }

  @objc private func pressed() { onPress?() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func rightMouseDown(with event: NSEvent) { if let onContextMenu { onContextMenu(event) } else { super.rightMouseDown(with: event) } }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
  override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

  override func keyDown(with event: NSEvent) {
    if isEnabled && (event.keyCode == 36 || event.keyCode == 76) { performClick(nil) }
    else { super.keyDown(with: event) }
  }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      let background: NSColor? = active || fileDropHovered || (isEnabled && cell?.isHighlighted == true)
        ? ExplorerPalette.pressed : (hovered && isEnabled ? ExplorerPalette.hover : nil)
      if let background {
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
      }
      let count = (iconName == nil ? 0 : 1) + (title.isEmpty ? 0 : 1) + (showsDropdown ? 1 : 0)
      let fixedWidth = (iconName == nil ? 0 : iconDimension) + (showsDropdown ? 12 : 0) + CGFloat(max(0, count - 1)) * 6
      let textWidth = min(ceil((title as NSString).size(withAttributes: [.font: explorerLabelFont]).width), max(0, bounds.width - horizontalPadding * 2 - fixedWidth))
      var x = alignment == .left ? horizontalPadding : bounds.midX - (fixedWidth + textWidth) / 2
      if let iconName {
        drawExplorerImage(ExplorerIcons.image(iconName, size: iconDimension, color: iconColor), in: NSRect(x: x, y: bounds.midY - iconDimension / 2, width: iconDimension, height: iconDimension), fraction: isEnabled ? 1 : 0.35)
        x += iconDimension + 6
      }
      if !title.isEmpty {
        drawExplorerText(title, in: NSRect(x: x, y: bounds.minY, width: textWidth + 1, height: bounds.height), color: ExplorerPalette.text.withAlphaComponent(isEnabled ? 1 : 0.35))
        x += textWidth + 6
      }
      if showsDropdown {
        drawExplorerImage(ExplorerIcons.image("chevronDown", size: 12), in: NSRect(x: x, y: bounds.midY - 6, width: 12, height: 12))
      }
      if isEnabled && window?.firstResponder === self && ExplorerFocus.keyboardVisible { drawExplorerFocus(in: bounds) }
    }
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let operation = onFileDragValidate?(sender) ?? []
    fileDropHovered = !operation.isEmpty; needsDisplay = true
    return operation
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { fileDropHovered = false; needsDisplay = true }
  override func draggingEnded(_ sender: NSDraggingInfo) { fileDropHovered = false; needsDisplay = true }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !(onFileDragValidate?(sender) ?? []).isEmpty }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let accepted = onFileDrop?(sender) ?? false
    fileDropHovered = false; needsDisplay = true
    return accepted
  }
}

final class ExplorerTabView: NSView {
  var onDragValidate: ((NSDraggingInfo) -> NSDragOperation)?
  var onDrop: ((NSDraggingInfo) -> Bool)?
  private var dragHover: DispatchWorkItem?
  private var fileDragHovered = false
  var canDetach: (() -> Bool)?
  var onDetach: ((NSPoint) -> Bool)?
  private var dragStart: NSPoint?
  private let onClose: () -> Void
  var badgeName: String? { didSet { needsDisplay = true } }
  var locationIcon: String? { didSet { needsDisplay = true } }
  var text: String {
    didSet {
      setAccessibilityLabel(text)
      closeButton.setAccessibilityLabel("Close \(text)")
      needsDisplay = true
    }
  }
  var selected: Bool { didSet { setAccessibilityValue(selected ? 1 : 0); needsDisplay = true } }
  private let onSelect: () -> Void
  private let closeButton: ExplorerButton
  private var hovered = false
  private var mousePressed = false
  private var hoverArea: NSTrackingArea?

  init(title: String, active: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
    text = title
    selected = active
    self.onSelect = onSelect
    self.onClose = onClose
    closeButton = ExplorerButton(icon: "close", action: onClose)
    super.init(frame: NSRect(x: 0, y: 0, width: 214, height: 36))
    focusRingType = .none
    closeButton.iconDimension = 13
    closeButton.setAccessibilityLabel("Close \(title)")
    addSubview(closeButton)
    needsLayout = true
    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
    setAccessibilityLabel(title)
    setAccessibilityValue(active ? 1 : 0)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) { fatalError("Use init(title:active:onSelect:onClose:)") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize { NSSize(width: 214, height: 36) }

  override func layout() {
    super.layout()
    closeButton.frame = NSRect(x: bounds.maxX - 32, y: bounds.midY - 12, width: 25, height: 24)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    let operation = onDragValidate?(sender) ?? []
    guard !operation.isEmpty else { endFileDrag(); return [] }
    fileDragHovered = true; needsDisplay = true
    if !selected, dragHover == nil {
      let work = DispatchWorkItem { [weak self] in guard let self, self.fileDragHovered, self.window != nil else { return }; self.dragHover = nil; self.onSelect() }
      dragHover = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    return operation
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { endFileDrag() }
  override func draggingEnded(_ sender: NSDraggingInfo) { endFileDrag() }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !(onDragValidate?(sender) ?? []).isEmpty }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { endFileDrag(); return onDrop?(sender) ?? false }
  private func endFileDrag() { dragHover?.cancel(); dragHover = nil; fileDragHovered = false; needsDisplay = true }
  override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { endFileDrag() }; super.viewWillMove(toWindow: newWindow) }
  deinit { dragHover?.cancel() }
  override func mouseDown(with event: NSEvent) {
    mousePressed = true; window?.makeFirstResponder(self)
    dragStart = canDetach?() == true ? event.locationInWindow : nil
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStart, let window, canDetach?() == true,
      abs(event.locationInWindow.y - start.y) >= 24,
      let root = window.contentView else { return }
    let point = root.convert(event.locationInWindow, from: nil)
    guard point.y < -16 || point.y > 64 else { return }
    dragStart = nil; mousePressed = false
    _ = onDetach?(window.convertPoint(toScreen: event.locationInWindow))
  }
  override func mouseUp(with event: NSEvent) {
    let shouldSelect = mousePressed && bounds.contains(convert(event.locationInWindow, from: nil))
    mousePressed = false; dragStart = nil
    if shouldSelect { onSelect() }
  }
  override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 && bounds.contains(convert(event.locationInWindow, from: nil)) { onClose() } else { super.otherMouseUp(with: event) }
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { dragStart = nil; mousePressed = false; return }
    if [36, 49, 76].contains(event.keyCode) { onSelect() }
    else { super.keyDown(with: event) }
  }
  override func accessibilityPerformPress() -> Bool { onSelect(); return true }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { mousePressed = false; needsDisplay = true; return true }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if selected || hovered || fileDragHovered {
        (fileDragHovered ? ExplorerPalette.selection : selected ? ExplorerPalette.surface : ExplorerPalette.tabHover).setFill()
        let shape = NSBezierPath()
        let r: CGFloat = min(8, bounds.width / 2)
        let k: CGFloat = 0.5522847498
        shape.move(to: NSPoint(x: bounds.minX, y: bounds.maxY))
        shape.line(to: NSPoint(x: bounds.minX, y: bounds.minY + r))
        shape.curve(to: NSPoint(x: bounds.minX + r, y: bounds.minY), controlPoint1: NSPoint(x: bounds.minX, y: bounds.minY + r * (1 - k)), controlPoint2: NSPoint(x: bounds.minX + r * (1 - k), y: bounds.minY))
        shape.line(to: NSPoint(x: bounds.maxX - r, y: bounds.minY))
        shape.curve(to: NSPoint(x: bounds.maxX, y: bounds.minY + r), controlPoint1: NSPoint(x: bounds.maxX - r * (1 - k), y: bounds.minY), controlPoint2: NSPoint(x: bounds.maxX, y: bounds.minY + r * (1 - k)))
        shape.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        shape.close()
        shape.fill()
      }
      if !selected {
        ExplorerPalette.border.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY + 11, width: 1, height: 15).fill()
      }
      let iconRect = NSRect(x: bounds.minX + 14, y: bounds.midY - 10.5, width: 21, height: 21)
      drawExplorerImage(locationIcon.map { ExplorerIcons.image($0, size: 18, color: ExplorerPalette.secondary) } ?? ExplorerIcons.folder(size: 21), in: iconRect)
      if let badgeName {
        let badge = NSRect(x: iconRect.maxX - 11, y: iconRect.maxY - 12.5, width: 11, height: 11)
        ExplorerPalette.sidebar.setFill(); NSBezierPath(roundedRect: badge, xRadius: 3.5, yRadius: 3.5).fill()
        ExplorerPalette.border.setStroke(); NSBezierPath(roundedRect: badge.insetBy(dx: 0.25, dy: 0.25), xRadius: 3.5, yRadius: 3.5).stroke()
        drawExplorerImage(ExplorerIcons.image(badgeName, size: 7, color: NSColor(srgbRed: 82 / 255, green: 125 / 255, blue: 170 / 255, alpha: 1)), in: badge.insetBy(dx: 2, dy: 2))
      }
      drawExplorerText(text, in: NSRect(x: bounds.minX + 45, y: bounds.minY, width: max(0, bounds.width - 88), height: bounds.height))
      if window?.firstResponder === self && ExplorerFocus.keyboardVisible {
        drawExplorerFocus(in: NSRect(x: bounds.minX + 2, y: bounds.minY + 2, width: max(0, bounds.width - 36), height: bounds.height - 4))
      }
    }
  }
}

final class ExplorerSidebarRow: NSView, NSDraggingSource {
  static let placeType = NSPasteboard.PasteboardType("local.macexplorer.quick-access")
  var placePath: String?
  var onContext: ((NSEvent) -> Void)?
  var onOpenTab: (() -> Void)?
  var onDragUpdate: ((NSDraggingInfo, CGFloat) -> NSDragOperation)?
  var onDrop: ((NSDraggingInfo, CGFloat) -> Bool)?
  var onDragExit: (() -> Void)?
  private var downEvent: NSEvent?
  var selected = false { didSet { setAccessibilityValue(selected ? 1 : 0); needsDisplay = true } }
  var expanded = false {
    didSet {
      disclosureButton.iconName = expanded ? "chevronDown" : "chevronRight"
      updateDisclosure()
    }
  }
  var onExpand: (() -> Void)? { didSet { updateDisclosure() } }
  var tint: NSColor? { didSet { needsDisplay = true } }
  private let text: String
  private let icon: String
  private let level: Int
  private let pinned: Bool
  private let onOpen: () -> Void
  private let disclosureButton = ExplorerButton(icon: "chevronRight")
  private var hovered = false
  private var mousePressed = false
  private var hoverArea: NSTrackingArea?

  init(title: String, icon: String, level: Int = 0, pinned: Bool = false, onOpen: @escaping () -> Void) {
    text = title
    self.icon = icon
    self.level = max(0, level)
    self.pinned = pinned
    self.onOpen = onOpen
    super.init(frame: NSRect(x: 0, y: 0, width: 192, height: 36))
    focusRingType = .none
    disclosureButton.iconDimension = 12
    disclosureButton.iconColor = ExplorerPalette.chevron
    disclosureButton.onPress = { [weak self] in self?.onExpand?() }
    addSubview(disclosureButton)
    needsLayout = true
    updateDisclosure()
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
    setAccessibilityValue(0)
    registerForDraggedTypes([Self.placeType, .fileURL])
  }

  required init?(coder: NSCoder) { fatalError("Use init(title:icon:level:pinned:onOpen:)") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }

  private func updateDisclosure() {
    let focused = ExplorerFocus.keyboardVisible && (window?.firstResponder === self || window?.firstResponder === disclosureButton)
    disclosureButton.isHidden = onExpand == nil || !(hovered || focused || expanded)
    disclosureButton.setAccessibilityLabel("\(expanded ? "Collapse" : "Expand") \(text)")
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    disclosureButton.frame = NSRect(x: bounds.minX + 1 + CGFloat(level) * 14, y: bounds.midY - 12, width: 20, height: 24)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; updateDisclosure() }
  override func mouseExited(with event: NSEvent) { hovered = false; updateDisclosure() }
  override func mouseDown(with event: NSEvent) { mousePressed = true; downEvent = event; window?.makeFirstResponder(self) }
  override func mouseDragged(with event: NSEvent) {
    guard let path = placePath, let downEvent,
      hypot(event.locationInWindow.x - downEvent.locationInWindow.x, event.locationInWindow.y - downEvent.locationInWindow.y) >= 4 else { return }
    self.downEvent = nil; mousePressed = false
    let item = NSPasteboardItem(); item.setString(path, forType: Self.placeType)
    let drag = NSDraggingItem(pasteboardWriter: item)
    if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
      cacheDisplay(in: bounds, to: bitmap); let image = NSImage(size: bounds.size); image.addRepresentation(bitmap)
      drag.setDraggingFrame(bounds, contents: image)
    } else { drag.setDraggingFrame(NSRect(x: 24, y: 9, width: 18, height: 18), contents: ExplorerIcons.image(icon)) }
    beginDraggingSession(with: [drag], event: event, source: self)
  }
  override func mouseUp(with event: NSEvent) {
    let shouldOpen = mousePressed && bounds.contains(convert(event.locationInWindow, from: nil))
    mousePressed = false; downEvent = nil
    if shouldOpen { onOpen() }
  }
  override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onOpenTab?() } else { super.otherMouseUp(with: event) } }
  override func menu(for event: NSEvent) -> NSMenu? { onContext?(event); return nil }
  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDragExit?() }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onDragUpdate?(sender, convert(sender.draggingLocation, from: nil).y) ?? [] }
  override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender, convert(sender.draggingLocation, from: nil).y) ?? false }
  override func draggingEnded(_ sender: NSDraggingInfo) { onDragExit?() }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 49, 76: onOpen()
    case 124 where !expanded && onExpand != nil: onExpand?()
    case 123 where expanded && onExpand != nil: onExpand?()
    default: super.keyDown(with: event)
    }
  }
  override func accessibilityPerformPress() -> Bool { onOpen(); return true }
  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    guard onExpand != nil else { return nil }
    return [NSAccessibilityCustomAction(name: expanded ? "Collapse" : "Expand", handler: { [weak self] in
      guard let self, let onExpand = self.onExpand else { return false }
      onExpand()
      return true
    })]
  }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { mousePressed = false; needsDisplay = true; return true }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

  private var defaultTint: NSColor { ExplorerPalette.place(icon) }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if selected || hovered {
        (selected ? ExplorerPalette.active : ExplorerPalette.hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
      }
      if selected {
        ExplorerPalette.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.minX, y: bounds.minY + 10, width: 3, height: 17), xRadius: 1.5, yRadius: 1.5).fill()
      }
      let x = bounds.minX + 24 + CGFloat(level) * 14
      drawExplorerImage(ExplorerIcons.image(icon, color: tint ?? defaultTint), in: NSRect(x: x, y: bounds.midY - 9, width: 18, height: 18))
      drawExplorerText(text, in: NSRect(x: x + 31, y: bounds.minY, width: max(0, bounds.maxX - x - 31 - (pinned ? 38 : 13)), height: bounds.height))
      if pinned {
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext.current?.cgContext {
          context.translateBy(x: bounds.maxX - 19, y: bounds.midY)
          context.rotate(by: 35 * .pi / 180)
          drawExplorerImage(ExplorerIcons.image("pin", size: 12, color: ExplorerPalette.pin), in: NSRect(x: -6, y: -6, width: 12, height: 12))
        }
        NSGraphicsContext.restoreGraphicsState()
      }
      if window?.firstResponder === self && ExplorerFocus.keyboardVisible { drawExplorerFocus(in: bounds) }
    }
  }
}
