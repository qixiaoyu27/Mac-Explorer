import AppKit
import ExplorerCore

struct EDPropertyValues {
  var general: [(String, String)]
  var details: [(String, String)] = []
  var permissions: [(String, String)] = []
}

/// Window-scoped Explorer dialogs. Call on the main thread.
/// Shortcut row names are opaque identifiers: onShortcut returns the supplied first
/// tuple element unchanged, with an Electron-style accelerator (or "" to clear).
enum ExplorerDialogs {
  fileprivate static var presentations: [ObjectIdentifier: EDPresentation] = [:]
  static func close(in window: NSWindow) { presentations[ObjectIdentifier(window)]?.close() }
  static func isPresenting(in window: NSWindow) -> Bool { presentations[ObjectIdentifier(window)] != nil }

  static func name(in window: NSWindow, title: String, value: String, submit: @escaping (String) -> Void) {
    let form = EDNameForm(value: value)
    let dialog = EDPresentation(parent: window, title: title, size: NSSize(width: 430, height: 246), body: form)
    dialog.surface.primary.title = title.hasPrefix(NL("新建")) ? NL("创建") : NL("确定")
    dialog.surface.primary.isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    form.onChange = { [weak dialog] value in
      dialog?.surface.primary.isEnabled = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    dialog.onSubmit = { [weak dialog, weak form] in
      guard let dialog, let value = form?.field.stringValue,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      dialog.close()
      submit(value)
    }
    dialog.present(focus: form.field)
    form.field.selectText(nil)
  }

  static func confirm(in window: NSWindow, title: String, detail: String, confirmTitle: String, remember: ((Bool) -> Void)? = nil, destructive: Bool = false, action: @escaping () -> Void) {
    let body = EDScrollingBody()
    body.flow.padding = 0
    let detailLabel = edLabel(detail, size: 13, wraps: true, selectable: true)
    body.flow.add(detailLabel) { width in edTextHeight(detail, width: width, size: 13) + 12 }
    let checkbox = NSButton(checkboxWithTitle: NL("不再询问"), target: nil, action: nil)
    if remember != nil { body.flow.add(checkbox) { _ in 28 } }
    let height = min(440, max(236, 144 + edTextHeight(detail, width: 380, size: 13) + (remember == nil ? 0 : 32)))
    let dialog = EDPresentation(parent: window, title: title, size: NSSize(width: 430, height: height), body: body)
    dialog.surface.primary.title = confirmTitle
    dialog.onSubmit = { [weak dialog] in
      guard let dialog else { return }
      remember?(checkbox.state == .on)
      dialog.close()
      action()
    }
    dialog.present(focus: destructive ? dialog.surface.cancel : dialog.surface.primary)
  }

  static func properties(in window: NSWindow, title: String, icon: NSImage?, values: [(String, String)], rename: ((String) -> Void)? = nil, load: (() async throws -> EDPropertyValues)? = nil) {
    let body = EDPropertiesBody(title: title, icon: icon, values: values, editable: rename != nil)
    let dialog = EDPresentation(parent: window, title: NL("{0} 属性", title), size: NSSize(width: 490, height: 600), body: body, compact: true, draggable: true)
    if rename != nil { dialog.surface.primary.title = NL("保存"); dialog.surface.primary.isEnabled = false }
    dialog.onSubmit = { [weak dialog, weak body] in
      guard let dialog, let body else { return }
      let value = body.name.stringValue
      dialog.close()
      if value != title { rename?(value) }
    }
    dialog.present(focus: nil)
    if let load {
      let task = Task { @MainActor [weak body, weak dialog] in
        do {
          let values = try await load()
          try Task.checkCancellation()
          guard let dialog else { return }; body?.update(values: values); dialog.surface.primary.isEnabled = true
        } catch is CancellationError {} catch {
          body?.update(values: EDPropertyValues(general: values + [(NL("错误"), error.localizedDescription)]))
        }
      }
      dialog.onClose = { task.cancel() }
    }
  }

  static func settings(
    in window: NSWindow,
    theme: String,
    onTheme: @escaping (String) -> Void,
    toolbar: [String] = ["cut", "copy", "paste", "rename", "share", "trash"],
    onToolbar: (([String]) -> Void)? = nil,
    shortcutRows: [(String, String)] = [],
    onShortcut: ((String, String) -> Void)? = nil,
    shortcutDefaults: [String: String] = [:],
    folderDefaults: [String: String] = [:],
    onFolderDefaults: (([String: String]) -> Void)? = nil,
    onResetFolders: (() -> Void)? = nil,
    browser: BrowserController? = nil,
    initialTab: Int = 0
  ) {
    let body = EDSettingsBody(theme: theme, toolbar: toolbar, shortcutRows: shortcutRows, onTheme: onTheme, onToolbar: onToolbar, onShortcut: onShortcut, shortcutDefaults: shortcutDefaults, folderDefaults: folderDefaults, onFolderDefaults: onFolderDefaults, onResetFolders: onResetFolders)
    let dialog = EDPresentation(parent: window, title: NL("设置"), size: NSSize(width: 560, height: 700), body: body, compact: true, draggable: true)
    dialog.surface.cancel.isHidden = true
    dialog.surface.primary.title = NL("关闭")
    dialog.onSubmit = { [weak dialog] in dialog?.close() }
    body.didChangeTheme = { [weak dialog] mode in
      dialog?.applyAppearance(mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil)
    }
    body.browser = browser
    body.openTab(initialTab)
    dialog.present(focus: body.tabs[max(0, min(3, initialTab))])
  }
}

private enum EDColors {
  static let dialog = dynamic(0xffffff, 0x2b2b2b)
  static let inset = dynamic(0xf5f5f5, 0x252525)
  static let primaryText = dynamic(0xffffff, 0x10202b)
  static let primaryHover = dynamic(0x1975c5, 0x8bd3ff)
  static let primaryPressed = dynamic(0x3686cc, 0x5eb8ef)
  static let error = dynamic(0xad2626, 0xffaaaa)
  static let dim = NSColor(name: nil) { appearance in
    NSColor.black.withAlphaComponent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 136.0 / 255 : 38.0 / 255)
  }

  private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
  }
}

private func edLabel(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, wraps: Bool = false, selectable: Bool = false) -> NSTextField {
  let label = ExplorerTextField(labelWithString: text)
  label.font = .systemFont(ofSize: size, weight: weight)
  label.textColor = ExplorerPalette.text
  label.isSelectable = selectable
  label.lineBreakMode = wraps ? .byCharWrapping : .byTruncatingTail
  label.maximumNumberOfLines = wraps ? 0 : 1
  label.cell?.wraps = wraps
  label.cell?.usesSingleLineMode = !wraps
  return label
}

private func edTextHeight(_ text: String, width: CGFloat, size: CGFloat = 12) -> CGFloat {
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineBreakMode = .byCharWrapping
  let rect = (text as NSString).boundingRect(with: NSSize(width: max(1, width), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph])
  return max(18, ceil(rect.height) + 2)
}

private func edDrawText(_ text: String, in rect: NSRect, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = ExplorerPalette.text, alignment: NSTextAlignment = .left) {
  guard rect.width > 0 else { return }
  NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
  let font = NSFont.systemFont(ofSize: size, weight: weight)
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineBreakMode = .byTruncatingTail
  paragraph.alignment = alignment
  let height = ceil(font.ascender - font.descender)
  (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}

private func edBorder(_ rect: NSRect, color: NSColor = ExplorerPalette.border, radius: CGFloat = 4, width: CGFloat = 1) {
  color.setStroke()
  let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
  path.lineWidth = width
  path.stroke()
}

class EDView: NSView {
  override var isFlipped: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class EDPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class EDDimPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class EDDimView: EDView {
  override func draw(_ dirtyRect: NSRect) { EDColors.dim.setFill(); bounds.fill() }
  override func mouseDown(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}

/// Retained by ExplorerDialogs until every dismissal path tears down observers,
/// the local event monitor, both child windows, and restores the original focus.
fileprivate final class EDPresentation {
  private weak var parent: NSWindow?
  private weak var previousResponder: NSResponder?
  private let parentID: ObjectIdentifier
  private let desiredSize: NSSize
  private let panel: EDPanel
  private let dim: EDDimPanel
  fileprivate let surface: EDSurface
  fileprivate var onSubmit: (() -> Void)?
  fileprivate var onClose: (() -> Void)?
  private var observers: [NSObjectProtocol] = []
  private var monitor: Any?
  private var isClosed = false
  private var hasMoved = false
  private var offset = NSPoint.zero

  init(parent: NSWindow, title: String, size: NSSize, body: NSView, compact: Bool = false, draggable: Bool = false) {
    self.parent = parent
    parentID = ObjectIdentifier(parent)
    desiredSize = size
    surface = EDSurface(title: title, body: body, compact: compact, draggable: draggable)
    panel = EDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    dim = EDDimPanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    for child in [panel as NSPanel, dim as NSPanel] {
      child.isReleasedWhenClosed = false
      child.isOpaque = false
      child.backgroundColor = .clear
      child.hidesOnDeactivate = false
      child.isFloatingPanel = false
      child.collectionBehavior = [.fullScreenAuxiliary]
      child.level = parent.level
      child.appearance = parent.effectiveAppearance
    }
    dim.hasShadow = false
    dim.contentView = EDDimView()
    panel.hasShadow = true
    panel.contentView = surface
    panel.title = title
    panel.setAccessibilitySubrole(.dialog)
    panel.setAccessibilityModal(true)
    dim.setAccessibilityElement(false)
    panel.autorecalculatesKeyViewLoop = true
    surface.onCancel = { [weak self] in self?.close() }
    surface.onSubmit = { [weak self] in self?.submit() }
    surface.header.onMove = { [weak self] delta in self?.move(by: delta) }
  }

  fileprivate func present(focus: NSView?) {
    precondition(Thread.isMainThread)
    guard let parent else { return }
    ExplorerDialogs.presentations[parentID]?.close(restoreFocus: false)
    previousResponder = parent.firstResponder
    ExplorerDialogs.presentations[parentID] = self
    parent.addChildWindow(dim, ordered: .above)
    dim.addChildWindow(panel, ordered: .above)
    position()
    for notification in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification, NSWindow.didEndLiveResizeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: notification, object: parent, queue: .main) { [weak self] _ in self?.position() })
    }
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in self?.close(restoreFocus: false) })
    observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willMiniaturizeNotification, object: parent, queue: .main) { [weak self] _ in self?.close(restoreFocus: false) })
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]) { [weak self] event in
      guard let self, !self.isClosed else { return event }
      if event.window === self.parent { return nil }
      guard event.window === self.panel || (event.window == nil && self.panel.isKeyWindow) else { return event }
      guard event.type == .keyDown else { return event }
      if let recorder = self.panel.firstResponder as? EDShortcutRecorder {
        recorder.keyDown(with: event)
        return nil
      }
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      if modifiers.isEmpty && event.keyCode == 53 {
        if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        self.close()
        return nil
      }
      if modifiers.isEmpty && [36, 76].contains(event.keyCode) {
        if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        if let button = self.panel.firstResponder as? NSButton { button.performClick(nil) }
        else { self.submit() }
        return nil
      }
      if modifiers.contains(.command) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "q" && modifiers == .command { return event }
        if key == "w" && modifiers == .command { self.close(); return nil }
        // Keep text editing native, but never dispatch an Explorer/menu command
        // behind the modal (including shortcuts such as Command+Delete).
        if self.panel.firstResponder is NSTextView,
           modifiers.subtracting([.command, .shift]).isEmpty,
           ["a", "c", "x", "v", "z"].contains(key) { return event }
        return nil
      }
      return event
    }
    dim.orderFront(nil)
    panel.makeKeyAndOrderFront(nil)
    surface.layoutSubtreeIfNeeded()
    panel.recalculateKeyViewLoop()
    if let focus { panel.makeFirstResponder(focus) }
  }

  fileprivate func applyAppearance(_ appearance: NSAppearance?) {
    panel.appearance = appearance
    dim.appearance = appearance
  }

  private func viewport() -> NSRect? {
    guard let parent, let content = parent.contentView else { return nil }
    return parent.convertToScreen(content.convert(content.bounds, to: nil))
  }

  private func position() {
    guard let viewport = viewport(), viewport.width > 0, viewport.height > 0 else { return }
    dim.setFrame(viewport, display: true)
    let inset = min(24, min(viewport.width, viewport.height) / 8)
    let available = viewport.insetBy(dx: inset, dy: inset)
    let size = NSSize(width: min(desiredSize.width, available.width), height: min(desiredSize.height, available.height))
    let centered = NSPoint(x: viewport.midX - size.width / 2, y: viewport.midY - size.height / 2)
    var origin = NSPoint(x: centered.x + (hasMoved ? offset.x : 0), y: centered.y + (hasMoved ? offset.y : 0))
    origin.x = max(available.minX, min(origin.x, available.maxX - size.width))
    origin.y = max(available.minY, min(origin.y, available.maxY - size.height))
    offset = NSPoint(x: origin.x - centered.x, y: origin.y - centered.y)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    surface.needsLayout = true
    surface.layoutSubtreeIfNeeded()
  }

  private func move(by delta: NSPoint) {
    hasMoved = true
    offset.x += delta.x
    offset.y += delta.y
    position()
  }

  private func submit() {
    guard !isClosed, surface.primary.isEnabled else { return }
    onSubmit?()
  }

  fileprivate func close(restoreFocus: Bool = true) {
    guard !isClosed else { return }
    isClosed = true
    onClose?(); onClose = nil
    ExplorerMenu.dismiss()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    dim.removeChildWindow(panel)
    parent?.removeChildWindow(dim)
    panel.orderOut(nil)
    dim.orderOut(nil)
    panel.close()
    dim.close()
    if ExplorerDialogs.presentations[parentID] === self { ExplorerDialogs.presentations.removeValue(forKey: parentID) }
    if restoreFocus, let parent, parent.isVisible {
      parent.makeKeyAndOrderFront(nil)
      if let view = previousResponder as? NSView, view.window === parent { parent.makeFirstResponder(view) }
      else if let responder = previousResponder, !(responder is NSView) { parent.makeFirstResponder(responder) }
      else { parent.makeFirstResponder(parent.contentView) }
    }
  }
}

fileprivate final class EDSurface: EDView {
  let header: EDTitleBar
  let primary = EDButton(title: NL("确定"), style: .primary)
  let cancel = EDButton(title: NL("取消"), style: .secondary)
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?
  private let body: NSView
  private let compact: Bool

  init(title: String, body: NSView, compact: Bool, draggable: Bool) {
    self.body = body
    self.compact = compact
    header = EDTitleBar(title: title, compact: compact, draggable: draggable)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.masksToBounds = true
    addSubview(header)
    addSubview(body)
    addSubview(primary)
    addSubview(cancel)
    primary.onPress = { [weak self] in self?.onSubmit?() }
    cancel.onPress = { [weak self] in self?.onCancel?() }
    header.close.onPress = { [weak self] in self?.onCancel?() }
    setAccessibilityElement(false)
    setAccessibilityRole(.group)
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  override func layout() {
    super.layout()
    let footer: CGFloat = compact ? 58 : 68
    let heading: CGFloat = compact ? (header.isSettings || header.isProperties ? 56 : 42) : 71
    let margin: CGFloat = compact ? 18 : 25
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: heading)
    body.frame = NSRect(x: margin, y: heading, width: max(1, bounds.width - margin * 2), height: max(1, bounds.height - heading - footer))
    let width = primary.intrinsicContentSize.width
    primary.frame = NSRect(x: max(margin, bounds.width - margin - width), y: bounds.height - footer + (footer - 34) / 2, width: width, height: 34)
    cancel.frame = NSRect(x: max(0, primary.frame.minX - 96), y: primary.frame.minY, width: 87, height: 34)
    body.needsLayout = true
  }

  override func draw(_ dirtyRect: NSRect) {
    EDColors.dialog.setFill()
    bounds.fill()
    if !compact || header.isProperties {
      let footer = NSRect(x: 0, y: bounds.height - (compact ? 58 : 68), width: bounds.width, height: compact ? 58 : 68)
      EDColors.inset.setFill()
      footer.fill()
      ExplorerPalette.border.setFill()
      NSRect(x: 0, y: footer.minY, width: bounds.width, height: 1).fill()
    }
  }
}

private final class EDTitleBar: EDView {
  let close = ExplorerButton(icon: "close")
  var onMove: ((NSPoint) -> Void)?
  private let text: String
  var isSettings: Bool { text == NL("设置") }
  var isProperties: Bool { text.hasSuffix(NL(" 属性")) }
  private let compact: Bool
  private let draggable: Bool
  private var lastMouse: NSPoint?

  init(title: String, compact: Bool, draggable: Bool) {
    text = title
    self.compact = compact
    self.draggable = draggable
    super.init(frame: .zero)
    addSubview(close)
    close.setAccessibilityLabel(NL("关闭"))
    setAccessibilityLabel(title)
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override var acceptsFirstResponder: Bool { draggable }
  override func layout() {
    super.layout()
    close.frame = NSRect(x: bounds.width - (compact ? 44 : 51), y: compact ? (bounds.height - 26) / 2 : 22, width: 26, height: 26)
  }
  override func draw(_ dirtyRect: NSRect) {
    let x: CGFloat = isSettings ? 45 : compact ? 18 : 25
    if isSettings { ExplorerIcons.image("settings", size: 18).draw(in: NSRect(x: 18, y: bounds.midY - 9, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    edDrawText(text, in: NSRect(x: x, y: compact ? 0 : 22, width: max(0, bounds.width - x - 60), height: compact ? bounds.height : 26), size: compact ? 15 : 18, weight: .semibold)
    if window?.firstResponder === self && ExplorerFocus.keyboardVisible { edBorder(bounds.insetBy(dx: 3, dy: 3), color: ExplorerPalette.accent, width: 2) }
  }
  override func mouseDown(with event: NSEvent) {
    guard draggable else { return }
    window?.makeFirstResponder(self)
    lastMouse = NSEvent.mouseLocation
  }
  override func mouseDragged(with event: NSEvent) {
    guard let lastMouse else { return }
    let point = NSEvent.mouseLocation
    onMove?(NSPoint(x: point.x - lastMouse.x, y: point.y - lastMouse.y))
    self.lastMouse = point
  }
  override func mouseUp(with event: NSEvent) { lastMouse = nil }
  override func keyDown(with event: NSEvent) {
    let delta: [UInt16: NSPoint] = [123: NSPoint(x: -10, y: 0), 124: NSPoint(x: 10, y: 0), 125: NSPoint(x: 0, y: -10), 126: NSPoint(x: 0, y: 10)]
    if let movement = delta[event.keyCode], draggable { onMove?(movement) }
    else { super.keyDown(with: event) }
  }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { lastMouse = nil; needsDisplay = true; return true }
}

final class EDButton: NSButton {
  enum Style { case primary, secondary, tab, checkbox, radio }
  var style: Style { didSet { needsDisplay = true } }
  var checked = false { didSet { setAccessibilityValue(checked ? 1 : 0); needsDisplay = true } }
  var onPress: (() -> Void)?
  var onNavigate: ((UInt16) -> Void)?
  var iconName: String?
  var labelSize: CGFloat = 12
  var readOnly = false
  private var hovered = false
  private var area: NSTrackingArea?

  init(title: String, style: Style) {
    self.style = style
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    setButtonType(.momentaryPushIn)
    font = .systemFont(ofSize: 12)
    focusRingType = .none
    target = self
    action = #selector(press)
    if style == .radio { setAccessibilityRole(.radioButton) }
    if style == .checkbox { setAccessibilityRole(.checkBox) }
    if style == .tab { setAccessibilityRole(.radioButton) }
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { isEnabled }
  override var mouseDownCanMoveWindow: Bool { false }
  override var intrinsicContentSize: NSSize {
    NSSize(width: max(style == .tab ? 80 : 87, ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 36), height: 34)
  }
  @objc private func press() { if !readOnly { onPress?() } }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(next)
    area = next
  }
  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
  override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
  override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
  override func keyDown(with event: NSEvent) {
    if [123, 124, 115, 119].contains(event.keyCode), let onNavigate { onNavigate(event.keyCode) }
    else if [36, 76].contains(event.keyCode) { performClick(nil) }
    else { super.keyDown(with: event) }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
    let pressed = cell?.isHighlighted == true
    if style == .radio || style == .checkbox {
      let mark = NSRect(x: 0, y: bounds.midY - 7.5, width: 15, height: 15)
      let shape = NSBezierPath(roundedRect: mark, xRadius: style == .radio ? 7.5 : 3, yRadius: style == .radio ? 7.5 : 3)
      (checked ? ExplorerPalette.accent : ExplorerPalette.surface).setFill()
      shape.fill()
      edBorder(mark, color: checked ? ExplorerPalette.accent : ExplorerPalette.secondary, radius: style == .radio ? 7.5 : 3)
      if checked {
        if style == .radio {
          EDColors.primaryText.setFill()
          NSBezierPath(ovalIn: mark.insetBy(dx: 4.5, dy: 4.5)).fill()
        } else {
          ExplorerIcons.image("check", size: 12, color: EDColors.primaryText).draw(in: mark.insetBy(dx: 1.5, dy: 1.5), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
      }
      if let iconName { ExplorerIcons.image(iconName, size: 17).draw(in: NSRect(x: 22, y: bounds.midY - 8.5, width: 17, height: 17), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
      let textX: CGFloat = iconName == nil ? 24 : 46
      edDrawText(title, in: NSRect(x: textX, y: 0, width: max(0, bounds.width - textX), height: bounds.height), size: labelSize)
    } else {
      let background: NSColor
      switch style {
      case .primary: background = pressed ? EDColors.primaryPressed : hovered ? EDColors.primaryHover : ExplorerPalette.accent
      case .tab: background = checked ? EDColors.dialog : hovered ? ExplorerPalette.hover : .clear
      default: background = ExplorerPalette.surface
      }
      background.setFill()
      NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
      if style == .secondary && (hovered || pressed) {
        (pressed ? ExplorerPalette.pressed : ExplorerPalette.hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
      }
      if style != .tab || checked { edBorder(bounds, color: style == .primary ? ExplorerPalette.accent : ExplorerPalette.border) }
      if style == .tab && checked {
        EDColors.dialog.setFill()
        NSRect(x: 1, y: bounds.height - 4, width: bounds.width - 2, height: 4).fill()
      }
      let color = style == .primary ? EDColors.primaryText : ExplorerPalette.text
      var textRect = bounds.insetBy(dx: 8, dy: 0)
      if let iconName {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        let left = max(8, (bounds.width - textWidth - 22) / 2)
        ExplorerIcons.image(iconName, size: 16, color: color).draw(in: NSRect(x: left, y: bounds.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        textRect = NSRect(x: left + 22, y: 0, width: max(0, bounds.width - left - 30), height: bounds.height)
      }
      edDrawText(title, in: textRect, weight: style == .tab && checked ? .semibold : .regular, color: color, alignment: iconName == nil ? .center : .left)
    }
    if window?.firstResponder === self && ExplorerFocus.keyboardVisible { edBorder(bounds.insetBy(dx: 2, dy: 2), color: ExplorerPalette.accent, width: 2) }
  }
}

private final class EDNameForm: EDView, NSTextFieldDelegate {
  let field = ExplorerTextField()
  var onChange: ((String) -> Void)?
  private let label = edLabel(NL("名称"))
  private var editing = false
  init(value: String) {
    super.init(frame: .zero)
    field.stringValue = value
    field.font = .systemFont(ofSize: 13)
    field.textColor = ExplorerPalette.text
    field.isBezeled = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.setAccessibilityLabel(NL("名称"))
    addSubview(label)
    addSubview(field)
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override func layout() {
    super.layout()
    label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
    field.frame = NSRect(x: 10, y: 35, width: max(1, bounds.width - 20), height: 20)
  }
  override func draw(_ dirtyRect: NSRect) {
    let input = NSRect(x: 0, y: 27, width: bounds.width, height: 35)
    ExplorerPalette.surface.setFill()
    NSBezierPath(roundedRect: input, xRadius: 4, yRadius: 4).fill()
    edBorder(input)
    if editing {
      ExplorerPalette.accent.setFill()
      NSRect(x: 2, y: input.maxY - 2, width: max(0, input.width - 4), height: 2).fill()
    }
  }
  func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
  func controlTextDidBeginEditing(_ obj: Notification) { editing = true; needsDisplay = true }
  func controlTextDidEndEditing(_ obj: Notification) { editing = false; needsDisplay = true }
}

private final class EDFlow: EDView {
  var padding: CGFloat = 20
  var gap: CGFloat = 16
  private var rows: [(NSView, (CGFloat) -> CGFloat)] = []
  func add(_ view: NSView, height: @escaping (CGFloat) -> CGFloat) {
    rows.append((view, height))
    addSubview(view)
  }
  func clear() {
    rows.forEach { $0.0.removeFromSuperview() }
    rows.removeAll()
  }
  func reflow(width: CGFloat, minimumHeight: CGFloat) {
    let inner = max(1, width - padding * 2)
    var y = padding
    for (view, height) in rows {
      let h = height(inner)
      view.frame = NSRect(x: padding, y: y, width: inner, height: h)
      view.needsLayout = true
      y += h + gap
    }
    frame.size = NSSize(width: width, height: max(minimumHeight, y - (rows.isEmpty ? 0 : gap) + padding))
  }
}

private class EDScrollingBody: EDView {
  let scroll = NSScrollView()
  let flow = EDFlow()
  var bordered = false
  override init(frame: NSRect = .zero) {
    super.init(frame: frame)
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.documentView = flow
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override func layout() {
    super.layout()
    scroll.frame = bounds.insetBy(dx: bordered ? 1 : 0, dy: bordered ? 1 : 0)
    flow.reflow(width: scroll.contentSize.width, minimumHeight: scroll.contentSize.height)
  }
  override func draw(_ dirtyRect: NSRect) { if bordered { edBorder(bounds, radius: 0) } }
}

private final class EDMetadataRow: EDView {
  private let key: NSTextField
  private let value: NSTextField
  private let valueText: String
  private let keyWidth: CGFloat
  init(_ pair: (String, String), keyWidth: CGFloat = 110) {
    self.keyWidth = keyWidth
    key = edLabel(pair.0)
    key.textColor = ExplorerPalette.secondary
    value = edLabel(pair.1, wraps: true, selectable: true)
    valueText = pair.1
    super.init(frame: .zero)
    addSubview(key)
    addSubview(value)
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  func height(for width: CGFloat) -> CGFloat {
    width < 250 ? 24 + edTextHeight(valueText, width: width) : max(24, edTextHeight(valueText, width: width - keyWidth - 14))
  }
  override func layout() {
    super.layout()
    let stacked = bounds.width < 250
    key.frame = NSRect(x: 0, y: 0, width: stacked ? bounds.width : keyWidth, height: 20)
    value.frame = NSRect(x: stacked ? 0 : keyWidth + 14, y: stacked ? 24 : 0, width: max(1, bounds.width - (stacked ? 0 : keyWidth + 14)), height: bounds.height - (stacked ? 24 : 0))
  }
}

private final class EDPropertyIdentity: EDView {
  private let image = NSImageView()
  let name = ExplorerTextField()
  init(title: String, icon: NSImage?, editable: Bool = false) {
    super.init(frame: .zero)
    image.image = icon; image.imageScaling = .scaleProportionallyUpOrDown
    name.stringValue = title; name.isEditable = editable; name.isSelectable = true; name.identifier = .init("property-name"); name.setAccessibilityLabel(NL("名称")); name.isBordered = false; name.drawsBackground = false; name.font = .systemFont(ofSize: 13); name.textColor = ExplorerPalette.text
    addSubview(image); addSubview(name)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() { super.layout(); image.frame = NSRect(x: 0, y: 0, width: 42, height: 42); name.frame = NSRect(x: 70, y: 10, width: max(0, bounds.width - 80), height: 22) }
  override func draw(_ dirtyRect: NSRect) { edBorder(NSRect(x: 60, y: 4, width: max(0, bounds.width - 60), height: 34)); ExplorerPalette.border.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
}
private final class EDPropertyAttribute: EDView {
  private let label = edLabel(NL("属性")), toggle: EDButton
  init(title: String, value: String, first: Bool) {
    toggle = EDButton(title: title, style: .checkbox); toggle.checked = value == NL("是"); toggle.readOnly = true
    super.init(frame: .zero); label.isHidden = !first; label.textColor = ExplorerPalette.secondary; addSubview(label); addSubview(toggle)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() { super.layout(); label.frame = NSRect(x: 0, y: 4, width: 72, height: 20); toggle.frame = NSRect(x: 86, y: 0, width: max(0, bounds.width - 86), height: 26) }
}
private final class EDPropertiesBody: EDView {
  private let tabs = [NL("常规"), NL("详细信息"), NL("权限")].map { EDButton(title: $0, style: .tab) }
  private let content = EDScrollingBody()
  private let identity: EDPropertyIdentity
  private var values: EDPropertyValues
  private var section = 0
  var name: ExplorerTextField { identity.name }
  init(title: String, icon: NSImage?, values: [(String, String)], editable: Bool) {
    identity = EDPropertyIdentity(title: title, icon: icon, editable: editable)
    self.values = EDPropertyValues(general: values)
    super.init(frame: .zero); content.bordered = true; addSubview(content)
    tabs[2].toolTip = NL("权限由文件系统或服务器提供；共享访问控制由服务器决定。")
    for (index, tab) in tabs.enumerated() {
      addSubview(tab); tab.onPress = { [weak self] in self?.select(index) }
      tab.onNavigate = { [weak self] key in
        guard let self else { return }
        let next = key == 115 ? 0 : key == 119 ? 2 : (index + (key == 124 ? 1 : 2)) % 3
        self.select(next); self.window?.makeFirstResponder(self.tabs[next])
      }
    }
    select(0)
  }
  private func select(_ index: Int) {
    window?.makeFirstResponder(tabs[index]); section = index
    for (i, tab) in tabs.enumerated() { tab.checked = i == index }
    render()
  }
  func update(values: EDPropertyValues) { self.values = values; render() }
  private func render() {
    content.flow.clear(); content.flow.padding = 19; content.flow.gap = 13
    if section == 0 { content.flow.add(identity) { _ in 61 } }
    let rows = section == 0 ? values.general : section == 1 ? values.details : values.permissions
    var attributes = false
    for pair in rows {
      if pair.0 == NL("只读") || pair.0 == NL("隐藏") {
        let row = EDPropertyAttribute(title: pair.0, value: pair.1, first: !attributes); attributes = true
        content.flow.add(row) { _ in 26 }
      } else {
        let row = EDMetadataRow(pair, keyWidth: 85)
        content.flow.add(row) { [weak row] width in row?.height(for: width) ?? 24 }
      }
      if section == 0 && (pair.0 == NL("占用空间") || pair.0 == NL("修改日期")) {
        let separator = SurfaceView(); separator.color = ExplorerPalette.border
        content.flow.add(separator) { _ in 1 }
      }
    }
    content.scroll.contentView.scroll(to: .zero)
    content.needsLayout = true; needsLayout = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout(); var x: CGFloat = 0
    for tab in tabs { let width = max(68, tab.intrinsicContentSize.width); tab.frame = NSRect(x: x, y: 0, width: width, height: 34); x += width }
    content.frame = NSRect(x: 0, y: 33, width: bounds.width, height: max(1, bounds.height - 51)); content.needsLayout = true
  }
}

private final class EDGroup: EDView {
  let content = EDView()
  private let title: String
  var arrange: ((NSRect) -> Void)?
  init(_ title: String) {
    self.title = title
    super.init(frame: .zero)
    addSubview(content)
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override func layout() {
    super.layout()
    content.frame = NSRect(x: 0, y: 26, width: bounds.width, height: max(1, bounds.height - 26))
    arrange?(content.bounds)
  }
  override func draw(_ dirtyRect: NSRect) {
    let width = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
    edDrawText(title, in: NSRect(x: 0, y: 0, width: width, height: 18), weight: .semibold)
    ExplorerPalette.border.setFill()
    NSRect(x: width + 12, y: 9, width: max(0, bounds.width - width - 12), height: 1).fill()
  }
}

private final class EDSettingsBody: EDView {
  weak var browser: BrowserController?
  let tabs: [EDButton] = [NL("常规"), NL("自定义工具栏"), NL("键盘快捷键"), NL("关于")].map { EDButton(title: $0, style: .tab) }
  var didChangeTheme: ((String) -> Void)?
  private let content = EDScrollingBody()
  private var section = 0
  private var resetScroll = true
  private var theme: String
  private var toolbar: [String]
  private let onTheme: (String) -> Void
  private let onToolbar: (([String]) -> Void)?
  private let onShortcut: ((String, String) -> Void)?
  private let shortcutRows: [(String, String)]
  private let shortcutDefaults: [String: String]
  private var folderDefaults: [String: String]
  private let onFolderDefaults: (([String: String]) -> Void)?
  private let onResetFolders: (() -> Void)?
  private var shortcutValues: [String]
  private var savedShortcuts: [String]
  private var shortcutError: NSTextField?
  private var shortcutSave: EDButton?
  private var shortcutReset: EDButton?
  private let allTools = ["cut", "copy", "paste", "rename", "share", "trash", "airdrop", "terminal", "undo", "refresh"]
  private let toolLabels = ["cut": NL("剪切"), "copy": NL("复制"), "paste": NL("粘贴"), "rename": NL("重命名"), "share": NL("共享"), "trash": NL("移到回收站"), "airdrop": NL("隔空投送"), "terminal": NL("在终端中打开"), "undo": NL("撤销"), "refresh": NL("刷新")]

  init(theme: String, toolbar: [String], shortcutRows: [(String, String)], onTheme: @escaping (String) -> Void, onToolbar: (([String]) -> Void)?, onShortcut: ((String, String) -> Void)?, shortcutDefaults: [String: String], folderDefaults: [String: String], onFolderDefaults: (([String: String]) -> Void)?, onResetFolders: (() -> Void)?) {
    self.theme = theme
    self.shortcutDefaults = shortcutDefaults; self.folderDefaults = folderDefaults; self.onFolderDefaults = onFolderDefaults; self.onResetFolders = onResetFolders
    var seen = Set<String>()
    self.toolbar = toolbar.filter { seen.insert($0).inserted }
    self.shortcutRows = shortcutRows
    shortcutValues = shortcutRows.map { $0.1 }
    savedShortcuts = shortcutValues
    self.onTheme = onTheme
    self.onToolbar = onToolbar
    self.onShortcut = onShortcut
    super.init(frame: .zero)
    content.bordered = true
    addSubview(content)
    for (index, tab) in tabs.enumerated() {
      addSubview(tab)
      tab.onPress = { [weak self] in self?.select(index) }
      tab.onNavigate = { [weak self] key in
        guard let self else { return }
        let next = key == 115 ? 0 : key == 119 ? 3 : (index + (key == 124 ? 1 : 3)) % 4
        self.select(next)
        self.window?.makeFirstResponder(self.tabs[next])
      }
    }
    select(0)
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override func layout() {
    super.layout()
    let desired = tabs.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
    let scale = min(1, bounds.width / max(1, desired))
    var x: CGFloat = 0
    for tab in tabs {
      let width = tab.intrinsicContentSize.width * scale
      tab.frame = NSRect(x: x, y: 0, width: width, height: 34)
      x += width
    }
    content.frame = NSRect(x: 0, y: 33, width: bounds.width, height: max(1, bounds.height - 33))
    content.needsLayout = true
    if resetScroll {
      content.layoutSubtreeIfNeeded()
      content.scroll.contentView.scroll(to: .zero)
      content.scroll.reflectScrolledClipView(content.scroll.contentView)
      resetScroll = false
    }
  }
  func openTab(_ index: Int) { select(max(0, min(3, index))) }
  private func select(_ index: Int) {
    section = index
    resetScroll = true
    tabs.enumerated().forEach { $0.element.checked = $0.offset == index }
    content.flow.clear()
    content.flow.gap = 16
    shortcutError = nil
    shortcutSave = nil; shortcutReset = nil
    switch index {
    case 0: general()
    case 1: toolbarContent()
    case 2: shortcuts()
    default: about()
    }
    content.scroll.contentView.scroll(to: .zero)
    content.scroll.reflectScrolledClipView(content.scroll.contentView)
    needsLayout = true
    content.needsLayout = true
  }
  private func general() {
    content.flow.gap = 20
    let group = EDGroup(NL("外观"))
    let options = [("light", NL("浅色")), ("dark", NL("深色")), ("system", NL("跟随系统"))]
    let buttons = options.map { mode, label -> EDButton in
      let button = EDButton(title: label, style: .radio)
      button.iconName = mode == "light" ? "sun" : mode == "dark" ? "moon" : "computer"; button.labelSize = 13
      button.checked = mode == theme
      group.content.addSubview(button)
      button.onPress = { [weak self] in
        guard let self else { return }
        self.theme = mode
        self.onTheme(mode)
        self.didChangeTheme?(mode)
        self.select(0)
        self.window?.makeFirstResponder(self.tabs[0])
      }
      return button
    }
    let arrangeAppearance: (CGFloat) -> CGFloat = { width in
      var x: CGFloat = 0, y: CGFloat = 0
      for button in buttons {
        let itemWidth = ceil((button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 46
        if x > 0 && x + itemWidth > width { x = 0; y += 34 }
        button.frame = NSRect(x: x, y: y, width: min(width, itemWidth), height: 28)
        x += itemWidth + 18
      }
      return y + 28
    }
    group.arrange = { _ = arrangeAppearance($0.width) }
    content.flow.add(group) { 26 + arrangeAppearance($0) }
    if let browser {
      let startup = EDGroup(NL("启动位置"))
      let destination = EDChoiceRow(title: NL("默认打开"), options: [(NL("此电脑"), "computer"), (NL("个人文件夹"), "home")], value: NativeStartLocation.load(browser.defaults).rawValue) { [weak browser] value in
        guard let location = NativeStartLocation(rawValue: value) else { return }
        browser?.defaults.set(location.rawValue, forKey: NativeStartLocation.preferenceKey)
      }
      let restore = EDButton(title: NL("退出后恢复窗口和标签页"), style: .checkbox)
      restore.checked = browser.defaults.object(forKey: NativeSessions.restoreAfterQuitKey) as? Bool ?? false
      restore.onPress = { [weak restore, weak browser] in
        guard let restore else { return }; restore.checked.toggle()
        browser?.defaults.set(restore.checked, forKey: NativeSessions.restoreAfterQuitKey)
      }
      startup.content.addSubview(destination); startup.content.addSubview(restore)
      startup.arrange = { rect in
        destination.frame = NSRect(x: 0, y: 0, width: rect.width, height: 32)
        restore.frame = NSRect(x: 0, y: 40, width: rect.width, height: 28)
      }
      content.flow.add(startup) { _ in 94 }
    }
    let language = EDGroup(NL("语言"))
    let row = EDChoiceRow(title: NL("界面语言"), options: [(NL("跟随系统"), "system"), ("简体中文", "zh-CN"), ("繁體中文", "zh-TW"), ("English", "en")], value: browser?.defaults.string(forKey: "language") ?? "system") { [weak self] in self?.browser?.changeLanguage($0) }
    language.content.addSubview(row)
    language.arrange = { rect in row.frame = rect }
    content.flow.add(language) { _ in 58 }
    if let browser {
      let terminal = EDGroup(NL("终端"))
      let selected = browser.defaults.string(forKey: NativeTerminal.preferenceKey) ?? ""
      let application = EDChoiceRow(title: NL("终端应用"), options: NativeTerminal.options(selected: selected), value: selected) { [weak browser] in browser?.defaults.set($0, forKey: NativeTerminal.preferenceKey) }
      terminal.content.addSubview(application); terminal.arrange = { application.frame = $0 }
      content.flow.add(terminal) { _ in 58 }
      let search = EDGroup(NL("文件搜索"))
      let mode = EDChoiceRow(title: NL("搜索模式"), options: [(NL("普通文本"), "text"), (NL("通配符"), "wildcard"), (NL("正则表达式"), "regex")], value: FileSearchMode(rawValue: browser.defaults.string(forKey: "searchMode") ?? "")?.rawValue ?? "text") { [weak browser] in browser?.defaults.set($0, forKey: "searchMode") }
      search.content.addSubview(mode); search.arrange = { mode.frame = $0 }
      content.flow.add(search) { _ in 58 }
      let serverTransfer = EDGroup(NL("网络传输"))
      let offload = EDButton(title: NL("启用同服务器跨共享传输优化"), style: .checkbox)
      offload.checked = browser.defaults.object(forKey: "serverSideTransfer") as? Bool ?? true
      offload.onPress = { [weak offload, weak browser] in
        guard let offload else { return }; offload.checked.toggle(); browser?.defaults.set(offload.checked, forKey: "serverSideTransfer")
      }
      let forget = EDButton(title: NL("清除服务端传输登录信息"), style: .secondary)
      forget.onPress = { [weak browser] in
        guard let window = browser?.view.window else { return }
        let alert = NSAlert(); alert.messageText = NL("清除服务端传输登录信息？")
        alert.addButton(withTitle: NL("清除")); alert.addButton(withTitle: NL("取消"))
        alert.beginSheetModal(for: window) { response in
          guard response == .alertFirstButtonReturn else { return }
          let code = NativeSMBAccounts.shared.forgetAll()
          if code != 0 {
            let failure = NSAlert(); failure.messageText = NL("无法清除登录信息"); failure.informativeText = NL("钥匙串错误码：{0}", String(code)); failure.beginSheetModal(for: window)
          }
        }
      }
      serverTransfer.content.addSubview(offload); serverTransfer.content.addSubview(forget)
      serverTransfer.arrange = { rect in
        offload.frame = NSRect(x: 0, y: 0, width: rect.width, height: 28)
        forget.frame = NSRect(x: 0, y: 34, width: 240, height: 34)
      }
      content.flow.add(serverTransfer) { _ in 94 }
      let favorites = EDGroup(NL("快速访问")), extra = NativeSettingsView(browser: browser)
      favorites.content.addSubview(extra); favorites.arrange = { extra.frame = $0 }
      extra.onHeightChange = { [weak self] in self?.content.needsLayout = true }
      content.flow.add(favorites) { _ in extra.preferredHeight + 26 }
      if let integration = browser.systemIntegration {
        let group = EDGroup(NL("系统文件查看器（实验）")), system = NativeSystemSettingsView(integration: integration)
        group.content.addSubview(system); group.arrange = { system.frame = $0 }
        system.onHeightChange = { [weak self] in self?.content.needsLayout = true }
        content.flow.add(group) { _ in system.preferredHeight + 26 }
      }
      let vcs = EDGroup(NL("版本控制"))
      let toggle = EDButton(title: NL("启用 Git / SVN 状态角标和右键菜单"), style: .checkbox)
      toggle.checked = browser.defaults.object(forKey: "versionControl") as? Bool ?? true
      toggle.onPress = { [weak toggle, weak browser] in if let toggle { toggle.checked.toggle(); browser?.setVersionControl(toggle.checked) } }
      let help = NativeHelpButton(text: NL("仅在仓库内启用。关闭后停止状态检测与刷新；需要已安装 Git 或 SVN 命令行工具。"), accessibilityLabel: NL("版本控制说明"))
      vcs.content.addSubview(toggle); vcs.content.addSubview(help)
      vcs.arrange = { rect in toggle.frame = NSRect(x: 0, y: 0, width: rect.width - 30, height: 28); help.frame = NSRect(x: rect.width - 24, y: 0, width: 24, height: 28) }
      content.flow.add(vcs) { _ in 54 }
    }
    if onFolderDefaults != nil {
      let group = EDGroup(NL("文件夹视图"))
      var layouts = [(NL("超大图标"), "icons:128"), (NL("大图标"), "icons:64"), (NL("中图标"), "icons:48"), (NL("小图标"), "icons:32"), (NL("列表"), "list"), (NL("详细信息"), "details"), (NL("平铺"), "tiles"), (NL("内容"), "content")]
      let current = folderDefaults["view"] ?? "icons"
      let selectedLayout = current == "icons" ? "icons:" + (folderDefaults["iconSize"] ?? "64") : current
      if !layouts.contains(where: { $0.1 == selectedLayout }) { layouts.insert((NL("图标（{0} 像素）", folderDefaults["iconSize"] ?? "64"), selectedLayout), at: 4) }
      let layout = EDChoiceRow(title: NL("默认布局"), options: layouts, value: selectedLayout) { [weak self] value in
        guard let self else { return }; let parts = value.split(separator: ":"); self.folderDefaults["view"] = String(parts[0]); if parts.count == 2 { self.folderDefaults["iconSize"] = String(parts[1]) }; self.onFolderDefaults?(self.folderDefaults)
      }
      let sort = EDChoiceRow(title: NL("默认排序"), options: [(NL("名称"), "name"), (NL("修改日期"), "modified"), (NL("创建日期"), "created"), (NL("类型"), "kind"), (NL("大小"), "size")], value: folderDefaults["sort"] ?? "name") { [weak self] value in guard let self else { return }; self.folderDefaults["sort"] = value; self.onFolderDefaults?(self.folderDefaults) }
      let direction = EDChoiceRow(title: NL("排序方向"), options: [(NL("递增"), "true"), (NL("递减"), "false")], value: folderDefaults["ascending"] ?? "true") { [weak self] value in guard let self else { return }; self.folderDefaults["ascending"] = value; self.onFolderDefaults?(self.folderDefaults) }
      let reset = EDButton(title: NL("重置所有文件夹"), style: .secondary); reset.onPress = { [weak self] in self?.onResetFolders?() }
      [layout, sort, direction, reset].forEach(group.content.addSubview)
      group.arrange = { rect in
        for (index, row) in [layout, sort, direction].enumerated() { row.frame = NSRect(x: 0, y: CGFloat(index) * 44, width: rect.width, height: 32) }
        reset.frame = NSRect(x: 0, y: 132, width: 140, height: 34)
      }
      content.flow.add(group) { _ in 192 }
    }
  }
  private func toolbarContent() {
    content.flow.gap = 0
    let order = toolbar + (onToolbar == nil ? [] : allTools.filter { !toolbar.contains($0) })
    for id in order {
      let row = EDToolbarRow(title: toolLabels[id] ?? id, icon: id == "cut" ? "scissors" : id, checked: toolbar.contains(id), editable: onToolbar != nil)
      row.onToggle = { [weak self] in
        guard let self, let onToolbar = self.onToolbar else { return }
        if self.toolbar.contains(id) { self.toolbar.removeAll { $0 == id } }
        else { self.toolbar.append(id) }
        onToolbar(self.toolbar)
        self.select(1)
      }
      let position = toolbar.firstIndex(of: id)
      row.up.isEnabled = position.map { $0 > 0 } ?? false
      row.down.isEnabled = position.map { $0 < toolbar.count - 1 } ?? false
      row.onMove = { [weak self] delta in
        guard let self, let onToolbar = self.onToolbar, let index = self.toolbar.firstIndex(of: id), self.toolbar.indices.contains(index + delta) else { return }
        self.toolbar.swapAt(index, index + delta)
        onToolbar(self.toolbar)
        self.select(1)
      }
      content.flow.add(row) { _ in 36 }
    }
    if let onToolbar {
      let reset = EDButton(title: NL("恢复默认工具栏"), style: .secondary)
      reset.onPress = { [weak self] in
        guard let self else { return }
        self.toolbar = ["cut", "copy", "paste", "rename", "share", "trash"]
        onToolbar(self.toolbar)
        self.select(1)
      }
      let footer = EDView(); footer.addSubview(reset)
      content.flow.add(footer) { width in reset.frame = NSRect(x: 0, y: 12, width: min(width, reset.intrinsicContentSize.width), height: 34); return 46 }
    }
  }
  private func shortcuts() {
    content.flow.gap = 12
    if shortcutRows.isEmpty {
      content.flow.add(edLabel(NL("未设置"), size: 12)) { _ in 24 }
      return
    }
    content.flow.add(edLabel(NL("文件操作快捷键"), size: 13, weight: .semibold)) { _ in 22 }
    let list = EDFlow(); list.padding = 0; list.gap = 0
    content.flow.add(list) { width in list.reflow(width: width, minimumHeight: 0); return list.frame.height }
    for (index, pair) in shortcutRows.enumerated() {
      let row = EDShortcutRow(title: pair.0, value: shortcutValues[index], editable: onShortcut != nil)
      row.recorder.captureChanged = { [weak integration = browser?.systemIntegration] active in integration?.captureShortcut(active) }
      row.recorder.onRecord = { [weak self, weak row] value in
        guard let self else { return false }
        if !value.isEmpty, value == self.browser?.defaults.string(forKey: "wakeShortcut") { self.showShortcutError(NL("快捷键与唤醒快捷键冲突。")); return false }
        var next = self.shortcutValues
        next[index] = value
        if let error = EDShortcutRules.validate(next, labels: self.shortcutRows.map { $0.0 }) {
          self.showShortcutError(error)
          return false
        }
        self.shortcutValues = next
        row?.reset.isEnabled = self.shortcutDefaults[pair.0] != value
        self.updateShortcutSave()
        return true
      }
      row.recorder.onError = { [weak self] message in self?.showShortcutError(message) }
      row.onClear = { [weak self, weak row] in
        guard let self else { return }
        self.shortcutValues[index] = ""
        row?.recorder.value = ""; row?.reset.isEnabled = self.shortcutDefaults[pair.0] != ""
        self.updateShortcutSave()
      }
      row.reset.isEnabled = shortcutDefaults[pair.0].map { $0 != shortcutValues[index] } ?? false
      row.onReset = { [weak self, weak row] in
        guard let self, let value = self.shortcutDefaults[pair.0] else { return }
        self.shortcutValues[index] = value; row?.recorder.value = value; row?.reset.isEnabled = false; self.updateShortcutSave()
      }
      list.add(row) { _ in 44 }
    }
    if onShortcut != nil {
      let footer = EDView()
      let error = edLabel("", wraps: true)
      error.textColor = EDColors.error; error.frame = NSRect(x: 0, y: 0, width: 450, height: 22)
      shortcutError = error; footer.addSubview(error)
      let reset = EDButton(title: NL("恢复默认快捷键"), style: .secondary)
      reset.onPress = { [weak self] in
        guard let self else { return }; self.shortcutValues = self.shortcutRows.map { self.shortcutDefaults[$0.0] ?? $0.1 }; self.select(2)
      }
      shortcutReset = reset; footer.addSubview(reset)
      let save = EDButton(title: NL("保存操作快捷键"), style: .primary)
      save.onPress = { [weak self] in
        guard let self, let onShortcut = self.onShortcut else { return }
        if let error = EDShortcutRules.validate(self.shortcutValues, labels: self.shortcutRows.map { $0.0 }) { self.showShortcutError(error); return }
        for index in self.shortcutValues.indices where self.shortcutValues[index] != self.savedShortcuts[index] {
          onShortcut(self.shortcutRows[index].0, self.shortcutValues[index])
        }
        self.savedShortcuts = self.shortcutValues
        self.updateShortcutSave()
      }
      shortcutSave = save; footer.addSubview(save)
      content.flow.add(footer) { width in
        error.frame.size.width = width
        save.frame = NSRect(x: max(0, width - 142), y: 24, width: 142, height: 34)
        reset.frame = NSRect(x: max(0, width - 293), y: 24, width: 142, height: 34)
        return 58
      }
      updateShortcutSave()
    }
    if let integration = browser?.systemIntegration {
      let group = EDGroup(NL("唤醒快捷键")), wake = NativeWakeSettingsView(integration: integration)
      group.content.addSubview(wake); group.arrange = { wake.frame = $0 }
      content.flow.add(group) { _ in wake.preferredHeight + 26 }
    }
  }
  private func showShortcutError(_ message: String) {
    shortcutError?.stringValue = message
    shortcutSave?.isEnabled = false
  }
  private func updateShortcutSave() {
    let error = EDShortcutRules.validate(shortcutValues, labels: shortcutRows.map { $0.0 })
    shortcutError?.stringValue = error ?? ""
    shortcutSave?.isEnabled = error == nil && shortcutValues != savedShortcuts
    shortcutSave?.needsDisplay = true
    shortcutReset?.isEnabled = shortcutRows.enumerated().contains { shortcutDefaults[$0.element.0] != nil && shortcutValues[$0.offset] != shortcutDefaults[$0.element.0] }
  }
  private func about() {
    content.flow.gap = 8
    let iconRow = EDView(), icon = NSImageView()
    icon.image = NSImage(named: NSImage.Name("AppIcon")) ?? NSApp.applicationIconImage
    icon.imageScaling = .scaleProportionallyUpOrDown
    iconRow.addSubview(icon)
    content.flow.add(iconRow) { width in
      icon.frame = NSRect(x: (width - 64) / 2, y: 0, width: 64, height: 64)
      return 76
    }
    let info = Bundle.main.infoDictionary ?? [:]
    let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Mac Explorer"
    let nameLabel = edLabel(name, size: 18, weight: .semibold)
    nameLabel.alignment = .center
    content.flow.add(nameLabel) { _ in 28 }
    let version = info["CFBundleShortVersionString"] as? String ?? "—"
    let versionLabel = edLabel(NL("版本 {0}", version))
    versionLabel.textColor = ExplorerPalette.secondary; versionLabel.alignment = .center
    content.flow.add(versionLabel) { _ in 28 }
    let separator = SurfaceView(); separator.color = ExplorerPalette.border
    content.flow.add(separator) { _ in 1 }
    let updateDefaults = browser?.defaults ?? .standard
    let frequency = EDChoiceRow(title: NL("自动检查更新"), options: [
      (NL("每次打开"), "launch"), (NL("每天"), "daily"), (NL("每周"), "weekly"), (NL("从不"), "never")
    ], value: NativeUpdateFrequency.saved(in: updateDefaults).rawValue) { value in
      updateDefaults.set(value, forKey: NativeUpdateFrequency.preferenceKey)
    }
    content.flow.add(frequency) { _ in 34 }
    let updates = NativeUpdateView(); content.flow.add(updates) { _ in updates.preferredHeight }
    let linksRow = EDView()
    let links = [("项目主页", ""), ("GitHub 发布页", "/releases"), ("问题反馈", "/issues"), ("开源许可", "/blob/main/LICENSE")].map { title, path in
      let button = EDButton(title: NL(title), style: .secondary)
      button.onPress = { NSWorkspace.shared.open(URL(string: "https://github.com/qixiaoyu27/Mac-Explorer" + path)!) }
      linksRow.addSubview(button)
      return button
    }
    content.flow.add(linksRow) { width in
      let gap: CGFloat = 8, buttonWidth = (width - gap * 3) / 4
      for (index, button) in links.enumerated() {
        button.frame = NSRect(x: CGFloat(index) * (buttonWidth + gap), y: 0, width: buttonWidth, height: 30)
      }
      return 30
    }
    let copyright = edLabel("© 2026 qixiaoyu27 · GPL-3.0-only", size: 12)
    copyright.textColor = ExplorerPalette.secondary; copyright.alignment = .center
    content.flow.add(copyright) { _ in 24 }
  }
}

private final class EDChoice: NSButton {
  private let options: [(String, String)]
  private var value: String
  private let change: (String) -> Void
  init(options: [(String, String)], value: String, change: @escaping (String) -> Void) {
    self.options = options; self.value = value; self.change = change
    super.init(frame: .zero); title = options.first(where: { $0.1 == value })?.0 ?? value
    isBordered = false; focusRingType = .none; target = self; action = #selector(showOptions)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  @objc private func showOptions() {
    ExplorerMenu.present(options.map { title, value in ExplorerMenuItem(title: title, checked: value == self.value, radio: true, action: { [weak self] in guard let self else { return }; self.value = value; self.title = title; self.change(value); self.needsDisplay = true }) }, below: self)
  }
  override func keyDown(with event: NSEvent) { if [125, 126, 36, 49].contains(event.keyCode) { showOptions() } else { super.keyDown(with: event) } }
  override func draw(_ dirtyRect: NSRect) {
    ExplorerPalette.surface.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill(); edBorder(bounds)
    edDrawText(title, in: NSRect(x: 9, y: 0, width: max(0, bounds.width - 35), height: bounds.height), size: 13)
    ExplorerIcons.image("chevronDown", size: 14).draw(in: NSRect(x: bounds.width - 23, y: bounds.midY - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    if window?.firstResponder === self && ExplorerFocus.keyboardVisible { edBorder(bounds, color: ExplorerPalette.accent, width: 2) }
  }
}
private final class EDChoiceRow: EDView {
  private let label: NSTextField
  private let choice: EDChoice
  init(title: String, options: [(String, String)], value: String, change: @escaping (String) -> Void) {
    label = edLabel(title, size: 13); choice = EDChoice(options: options, value: value, change: change)
    super.init(frame: .zero); addSubview(label); addSubview(choice); choice.setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() { super.layout(); let width = min(132, bounds.width * 0.36); label.frame = NSRect(x: 0, y: 7, width: width, height: 18); choice.frame = NSRect(x: width + 20, y: 0, width: min(250, max(0, bounds.width - width - 20)), height: 32) }
}

private final class EDToolbarRow: EDView {
  let up = ExplorerButton(icon: "arrowUp")
  let down = ExplorerButton(icon: "arrowDown")
  var onToggle: (() -> Void)?
  var onMove: ((Int) -> Void)?
  private let toggle: EDButton
  private let label: NSTextField
  private let editable: Bool
  init(title: String, icon: String, checked: Bool, editable: Bool) {
    self.editable = editable
    toggle = EDButton(title: title, style: .checkbox)
    toggle.iconName = icon
    toggle.checked = checked
    label = edLabel(title)
    super.init(frame: .zero)
    if editable {
      addSubview(toggle)
      addSubview(up)
      addSubview(down)
      toggle.onPress = { [weak self] in self?.onToggle?() }
      up.onPress = { [weak self] in self?.onMove?(-1) }
      down.onPress = { [weak self] in self?.onMove?(1) }
      up.setAccessibilityLabel(NL("上移{0}", title))
      down.setAccessibilityLabel(NL("下移{0}", title))
    } else { addSubview(label) }
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override func layout() {
    super.layout()
    toggle.frame = NSRect(x: 8, y: 4, width: max(1, bounds.width - 72), height: 28)
    label.frame = NSRect(x: 8, y: 9, width: max(1, bounds.width - 16), height: 18)
    up.frame = NSRect(x: bounds.width - 60, y: 4, width: 28, height: 28)
    down.frame = NSRect(x: bounds.width - 30, y: 4, width: 28, height: 28)
  }
  override func draw(_ dirtyRect: NSRect) {
    ExplorerPalette.border.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }
}

private final class EDShortcutRow: EDView {
  let recorder: EDShortcutRecorder
  var onClear: (() -> Void)?
  var onReset: (() -> Void)?
  let reset = ExplorerButton(icon: "refresh")
  private let label: NSTextField
  private let readOnly: NSTextField
  private let clear = ExplorerButton(icon: "close")
  private let editable: Bool
  init(title: String, value: String, editable: Bool) {
    self.editable = editable
    recorder = EDShortcutRecorder(value: value)
    label = edLabel(title)
    readOnly = edLabel(EDShortcutRules.display(value), selectable: true)
    super.init(frame: .zero)
    addSubview(label)
    if editable {
      addSubview(recorder)
      addSubview(clear); addSubview(reset)
      reset.iconDimension = 14; clear.iconDimension = 15
      reset.setAccessibilityLabel(NL("恢复{0}的默认快捷键", title)); reset.onPress = { [weak self] in self?.onReset?() }
      recorder.setAccessibilityLabel(NL("{0}的快捷键", title))
      clear.setAccessibilityLabel(NL("清除{0}的快捷键", title))
      clear.onPress = { [weak self] in self?.onClear?() }
    } else { addSubview(readOnly) }
  }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override func layout() {
    super.layout()
    let left = max(108, (bounds.width - 72) / 2.4 + 8)
    label.frame = NSRect(x: 0, y: 13, width: max(1, left - 8), height: 18)
    recorder.frame = NSRect(x: left, y: 5, width: max(1, bounds.width - left - 64), height: 34)
    readOnly.frame = NSRect(x: left, y: 13, width: max(1, bounds.width - left), height: 18)
    clear.frame = NSRect(x: bounds.width - 56, y: 8, width: 28, height: 28)
    reset.frame = NSRect(x: bounds.width - 28, y: 8, width: 28, height: 28)
  }
  override func draw(_ dirtyRect: NSRect) {
    ExplorerPalette.border.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }
}

final class EDShortcutRecorder: EDView {
  var captureChanged: ((Bool) -> Void)?
  private var capturing = false
  var value: String { didSet { setAccessibilityValue(value); needsDisplay = true } }
  var onRecord: ((String) -> Bool)?
  var onError: ((String) -> Void)?
  init(value: String) {
    self.value = value
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.textField)
    setAccessibilityValue(value)
  }
  deinit { if capturing { captureChanged?(false) } }
  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
  override func becomeFirstResponder() -> Bool { capturing = true; captureChanged?(true); needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { if capturing { capturing = false; captureChanged?(false) }; needsDisplay = true; return true }
  override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if event.keyCode == 48 && flags.subtracting(.shift).isEmpty {
      if flags.contains(.shift) { window?.selectPreviousKeyView(self) }
      else { window?.selectNextKeyView(self) }
      return
    }
    if event.keyCode == 53 && flags.isEmpty { window?.makeFirstResponder(nil); return }
    guard let accelerator = EDShortcutRules.accelerator(event) else { onError?(NL("无效的快捷键。")); return }
    guard ExplorerShortcuts.canRecordOperation(accelerator) else { onError?(NL("请使用修饰键组合、功能键或 Return、Space、Backspace、Delete。")); return }
    if onRecord?(accelerator) == true { value = accelerator }
  }
  override func draw(_ dirtyRect: NSRect) {
    ExplorerPalette.surface.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    let focused = window?.firstResponder === self
    edBorder(bounds, color: focused ? ExplorerPalette.accent : ExplorerPalette.border, width: focused ? 2 : 1)
    let text = value.isEmpty ? (focused ? NL("按下快捷键") : NL("未设置")) : EDShortcutRules.display(value)
    edDrawText(text, in: bounds.insetBy(dx: 8, dy: 0), color: value.isEmpty ? ExplorerPalette.secondary : ExplorerPalette.text)
  }
}

private enum EDShortcutRules {
  // Same application/system reservations as shared/shortcuts.ts. The platform
  // does not expose a complete registry of user-customized global shortcuts.
  static let reserved: Set<String> = [
    "Command+,", "Command+Q", "Command+H", "Command+Alt+H", "Command+M", "Command+Shift+W", "Command+Control+F",
    "Command+Shift+C", "Command+Shift+H", "Command+Shift+D", "Command+Shift+O", "Command+Alt+L", "Command+Alt+S",
    "Command+Space", "Command+Alt+Space", "Control+Space", "Control+Shift+Space", "Command+Tab", "Command+Shift+Tab",
    "Command+Alt+Escape", "Control+Up", "Control+Down", "Control+Left", "Control+Right",
    "Command+Shift+3", "Command+Shift+4", "Command+Shift+5", "Tab", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown"
  ]
  static func canonical(_ value: String) -> String { ExplorerShortcuts.normalize(value) }
  static func display(_ value: String) -> String {
    value.components(separatedBy: " / ").map { alias in
      var parts = canonical(alias).components(separatedBy: "+")
      guard let key = parts.popLast(), !key.isEmpty else { return alias }
      let symbols = [("Control", "⌃"), ("Alt", "⌥"), ("Shift", "⇧"), ("Command", "⌘")]
      let prefix = symbols.filter { parts.contains($0.0) }.map { $0.1 }.joined()
      let keys = ["Enter": "Return", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Delete": "⌦", "Backspace": "⌫", "Plus": "+"]
      return prefix + (keys[key] ?? key)
    }.joined(separator: " / ")
  }
  static func validate(_ values: [String], labels: [String]) -> String? {
    var used: [String: Int] = [:]
    for (index, value) in values.enumerated() where !value.isEmpty {
      for alias in value.components(separatedBy: " / ") {
        let key = canonical(alias)
        if reserved.contains(key) { return NL("“{0}”是应用或系统保留组合。", alias) }
        if let previous = used[key], previous != index { return NL("“{0}”与“{1}”使用相同快捷键。", labels[index], labels[previous]) }
        used[key] = index
      }
    }
    return nil
  }
  static func accelerator(_ event: NSEvent) -> String? { ExplorerShortcuts.accelerator(event) }
}
