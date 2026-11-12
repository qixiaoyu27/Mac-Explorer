import AppKit
import ExplorerCore
import QuartzCore

enum ExplorerFocus { static var keyboardVisible = false }

enum ExplorerFormat {
  static func size(_ bytes: Int64) -> String {
    let value = Double(max(0, bytes))
    let divisor: Double = value >= pow(1024, 3) ? pow(1024, 3) : value >= pow(1024, 2) ? pow(1024, 2) : value >= 1024 ? 1024 : 1
    let unit = divisor == pow(1024, 3) ? "GB" : divisor == pow(1024, 2) ? "MB" : divisor == 1024 ? "KB" : NL("字节")
    return (value / divisor).formatted(.number.locale(NativeLanguage.formatLocale).precision(.fractionLength(0...(bytes >= 1_000_000_000 ? 1 : 0)))) + " " + unit
  }
}

extension NSColor {
  static var explorerSurface: NSColor { ExplorerPalette.surface }
  static var explorerChrome: NSColor { ExplorerPalette.toolbar }
  static var explorerSidebar: NSColor { ExplorerPalette.sidebar }
  static var explorerSelection: NSColor { ExplorerPalette.selection }
  static var explorerAccent: NSColor { ExplorerPalette.accent }
}

class SurfaceView: NSView {
  var color: NSColor = .explorerSurface { didSet { needsDisplay = true } }
  var bottomBorder = false
  var topBorder = false
  var rightBorder = false
  var leftBorder = false
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSBezierPath(rect: bounds).addClip(); color.setFill(); bounds.fill()
    if bottomBorder { ExplorerPalette.border.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
    ExplorerPalette.border.setFill()
    if topBorder { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
    if rightBorder { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    if leftBorder { NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill() }
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

enum FilePaneHit {
  case background
  case file(Int)
  case group(Int)
  case checkbox
}

protocol FilePaneDocument: AnyObject where Self: NSView {
  func selectableItem(at point: NSPoint) -> FilePaneHit
  func isClickInItemWhitespace(at point: NSPoint, row: Int) -> Bool
  func fileRows(intersecting rect: NSRect) -> IndexSet
}

final class FilePaneScrollView: NSScrollView {
  var onScroll: (() -> Void)?

  override var hasHorizontalScroller: Bool {
    get { false }
    set {}
  }

  override var hasVerticalScroller: Bool {
    get { false }
    set {}
  }

  override func reflectScrolledClipView(_ clip: NSClipView) {
    super.reflectScrolledClipView(clip)
    if clip === contentView { onScroll?() }
  }
}

final class ExplorerScroller: NSScroller {
  static let thickness: CGFloat = 10
  private static let thumbThickness: CGFloat = 6
  private static let fadeAnimationKey = "thumbFade"
  private let horizontal: Bool
  private let thumbLayer = CALayer()
  private var hovered = false
  private var tracking = false
  private var lastScrollOffset: CGFloat?
  private var pendingFade: DispatchWorkItem?
  weak var scrollView: NSScrollView?

  init(horizontal: Bool) {
    self.horizontal = horizontal
    let thickness = Self.thickness
    super.init(frame: NSRect(x: 0, y: 0, width: horizontal ? 100 : thickness, height: horizontal ? thickness : 100))
    wantsLayer = true
    thumbLayer.opacity = 0
    layer?.addSublayer(thumbLayer)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
  }

  required init?(coder: NSCoder) { fatalError() }

  override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { thickness }
  override var isOpaque: Bool { false }
  override var wantsUpdateLayer: Bool { true }

  var thumbRect: NSRect {
    let knob = backingAlignedRect(rect(for: .knob), options: .alignAllEdgesNearest)
    guard !knob.isEmpty else { return .zero }
    let thumbThickness = Self.thumbThickness
    if horizontal {
      return NSRect(x: knob.minX, y: bounds.midY - thumbThickness / 2, width: knob.width, height: thumbThickness)
    }
    return NSRect(x: bounds.midX - thumbThickness / 2, y: knob.minY, width: thumbThickness, height: knob.height)
  }

  func reflectScrollOrigin(_ origin: NSPoint) {
    let offset = horizontal ? origin.x : origin.y
    defer { lastScrollOffset = offset }
    if let lastScrollOffset, lastScrollOffset != offset { revealThumb() }
  }

  private func setThumbOpacity(_ opacity: Float, animated: Bool = false) {
    let previous = (thumbLayer.presentation() ?? thumbLayer).opacity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    thumbLayer.opacity = opacity
    thumbLayer.removeAnimation(forKey: Self.fadeAnimationKey)
    if animated && previous != opacity && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = previous
      fade.toValue = opacity
      fade.duration = 0.2
      thumbLayer.add(fade, forKey: Self.fadeAnimationKey)
    }
    CATransaction.commit()
  }

  fileprivate func revealThumb() {
    guard window != nil, isEnabled, !isHiddenOrHasHiddenAncestor else { return }
    if thumbLayer.opacity != 1 { setThumbOpacity(1) }
    scheduleFade()
  }

  private func scheduleFade() {
    pendingFade?.cancel()
    pendingFade = nil
    guard !hovered, !tracking, thumbLayer.opacity > 0 else { return }
    let fade = DispatchWorkItem { [weak self] in
      self?.pendingFade = nil
      self?.setThumbOpacity(0, animated: true)
    }
    pendingFade = fade
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: fade)
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    revealThumb()
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    scheduleFade()
  }

  override func mouseDown(with event: NSEvent) {
    tracking = true
    revealThumb()
    super.mouseDown(with: event)
    hovered = explorerPointerIsInside(self)
    tracking = false
    scheduleFade()
  }

  override func viewDidHide() {
    super.viewDidHide()
    hovered = false
    setThumbOpacity(0)
    scheduleFade()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func updateLayer() {
    let thumb = thumbRect
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      thumbLayer.backgroundColor = ExplorerPalette.scrollbar.cgColor
    }
    thumbLayer.isHidden = !isEnabled || thumb.isEmpty
    thumbLayer.bounds = NSRect(origin: .zero, size: thumb.size)
    thumbLayer.position = NSPoint(x: thumb.midX, y: thumb.midY)
    thumbLayer.cornerRadius = min(thumb.width, thumb.height) / 2
    CATransaction.commit()
  }

  override func scrollWheel(with event: NSEvent) {
    if let scrollView { scrollView.scrollWheel(with: event) }
    else { super.scrollWheel(with: event) }
  }
}

class ExplorerScrollView: NSScrollView {
  override func reflectScrolledClipView(_ clip: NSClipView) {
    super.reflectScrolledClipView(clip)
    guard clip === contentView else { return }
    let origin = clip.bounds.origin
    (horizontalScroller as? ExplorerScroller)?.reflectScrollOrigin(origin)
    (verticalScroller as? ExplorerScroller)?.reflectScrollOrigin(origin)
  }

  override var hasHorizontalScroller: Bool {
    get { super.hasHorizontalScroller }
    set {
      if newValue && horizontalScroller == nil { horizontalScroller = ExplorerScroller(horizontal: true) }
      super.hasHorizontalScroller = newValue
    }
  }

  override var hasVerticalScroller: Bool {
    get { super.hasVerticalScroller }
    set {
      if newValue && verticalScroller == nil { verticalScroller = ExplorerScroller(horizontal: false) }
      super.hasVerticalScroller = newValue
    }
  }
}

final class FilePaneSurface: SurfaceView {
  static let detailsInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 24)
  let scroll = FilePaneScrollView()
  let horizontalScroller = ExplorerScroller(horizontal: true)
  let verticalScroller = ExplorerScroller(horizontal: false)
  private var origins: [ObjectIdentifier: NSPoint] = [:]
  private var pendingOrigin: NSPoint?
  private var sizingViewport = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    scroll.automaticallyAdjustsContentInsets = false
    scroll.backgroundColor = ExplorerPalette.surface
    addSubview(scroll)
    for scroller in [horizontalScroller, verticalScroller] {
      scroller.isHidden = true
      scroller.target = self
      scroller.action = #selector(moveScroller(_:))
      scroller.scrollView = scroll
      addSubview(scroller)
    }
    scroll.onScroll = { [weak self] in self?.updateScrollers() }
  }

  required init?(coder: NSCoder) { fatalError() }

  func rememberDocumentOrigin(beforeInstalling document: NSView) {
    guard let previous = scroll.documentView, previous !== document, pendingOrigin == nil else { return }
    origins[ObjectIdentifier(previous)] = scroll.contentView.bounds.origin
  }

  func install(_ document: NSView) {
    guard scroll.documentView !== document else { return }
    let table = document as? FileTableView
    let insets = table == nil ? NSEdgeInsets() : Self.detailsInsets
    scroll.contentInsets = insets
    scroll.documentView = document
    pendingOrigin = origins[ObjectIdentifier(document)] ??
      NSPoint(x: -insets.left, y: -(table?.headerView?.frame.height ?? 0))
  }

  func layoutViewport(filesVisible: Bool, layoutDocument: () -> Void) {
    let origin = pendingOrigin ?? scroll.contentView.bounds.origin
    pendingOrigin = nil
    var viewport = bounds
    var horizontal = false, vertical = false
    sizingViewport = true
    while true {
      if scroll.frame != viewport { scroll.frame = viewport }
      layoutDocument()
      guard filesVisible else { break }
      let (minimum, maximum) = scrollLimits()
      let needsHorizontal = !horizontal && maximum.x > minimum.x
      let needsVertical = !vertical && maximum.y > minimum.y
      guard needsHorizontal || needsVertical else { break }
      if needsHorizontal {
        horizontal = true
        viewport.size.height = max(0, viewport.height - ExplorerScroller.thickness)
      }
      if needsVertical {
        vertical = true
        viewport.size.width = max(0, viewport.width - ExplorerScroller.thickness)
      }
    }
    if horizontal {
      horizontalScroller.frame = NSRect(x: viewport.minX, y: viewport.maxY, width: viewport.width, height: bounds.maxY - viewport.maxY)
    }
    if vertical {
      verticalScroller.frame = NSRect(x: viewport.maxX, y: viewport.minY, width: bounds.maxX - viewport.maxX, height: viewport.height)
    }
    let revealHorizontal = horizontal && horizontalScroller.isHidden
    horizontalScroller.isHidden = !horizontal
    verticalScroller.isHidden = !vertical
    scrollTo(origin)
    sizingViewport = false
    updateScrollers()
    if revealHorizontal { horizontalScroller.revealThumb() }
  }

  func scrollTo(_ origin: NSPoint) {
    let clip = scroll.contentView
    let proposed = NSRect(origin: origin, size: clip.bounds.size)
    scroll.scroll(clip, to: clip.constrainBoundsRect(proposed).origin)
    scroll.reflectScrolledClipView(clip)
  }

  private func scrollLimits() -> (minimum: NSPoint, maximum: NSPoint) {
    let clip = scroll.contentView
    let insets = scroll.contentInsets
    let extent = clip.documentRect.insetBy(dx: -clip.bounds.width - insets.left - insets.right,
                                          dy: -clip.bounds.height - insets.top - insets.bottom)
    let minimum = NSRect(origin: extent.origin, size: clip.bounds.size)
    let maximum = NSRect(origin: NSPoint(x: extent.maxX, y: extent.maxY), size: clip.bounds.size)
    return (clip.constrainBoundsRect(minimum).origin, clip.constrainBoundsRect(maximum).origin)
  }

  private func updateScrollers() {
    guard !sizingViewport, !horizontalScroller.isHidden || !verticalScroller.isHidden else { return }
    let (minimum, maximum) = scrollLimits()
    let origin = scroll.contentView.bounds.origin, visible = fileViewport.size
    func update(_ scroller: ExplorerScroller, offset: CGFloat, range: CGFloat, page: CGFloat) {
      guard !scroller.isHidden else { return }
      scroller.isEnabled = range > 0
      scroller.knobProportion = range > 0 ? page / (page + range) : 1
      scroller.doubleValue = range > 0 ? Double(max(0, min(1, offset / range))) : 0
      scroller.reflectScrollOrigin(origin)
    }
    update(horizontalScroller, offset: origin.x - minimum.x, range: maximum.x - minimum.x, page: visible.width)
    update(verticalScroller, offset: origin.y - minimum.y, range: maximum.y - minimum.y, page: visible.height)
  }

  @objc private func moveScroller(_ scroller: NSScroller) {
    let horizontal = scroller === horizontalScroller
    let (minimum, maximum) = scrollLimits()
    let start = horizontal ? minimum.x : minimum.y
    let end = horizontal ? maximum.x : maximum.y
    var origin = scroll.contentView.bounds.origin
    let axis = horizontal ? \NSPoint.x : \NSPoint.y
    let line = horizontal ? scroll.horizontalLineScroll : scroll.verticalLineScroll
    let page = horizontal ? fileViewport.width - scroll.horizontalPageScroll : fileViewport.height - scroll.verticalPageScroll
    switch scroller.hitPart {
    case .decrementLine: origin[keyPath: axis] -= line
    case .incrementLine: origin[keyPath: axis] += line
    case .decrementPage: origin[keyPath: axis] -= max(line, page)
    case .incrementPage: origin[keyPath: axis] += max(line, page)
    default: origin[keyPath: axis] = start + (end - start) * scroller.doubleValue
    }
    scrollTo(origin)
  }

  var fileViewport: NSRect {
    let clip = scroll.contentView
    var area = convert(clip.bounds, from: clip)
    if let header = (scroll.documentView as? FileTableView)?.headerView, let headerClip = header.superview {
      let top = min(area.maxY, max(area.minY, convert(headerClip.bounds, from: headerClip).maxY))
      area.size.height = area.maxY - top
      area.origin.y = top
    }
    return area.intersection(bounds)
  }

  func pointerTarget(at event: NSEvent) -> (document: any FilePaneDocument, hit: FilePaneHit)? {
    let point = convert(event.locationInWindow, from: nil)
    guard let window, event.window === window, window.isKeyWindow, !scroll.isHidden, fileViewport.contains(point),
          NativeSelection.canHandle(self), let document = scroll.documentView as? any FilePaneDocument,
          let root = window.contentView, let parent = root.superview,
          let hit = root.hitTest(parent.convert(event.locationInWindow, from: nil)),
          hit === scroll || hit.isDescendant(of: scroll) else { return nil }
    var target: NSView? = hit
    while let candidate = target, candidate !== scroll {
      if candidate is ExplorerCheckbox { return (document, .checkbox) }
      if candidate is NSScroller || candidate is NSTableHeaderView || candidate is NSButton { return nil }
      target = candidate.superview
    }
    return (document, document.selectableItem(at: document.convert(event.locationInWindow, from: nil)))
  }
}

final class ExplorerTabBar: SurfaceView {
  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    if event.clickCount == 2 {
      window.performZoom(nil)
    } else {
      window.performDrag(with: event)
    }
  }
}
final class ExplorerLoadingView: SurfaceView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    ExplorerPalette.active.withAlphaComponent(0.55).setFill()
    for (index, fraction) in [0.50, 0.37, 0.61, 0.43, 0.55].enumerated() {
      NSBezierPath(roundedRect: NSRect(x: 32, y: 48 + CGFloat(index) * 32, width: max(0, bounds.width - 64) * fraction, height: 15), xRadius: 3, yRadius: 3).fill()
    }
  }
}

final class ExplorerEmptyStateView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ExplorerRootView: SurfaceView {
  var onLayout: (() -> Void)?
  override func layout() { super.layout(); onLayout?() }
  override var mouseDownCanMoveWindow: Bool { false }
}

class ExplorerTextField: NSTextField {
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    super.draw(dirtyRect)
    NSGraphicsContext.restoreGraphicsState()
  }
}

func label(_ text: String, size: CGFloat = 13, color: NSColor = ExplorerPalette.text) -> NSTextField {
  let field = ExplorerTextField(labelWithString: text)
  field.font = ExplorerTypography.font(ofSize: size == 12 ? 13 : size); field.textColor = color; field.lineBreakMode = .byTruncatingTail
  return field
}
private func explorerPointerIsInside(_ view: NSView) -> Bool {
  guard let window = view.window, window.isKeyWindow, !view.isHiddenOrHasHiddenAncestor else { return false }
  let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
  return view.bounds.contains(point) && view.visibleRect.contains(point)
}
func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
  child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
  NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset), child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)])
}
func symbol(_ name: String, description: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: description) }

final class IconLoader {
  static let shared = IconLoader()
  private let cache = NSCache<NSString, NSImage>()
  private let service = NativeIconService()
  private var pending: [String: [(UUID, (NSImage) -> Void)]] = [:]
  private var sources: [String: (String, Int)] = [:]
  private var queue: [String] = []
  private var scheduled = false
  private var inFlight = 0
  private(set) var loads = 0
  var isIdle: Bool { queue.isEmpty && !scheduled && inFlight == 0 }
  init() { cache.countLimit = 512 }
  func clear() { cache.removeAllObjects() }
  func request(_ entry: FileEntry, pixels: Int, completion: @escaping (NSImage) -> Void) -> () -> Void {
    // A retained file URL can keep its previous Launch Services binding cached.
    let application = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: entry.url.path))?.path ?? ""
    let key = "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(pixels)|\(application)"
    if let image = cache.object(forKey: key as NSString) { completion(image); return {} }
    let id = UUID()
    if pending[key] == nil { queue.append(key); pending[key] = []; sources[key] = (entry.url.path, pixels) }
    pending[key, default: []].append((id, completion)); schedule()
    return { [weak self] in self?.pending[key]?.removeAll { $0.0 == id } }
  }
  private func schedule() {
    guard !scheduled, !queue.isEmpty, inFlight < 4 else { return }; scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }; self.scheduled = false
      while self.inFlight < 4 && !self.queue.isEmpty {
        let key = self.queue.removeFirst()
        guard let source = self.sources.removeValue(forKey: key), !(self.pending[key] ?? []).isEmpty else { self.pending.removeValue(forKey: key); continue }
        self.inFlight += 1; self.loads += 1
        self.service.request(path: source.0, pixels: source.1) { [weak self] result in
          guard let self else { return }
          let image = result ?? NSWorkspace.shared.icon(forFile: source.0)
          self.cache.setObject(image, forKey: key as NSString)
          let callbacks = self.pending.removeValue(forKey: key) ?? []
          self.inFlight -= 1; callbacks.forEach { $0.1(image) }; self.schedule()
        }
      }
    }
  }
}

final class FileIconView: NSImageView {
  private var cancel: (() -> Void)?
  private var vcsMark: String?
  private var entry: FileEntry?
  private var pixels = 64
  func show(_ entry: FileEntry, pixels: Int = 64) {
    self.entry = entry; self.pixels = pixels
    cancel?(); contentTintColor = nil; vcsMark = entry.vcsMark; needsDisplay = true
    if entry.isDirectory && !entry.isPackage { image = ExplorerIcons.folder(size: 128, url: entry.url); cancel = nil; return }
    image = ExplorerIcons.image("document", size: 64, color: ExplorerPalette.secondary)
    cancel = IconLoader.shared.request(entry, pixels: pixels) { [weak self] image in self?.image = image }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let vcsMark else { return }
    let size = min(18, max(10, bounds.width * 0.3)), frame = NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - size : bounds.minY, width: size, height: size)
    let color: NSColor = vcsMark == "!" || vcsMark == "D" ? .systemRed : vcsMark == "✓" ? .systemGreen : .systemBlue
    color.setFill(); NSBezierPath(ovalIn: frame).fill()
    let font = NSFont.systemFont(ofSize: size * 0.68, weight: .bold), text = vcsMark as NSString
    let dimensions = text.size(withAttributes: [.font: font])
    text.draw(at: NSPoint(x: frame.midX - dimensions.width / 2, y: frame.midY - dimensions.height / 2), withAttributes: [.font: font, .foregroundColor: NSColor.white])
  }
  func refresh() { if let entry { show(entry, pixels: pixels) } }
  func clear() { cancel?(); cancel = nil; entry = nil; vcsMark = nil; image = nil }
  deinit { cancel?() }
}

final class ExplorerCheckbox: NSButton {
  var available = false { didSet { updateVisibility() } }
  var hovered = false { didSet { updateVisibility() } }
  override var state: NSControl.StateValue { didSet { updateVisibility() } }
  private func updateVisibility() { isHidden = !available || (!hovered && state != .on) }
  var changed: ((Bool) -> Void)?
  override init(frame: NSRect) { super.init(frame: frame); setButtonType(.toggle); isBordered = false; title = ""; target = self; action = #selector(toggle) }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func toggle() { changed?(state == .on); updateVisibility(); needsDisplay = true }
  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 1, dy: 1), path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
    (state == .on ? ExplorerPalette.accent : ExplorerPalette.surface).setFill(); path.fill()
    ExplorerPalette.secondary.setStroke(); path.lineWidth = 0.7; path.stroke()
    if state == .on { ExplorerIcons.image("check", size: 11, color: .white).draw(in: rect.insetBy(dx: 1, dy: 1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
  }
}

final class NameCell: NSTableCellView {
  private static let iconSize: CGFloat = 22
  let icon = FileIconView(); let nameLabel = label(""); let checkbox = ExplorerCheckbox()
  var checkboxes = false { didSet { needsLayout = true } }
  override var isFlipped: Bool { true }
  static func textLeading(checkboxes: Bool) -> CGFloat {
    HorizontalFileGeometry.nameLeading(iconLeading: HorizontalFileGeometry.leading(checkboxes: checkboxes), iconSize: iconSize)
  }
  override init(frame: NSRect) {
    super.init(frame: frame); [icon, nameLabel, checkbox].forEach(addSubview)
    icon.imageScaling = .scaleProportionallyUpOrDown; nameLabel.alignment = .left; textField = nameLabel
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout(); checkbox.available = checkboxes
    checkbox.hovered = (superview as? FileRowView)?.hovered ?? false
    checkbox.frame = NSRect(x: 7, y: (bounds.height - 14) / 2, width: 14, height: 14)
    let left = HorizontalFileGeometry.leading(checkboxes: checkboxes), iconSize = Self.iconSize
    icon.frame = NSRect(x: left, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
    let height: CGFloat = max(nameLabel.isEditable ? 24 : 17, ceil(nameLabel.font?.ascender ?? 13) - floor(nameLabel.font?.descender ?? -3) + 2)
    let textLeading = Self.textLeading(checkboxes: checkboxes)
    nameLabel.frame = NSRect(x: textLeading - (nameLabel.isEditable ? 2 : 0), y: (bounds.height - height) / 2, width: max(0, min(nameLabel.isEditable ? 240 : bounds.width, bounds.width - textLeading - MetadataCell.textInset)), height: height)
  }
  func configure(_ entry: FileEntry, name: String? = nil) {
    nameLabel.font = ExplorerTypography.font()
    nameLabel.identifier = NSUserInterfaceItemIdentifier(entry.id)
    nameLabel.stringValue = name ?? entry.name; nameLabel.textColor = ExplorerPalette.text
    alphaValue = entry.isHidden ? 0.6 : 1; toolTip = entry.url.path; icon.show(entry)
  }
  override func prepareForReuse() { super.prepareForReuse(); icon.clear(); checkbox.changed = nil; nameLabel.delegate = nil; nameLabel.abortEditing(); nameLabel.isEditable = false; nameLabel.isSelectable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false }
}
final class TopStackView: NSStackView { override var isFlipped: Bool { true } }
final class MetadataCell: NSTableCellView {
  static let textInset: CGFloat = 12
  let value = label("", color: ExplorerPalette.secondary)
  override var isFlipped: Bool { true }
  override init(frame: NSRect) { super.init(frame: frame); addSubview(value); textField = value }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() { super.layout(); let height = max(17, ceil(value.font?.ascender ?? 13) - floor(value.font?.descender ?? -3) + 2); value.frame = NSRect(x: Self.textInset, y: (bounds.height - height) / 2, width: max(0, bounds.width - 2 * Self.textInset), height: height) }
}
final class ExplorerTableHeaderView: NSTableHeaderView {
  var onMenu: ((NSEvent) -> Void)?
  override func rightMouseDown(with event: NSEvent) { if let onMenu { onMenu(event) } else { super.rightMouseDown(with: event) } }
}

final class ExplorerHeaderCell: NSTableHeaderCell {
  var ascending: Bool?
  var textLeading = MetadataCell.textInset
  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    ExplorerPalette.surface.setFill(); cellFrame.fill()
    let bottomBorderY = cellFrame.maxY - 1
    let contentMidY = (cellFrame.minY + bottomBorderY) / 2
    let titleCell = NSTextFieldCell(textCell: stringValue)
    titleCell.lineBreakMode = .byTruncatingTail; titleCell.font = ExplorerTypography.font()
    titleCell.textColor = ExplorerPalette.secondary; titleCell.alignment = alignment
    let titleSize = titleCell.cellSize
    let arrowSpace: CGFloat = ascending == nil ? 0 : 16
    let left = cellFrame.minX + textLeading, right = cellFrame.maxX - MetadataCell.textInset
    let titleFrame = NSRect(x: left + (alignment == .right ? arrowSpace : 0), y: contentMidY - titleSize.height / 2,
                            width: max(0, right - left - arrowSpace), height: titleSize.height)
    titleCell.draw(withFrame: titleFrame, in: controlView)
    ExplorerPalette.border.setFill()
    let dividerY = cellFrame.minY + 7
    NSRect(x: cellFrame.maxX - 1, y: dividerY, width: 1, height: max(0, bottomBorderY - dividerY - 4)).fill()
    NSRect(x: cellFrame.minX, y: bottomBorderY, width: cellFrame.width, height: 1).fill()
    if let ascending {
      let titleWidth = min(titleFrame.width, titleSize.width)
      let x = alignment == .right ? titleFrame.maxX - titleWidth - arrowSpace : titleFrame.minX + titleWidth + 4
      ExplorerIcons.image(ascending ? "chevronUp" : "chevronDown", size: 12, color: ExplorerPalette.secondary).draw(in: NSRect(x: x, y: contentMidY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
  }
  override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}
final class FileRowView: NSTableRowView {
  var selectionFocused = false { didSet { needsDisplay = true } }
  override var isSelected: Bool { didSet { for column in 0..<numberOfColumns { (view(atColumn: column) as? NameCell)?.checkbox.state = isSelected ? .on : .off } } }
  var hovered = false { didSet { for column in 0..<numberOfColumns { (view(atColumn: column) as? NameCell)?.checkbox.hovered = hovered }; needsDisplay = true } }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    hovered = explorerPointerIsInside(self)
  }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = explorerPointerIsInside(self) }
  override func mouseEntered(with event: NSEvent) { hovered = explorerPointerIsInside(self) }
  override func mouseExited(with event: NSEvent) { hovered = explorerPointerIsInside(self) }
  override func drawBackground(in dirtyRect: NSRect) {
    (hovered && !isSelected ? ExplorerPalette.rowHover : ExplorerPalette.surface).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    if !isSelected { drawFileFocus() }
  }
  override func drawSelection(in dirtyRect: NSRect) {
    let radius: CGFloat = 3
    var shape = bounds
    if let table = enclosingScrollView?.documentView as? FileTableView {
      let row = table.row(for: self)
      let selection = table.selectedRowIndexes
      if row >= 0 {
        let joinsAbove = row > 0 && selection.contains(row - 1)
        let joinsBelow = selection.contains(row + 1)
        if isFlipped ? joinsAbove : joinsBelow { shape.origin.y -= radius; shape.size.height += radius }
        if isFlipped ? joinsBelow : joinsAbove { shape.size.height += radius }
      }
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath.clip(bounds)
    ExplorerPalette.selection.setFill()
    NSBezierPath(roundedRect: shape, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    drawFileFocus()
  }
  private func drawFileFocus() {
    guard selectionFocused, ExplorerFocus.keyboardVisible, window?.isKeyWindow == true, window?.firstResponder is FileTableView else { return }
    drawFileSelectionFocus(bounds)
  }
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
private func drawFileSelectionFocus(_ bounds: NSRect) {
  ExplorerPalette.accent.withAlphaComponent(0.65).setStroke()
  NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
}

final class FileTableView: NSTableView, FilePaneDocument {
  var isFileRow: (Int) -> Bool = { _ in true }
  var groupHeaderRows = IndexSet()
  override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
    super.selectRowIndexes(indexes.subtracting(groupHeaderRows), byExtendingSelection: extend)
  }
  var previewSelection: (() -> Void)?; var renameSelection: (() -> Void)?; var trashSelection: (() -> Void)?
  var showFileContextMenu: ((NSEvent) -> Void)?
  weak var selectionManager: SelectionManager?
  private func hitsFileContent(at point: NSPoint, row: Int) -> Bool {
    let column = column(at: point)
    guard column >= 0 else { return false }
    guard let cell = view(atColumn: column, row: row, makeIfNecessary: false) else { return true }
    let location = cell.convert(point, from: self)
    if let name = cell as? NameCell {
      let start = name.checkboxes ? name.checkbox.frame.minX : name.icon.frame.minX
      let prefix = NSRect(x: start, y: 0, width: name.nameLabel.frame.minX - start, height: name.bounds.height)
      return prefix.contains(location) || HorizontalFileGeometry.textHit(name.nameLabel, at: location)
    }
    if let metadata = cell as? MetadataCell { return HorizontalFileGeometry.textHit(metadata.value, at: location) }
    return true
  }
  func selectableItem(at point: NSPoint) -> FilePaneHit {
    guard bounds.contains(point) else { return .background }
    let row = row(at: point)
    guard row >= 0 else { return .background }
    guard isFileRow(row) else { return .group(row) }
    return .file(row)
  }

  func isClickInItemWhitespace(at point: NSPoint, row: Int) -> Bool {
    !hitsFileContent(at: point, row: row)
  }

  func fileRows(intersecting rect: NSRect) -> IndexSet {
    let rows = rows(in: rect)
    guard rows.location != NSNotFound, rows.length > 0 else { return [] }
    let candidates = IndexSet(integersIn: rows.location..<min(numberOfRows, NSMaxRange(rows)))
    return IndexSet(candidates.filter { isFileRow($0) && self.rect(ofRow: $0).intersects(rect) })
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    showFileContextMenu?(event)
    return nil
  }
  override func keyDown(with event: NSEvent) {
    guard NativeSelection.canHandle(self), let selectionManager else { super.keyDown(with: event); return }
    if event.keyCode == 53 {
      selectionManager.SelectionChange(.clear)
      return
    }
    let flags = FileSelectionModifiers(event.modifierFlags)
    if event.keyCode == 49, selectionManager._HandleSpaceKey(flags, fallbackRow: selectedRowIndexes.last) { return }
    if [115, 119, 125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .option]).isEmpty, numberOfRows > 0 {
      let previous = selectionManager.focusedRow(fallback: selectedRowIndexes.last) ?? -1
      guard let next = nextFileRow(key: event.keyCode, previous: previous, count: numberOfRows, accepts: isFileRow) else { return }
      selectionManager.UserMovedFocusWithKeyboard(to: next, modifiers: flags)
      scrollRowToVisible(next)
      return
    }
    if event.keyCode == 36 || event.keyCode == 76 { renameSelection?(); return }
    if event.keyCode == 49 { previewSelection?(); return }
    if event.keyCode == 120 { renameSelection?(); return }
    if event.keyCode == 51 && event.modifierFlags.contains(.command) { trashSelection?(); return }
    super.keyDown(with: event)
  }
}
final class FileCollectionView: NSCollectionView, FilePaneDocument {
  override func reloadData() {
    for view in subviews where view is NativeExpandedNameView { view.removeFromSuperview() }
    super.reloadData()
  }

  override func setFrameSize(_ newSize: NSSize) {
    var size = newSize
    if let layout = collectionViewLayout as? ExplorerCollectionLayout, layout.mode == .list {
      // NSCollectionView can propose the viewport width during relayout. Horizontal
      // List content must keep its full document width for NSClipView to scroll it.
      size.width = max(size.width, layout.collectionViewContentSize.width)
    }
    super.setFrameSize(size)
  }
  var isFileRow: (Int) -> Bool = { _ in true }
  var listFileName: (Int) -> String? = { _ in nil }
  var listCheckboxesEnabled: () -> Bool = { false }
  var previewSelection: (() -> Void)?; var renameSelection: (() -> Void)?; var trashSelection: (() -> Void)?
  var showFileContextMenu: ((NSEvent) -> Void)?
  weak var selectionManager: SelectionManager?
  func refreshExpandedNames() { for item in visibleItems() { item.view.needsLayout = true } }
  override func menu(for event: NSEvent) -> NSMenu? {
    showFileContextMenu?(event)
    return nil
  }

  override func keyDown(with event: NSEvent) {
    guard NativeSelection.canHandle(self), let selectionManager else { super.keyDown(with: event); return }
    if event.keyCode == 53 {
      selectionManager.SelectionChange(.clear)
      return
    }
    let flags = FileSelectionModifiers(event.modifierFlags)
    if event.keyCode == 49, selectionManager._HandleSpaceKey(flags, fallbackRow: selectionIndexPaths.lazy.map(\.item).max()) { return }
    if [115, 119, 123, 124, 125, 126].contains(event.keyCode),
       event.modifierFlags.intersection([.command, .option]).isEmpty, numberOfSections > 0 {
      let count = numberOfItems(inSection: 0), previous = selectionManager.focusedRow(fallback: selectionIndexPaths.lazy.map(\.item).max()) ?? -1
      let next: Int?
      if [115, 119].contains(event.keyCode) || previous < 0 {
        next = nextFileRow(key: event.keyCode, previous: previous, count: count, accepts: isFileRow)
      } else {
        next = (collectionViewLayout as? ExplorerCollectionLayout)?.neighbor(of: previous, key: event.keyCode, accepts: isFileRow)
      }
      guard let next else { return }
      selectionManager.UserMovedFocusWithKeyboard(to: next, modifiers: flags)
      scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge))
      return
    }
    if event.keyCode == 36 || event.keyCode == 76 { renameSelection?(); return }
    if event.keyCode == 49 { previewSelection?(); return }
    if event.keyCode == 120 { renameSelection?(); return }
    if event.keyCode == 51 && event.modifierFlags.contains(.command) { trashSelection?(); return }
    super.keyDown(with: event)
  }
  func selectableItem(at point: NSPoint) -> FilePaneHit {
    guard let indexPath = indexPathForItem(at: point),
          let frame = layoutAttributesForItem(at: indexPath)?.frame, frame.contains(point) else { return .background }
    return isFileRow(indexPath.item) ? .file(indexPath.item) : .group(indexPath.item)
  }

  func isClickInItemWhitespace(at point: NSPoint, row: Int) -> Bool {
    guard (collectionViewLayout as? ExplorerCollectionLayout)?.mode == .list,
          let frame = layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame else { return false }
    return !HorizontalFileGeometry.listHit(in: frame, checkboxes: listCheckboxesEnabled(), name: listFileName(row),
                                           where: { $0.contains(point) })
  }

  func fileRows(intersecting rect: NSRect) -> IndexSet {
    guard let layout = collectionViewLayout else { return [] }
    return IndexSet(layout.layoutAttributesForElements(in: rect).compactMap { attributes in
      guard let row = attributes.indexPath?.item, isFileRow(row) else { return nil }
      return row
    })
  }
}

private enum HorizontalFileGeometry {
  static let listIconSize: CGFloat = 16
  static let listIconLeading: CGFloat = 32
  static let listNameLeading = listIconLeading + listIconSize + 2
  static let listTrailing: CGFloat = 6
  static func leading(checkboxes: Bool) -> CGFloat { checkboxes ? 30 : 12 }
  static func nameLeading(iconLeading: CGFloat, iconSize: CGFloat) -> CGFloat { iconLeading + iconSize + 9 }
  static func nameWidth(in width: CGFloat, leading: CGFloat) -> CGFloat { max(20, width - leading - 12) }

  private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4
  }

  static func listWidth(for names: [String]) -> CGFloat {
    let font = ExplorerTypography.font()
    let labelWidth = names.lazy.map { textWidth($0, font: font) }.max() ?? 0
    return listNameLeading + max(20, labelWidth) + listTrailing
  }

  static func textHit(_ label: NSTextField, at point: NSPoint) -> Bool {
    guard label.frame.contains(point), !label.stringValue.isEmpty, let font = label.font else { return false }
    var rect = label.frame
    rect.size.width = min(rect.width, textWidth(label.stringValue, font: font))
    if label.alignment == .right { rect.origin.x = label.frame.maxX - rect.width }
    return rect.contains(point)
  }

  static func listHit(in frame: NSRect, checkboxes: Bool, name: @autoclosure () -> String?,
                      where test: (NSRect) -> Bool) -> Bool {
    if checkboxes, test(NSRect(x: frame.minX + 7, y: frame.midY - 7, width: 14, height: 14)) { return true }
    let iconArea = NSRect(x: frame.minX + listIconLeading, y: frame.minY,
                          width: listNameLeading - listIconLeading, height: frame.height)
    if test(iconArea.intersection(frame)) { return true }
    let nameArea = NSRect(x: frame.minX + listNameLeading, y: frame.minY,
                          width: max(0, frame.width - listNameLeading - listTrailing), height: frame.height)
    guard test(nameArea), let name = name() else { return false }
    var textArea = nameArea
    textArea.size.width = min(textArea.width, textWidth(name, font: ExplorerTypography.font()))
    return test(textArea)
  }
}

enum ExplorerLayoutMode: String { case details, icons, list, tiles, content }
final class ExplorerCollectionLayout: NSCollectionViewLayout {
  var mode: ExplorerLayoutMode = .icons
  var iconSize: CGFloat = 64
  var compact = false
  var groupHeaderRows = Set<Int>()
  private var groupedFrames: [NSRect] = []
  private var count = 0
  private var columns = 1
  private var rows = 1
  private var cell = NSSize.zero
  private var inset = NSSize.zero
  private var gap = NSSize.zero
  private var contentSize = NSSize.zero
  override func prepare() {
    guard let collectionView else { return }
    count = collectionView.numberOfSections == 0 ? 0 : collectionView.numberOfItems(inSection: 0)
    let viewport = collectionView.enclosingScrollView?.contentSize ?? collectionView.bounds.size
    switch mode {
    case .list:
      inset = NSSize(width: 14, height: 6); gap = NSSize(width: 10, height: 1)
      cell.height = max(compact ? 28 : 32, ExplorerTypography.rowHeight)
      rows = max(1, Int((viewport.height - 2 * inset.height + gap.height) / (cell.height + gap.height)))
      let files = collectionView as? FileCollectionView
      cell.width = HorizontalFileGeometry.listWidth(for: (0..<min(count, rows)).compactMap { files?.listFileName($0) })
      columns = max(1, (count + rows - 1) / rows)
      let width = 2 * inset.width + CGFloat(columns) * (cell.width + gap.width) - gap.width
      contentSize = NSSize(width: max(viewport.width, width), height: viewport.height)
    case .content:
      inset = NSSize(width: 10, height: 6); gap = .zero; columns = 1; cell = NSSize(width: max(100, viewport.width - 20), height: max(compact ? 66 : 78, ExplorerTypography.lineHeight * 2 + 16))
      contentSize = NSSize(width: viewport.width, height: max(viewport.height, CGFloat(count) * cell.height + 20))
    default:
      let horizontal = mode == .tiles || iconSize == 32
      inset = NSSize(width: horizontal ? 10 : 14, height: horizontal ? 8 : compact ? 8 : 12)
      gap = NSSize(width: horizontal ? 4 : 3, height: horizontal ? 2 : compact ? 1 : 4)
      let minimum: CGFloat = horizontal ? 220 : max(iconSize + 32, ExplorerTypography.baseSize * 6 + 32)
      columns = max(1, Int((viewport.width - inset.width * 2 + gap.width) / (minimum + gap.width)))
      let width = max(40, (viewport.width - inset.width * 2 - CGFloat(columns - 1) * gap.width) / CGFloat(columns))
      let height: CGFloat = mode == .tiles ? max(compact ? 56 : 66, ExplorerTypography.lineHeight * 2 + 16) : iconSize == 32 ? max(compact ? 34 : 38, ExplorerTypography.rowHeight) : iconSize + max(compact ? 44 : 50, ExplorerTypography.lineHeight * 2 + 20)
      cell = NSSize(width: width, height: height); rows = max(1, Int(ceil(Double(count) / Double(columns))))
      contentSize = NSSize(width: viewport.width, height: max(viewport.height, inset.height + CGFloat(rows) * (height + gap.height) + 30))
    }
    groupedFrames.removeAll(keepingCapacity: true)
    if !groupHeaderRows.isEmpty {
      if mode == .list {
        let width = max(1, viewport.width - 2 * inset.width)
        cell.width = min(cell.width, width)
        columns = max(1, Int((width + gap.width) / (cell.width + gap.width)))
      }
      var y = inset.height, column = 0
      groupedFrames.reserveCapacity(count)
      for index in 0..<count {
        if groupHeaderRows.contains(index) {
          if column > 0 { y += cell.height + gap.height; column = 0 }
          groupedFrames.append(NSRect(x: 8, y: y, width: max(0, viewport.width - 16), height: max(38, ExplorerTypography.rowHeight))); y += max(38, ExplorerTypography.rowHeight) + 4
        } else {
          groupedFrames.append(NSRect(x: inset.width + CGFloat(column) * (cell.width + gap.width), y: y, width: cell.width, height: cell.height))
          column += 1
          if column == columns { column = 0; y += cell.height + gap.height }
        }
      }
      if column > 0 { y += cell.height + gap.height }
      contentSize = NSSize(width: viewport.width, height: max(viewport.height, y + 20))
    }
  }
  override var collectionViewContentSize: NSSize { contentSize }
  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { newBounds.size != collectionView?.bounds.size }
  override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < count else { return nil }
    if !groupHeaderRows.isEmpty {
      guard groupedFrames.indices.contains(indexPath.item) else { return nil }
      let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath); attributes.frame = groupedFrames[indexPath.item]; return attributes
    }
    let column = mode == .list ? indexPath.item / rows : indexPath.item % columns
    let row = mode == .list ? indexPath.item % rows : indexPath.item / columns
    let value = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
    value.frame = NSRect(x: inset.width + CGFloat(column) * (cell.width + gap.width), y: inset.height + CGFloat(row) * (cell.height + gap.height), width: cell.width, height: cell.height)
    return value
  }
  override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
    guard NSRect(origin: .zero, size: contentSize).contains(point) else { return nil }
    if !groupHeaderRows.isEmpty {
      return layoutAttributesForElements(in: NSRect(x: point.x, y: point.y, width: 1, height: 1)).first { $0.frame.contains(point) }
        ?? layoutAttributesForInterItemGap(before: IndexPath(item: count, section: 0))
    }
    let column = max(0, Int((point.x - inset.width) / (cell.width + gap.width)))
    let row = max(0, Int((point.y - inset.height) / (cell.height + gap.height)))
    let item = mode == .list ? column * rows + row : row * columns + column
    if let value = layoutAttributesForItem(at: IndexPath(item: item, section: 0)), value.frame.contains(point) { return value }
    return layoutAttributesForInterItemGap(before: IndexPath(item: count, section: 0))
  }
  override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    guard indexPath.section == 0, (0...count).contains(indexPath.item) else { return nil }
    let value = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
    value.isHidden = true
    return value
  }
  func neighbor(of index: Int, key: UInt16, accepts: (Int) -> Bool) -> Int? {
    guard (0..<count).contains(index) else { return nil }
    let horizontal = key == 123 || key == 124
    let direction = key == 124 || key == 125 ? 1 : -1
    if groupHeaderRows.isEmpty {
      let step = mode == .list ? (horizontal ? rows : 1) : (horizontal ? 1 : columns)
      let next = index + direction * step
      guard (0..<count).contains(next), accepts(next) else { return nil }
      if mode == .list, !horizontal, index / rows != next / rows { return nil }
      if mode != .list, horizontal, index / columns != next / columns { return nil }
      return next
    }
    guard groupedFrames.indices.contains(index) else { return nil }
    let frame = groupedFrames[index]
    for candidate in stride(from: index + direction, to: direction > 0 ? groupedFrames.count : -1, by: direction) {
      let next = groupedFrames[candidate]
      if horizontal {
        guard next.midY == frame.midY else { return nil }
        if accepts(candidate) { return candidate }
      } else if abs(next.midY - frame.midY) >= frame.height,
                next.maxX > frame.minX, next.minX < frame.maxX, accepts(candidate) {
        return candidate
      }
    }
    return nil
  }

  override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
    guard count > 0 else { return [] }
    var output: [NSCollectionViewLayoutAttributes] = []
    if !groupHeaderRows.isEmpty {
      // Frames have monotonically increasing Y extents. Binary search keeps scrolling
      // proportional to visible items, rather than scanning a large directory.
      var low = 0, high = groupedFrames.count
      while low < high { let mid = (low + high) / 2; if groupedFrames[mid].maxY < rect.minY { low = mid + 1 } else { high = mid } }
      var index = low
      while index < groupedFrames.count && groupedFrames[index].minY <= rect.maxY {
        if groupedFrames[index].intersects(rect), let a = layoutAttributesForItem(at: IndexPath(item: index, section: 0)) { output.append(a) }; index += 1
      }
      return output
    }
    if mode == .list {
      let pitch = cell.width + gap.width
      let first = max(0, Int((rect.minX - inset.width) / pitch))
      let last = min(columns - 1, Int((rect.maxX - inset.width) / pitch))
      if first <= last { for index in (first * rows)..<min(count, (last + 1) * rows) { if let a = layoutAttributesForItem(at: IndexPath(item: index, section: 0)), a.frame.intersects(rect) { output.append(a) } } }
    } else {
      let first = max(0, Int((rect.minY - inset.height) / (cell.height + gap.height))); let last = max(first, Int(rect.maxY / (cell.height + gap.height)) + 1)
      let start = min(count, first * columns), end = min(count, (last + 1) * columns)
      if start < end { for index in start..<end { if let a = layoutAttributesForItem(at: IndexPath(item: index, section: 0)), a.frame.intersects(rect) { output.append(a) } } }
    }
    return output
  }
}
final class ItemSurface: SurfaceView {
  var desktopAppearance = false
  var selected = false {
    didSet {
      if !selected { removeExpandedName() }
      needsDisplay = true
      needsLayout = true
    }
  }
  var hovered = false { didSet { subviews.compactMap { $0 as? ExplorerCheckbox }.forEach { $0.hovered = hovered }; needsDisplay = true } }
  var bottomLine = false
  var selectionFocused = false { didSet { needsDisplay = true } }
  private weak var expandedName: NativeExpandedNameView?
  private var scrollObserver: NSObjectProtocol?
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = explorerPointerIsInside(self); if window == nil { removeExpandedName(); if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }; scrollObserver = nil } }
  deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

  private func removeExpandedName() {
    expandedName?.removeFromSuperview()
    expandedName = nil
  }

  override func layout() {
    super.layout(); removeExpandedName()
    guard selected, window != nil, let name = subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier != nil }),
          !name.isEditable, name.alignment == .center, name.maximumNumberOfLines == 2, name.frame.minY > 40 else { return }
    var ancestor = superview
    while ancestor != nil, !(ancestor is FileCollectionView) { ancestor = ancestor?.superview }
    guard let collection = ancestor as? FileCollectionView, collection.selectionManager?.isMarqueeActive != true else { return }
    if scrollObserver == nil, let clip = collection.enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
    }
    let rect = convert(name.frame, to: collection)
    guard convert(bounds, to: collection).intersects(collection.visibleRect), rect.intersects(collection.visibleRect) else { return }
    let overlay = NativeExpandedNameView(name: name, selected: true)
    let measured = overlay.text.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, rect.width - 4), height: 10_000))
    guard measured.height > rect.height else { return }
    let itemRect = convert(bounds, to: collection)
    overlay.frame = NSRect(x: itemRect.minX, y: rect.minY, width: itemRect.width, height: ceil(measured.height) + 4)
    collection.addSubview(overlay); expandedName = overlay
  }
  override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)); hovered = explorerPointerIsInside(self) }
  override func mouseEntered(with event: NSEvent) { hovered = explorerPointerIsInside(self) }
  override func mouseExited(with event: NSEvent) { hovered = explorerPointerIsInside(self) }
  override func draw(_ dirtyRect: NSRect) {
    color.setFill(); bounds.fill()
    if selected || hovered { (selected ? ExplorerPalette.selection : ExplorerPalette.rowHover).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    if desktopAppearance, let name = subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier != nil }), !name.isEditable {
      let measured = (name.stringValue as NSString).boundingRect(with: NSSize(width: max(1, name.frame.width - 4), height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: name.font ?? NSFont.systemFont(ofSize: 12)])
      let width = min(name.frame.width, ceil(measured.width) + 8), height = min(name.frame.height, ceil(measured.height) + 4)
      NSColor.black.withAlphaComponent(0.7).setFill()
      NSBezierPath(roundedRect: NSRect(x: name.frame.midX - width / 2, y: name.frame.minY, width: width, height: height), xRadius: 3, yRadius: 3).fill()
    }
    if bottomLine { ExplorerPalette.border.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
    if selectionFocused, ExplorerFocus.keyboardVisible, window?.isKeyWindow == true, window?.firstResponder is FileCollectionView {
      drawFileSelectionFocus(bounds)
    }
  }
}
final class IconItem: NSCollectionViewItem {
  let icon = FileIconView(); let nameLabel = label(""); let kindLabel = label("", size: 11, color: ExplorerPalette.secondary); let dateLabel = label("", size: 11, color: ExplorerPalette.secondary); let pathLabel = label("", size: 11, color: ExplorerPalette.secondary)
  let checkbox = ExplorerCheckbox()
  private let surface = ItemSurface()
  var selectionFocused: Bool {
    get { surface.selectionFocused }
    set { surface.selectionFocused = newValue }
  }
  var mode: ExplorerLayoutMode = .icons; var iconSize: CGFloat = 64; var checkboxes = false
  override func loadView() { view = surface; [icon, nameLabel, kindLabel, dateLabel, pathLabel, checkbox].forEach(view.addSubview); icon.imageScaling = .scaleProportionallyUpOrDown }
  override var isSelected: Bool { didSet { surface.selected = isSelected; checkbox.state = isSelected ? .on : .off } }
  override func viewDidLayout() {
    super.viewDidLayout(); let width = view.bounds.width, height = view.bounds.height
    let horizontal = mode != .icons || iconSize == 32
    let size: CGFloat = mode == .list ? HorizontalFileGeometry.listIconSize : mode == .tiles ? 48 : mode == .content ? 56 : iconSize
    let leading = mode == .list ? HorizontalFileGeometry.listIconLeading : HorizontalFileGeometry.leading(checkboxes: checkboxes && horizontal)
    checkbox.available = checkboxes; checkbox.hovered = surface.hovered; checkbox.frame = NSRect(x: 7, y: horizontal ? (height - 14) / 2 : 8, width: 14, height: 14)
    nameLabel.alignment = horizontal ? .left : .center; nameLabel.maximumNumberOfLines = horizontal ? 1 : 2
    nameLabel.lineBreakMode = horizontal ? .byTruncatingTail : nameLabel.isEditable ? .byCharWrapping : .byWordWrapping
    nameLabel.cell?.truncatesLastVisibleLine = !nameLabel.isEditable
    kindLabel.isHidden = mode != .tiles && mode != .content; dateLabel.isHidden = mode != .content; pathLabel.isHidden = mode != .content
    surface.bottomLine = mode == .content
    if horizontal {
      icon.frame = NSRect(x: leading, y: (height - size) / 2, width: size, height: size)
      let textX = mode == .list ? HorizontalFileGeometry.listNameLeading : HorizontalFileGeometry.nameLeading(iconLeading: leading, iconSize: size)
      let textWidth = mode == .list ? max(0, width - textX - HorizontalFileGeometry.listTrailing) :
        HorizontalFileGeometry.nameWidth(in: mode == .content ? width * 0.55 : width, leading: textX)
      let twoLines = mode == .tiles || mode == .content
      let line = ExplorerTypography.lineHeight
      let top = height / 2 - (twoLines ? line + 2 : line / 2)
      nameLabel.frame = NSRect(x: textX, y: top, width: textWidth, height: line)
      kindLabel.frame = NSRect(x: textX, y: top + line + 4, width: textWidth, height: line)
      dateLabel.frame = NSRect(x: width * 0.57, y: top, width: width * 0.43 - 12, height: line)
      pathLabel.frame = NSRect(x: width * 0.57, y: top + line + 4, width: width * 0.43 - 12, height: line)
    } else {
      icon.frame = NSRect(x: (width - size) / 2, y: 8, width: size, height: size)
      nameLabel.frame = NSRect(x: 5, y: size + 14, width: width - 10, height: max(36, ExplorerTypography.lineHeight * 2))
    }
  }
  func configure(_ entry: FileEntry, name: String? = nil, mode: ExplorerLayoutMode = .icons, size: CGFloat = 64, checkboxes: Bool = false) {
    _ = view; nameLabel.font = ExplorerTypography.font(); for label in [kindLabel, dateLabel, pathLabel] { label.font = ExplorerTypography.font(ofSize: 11) }; self.mode = mode; iconSize = size; self.checkboxes = checkboxes
    nameLabel.identifier = NSUserInterfaceItemIdentifier(entry.id)
    nameLabel.stringValue = name ?? entry.name; kindLabel.stringValue = entry.kind + (entry.isDirectory ? "" : " · \(ExplorerFormat.size(entry.size))")
    dateLabel.stringValue = NL("修改日期：") + (entry.modified?.formatted(.dateTime.year().month().day()) ?? "—")
    pathLabel.stringValue = NL("位置：") + entry.url.deletingLastPathComponent().path
    view.toolTip = entry.url.path; icon.show(entry, pixels: size > 64 ? 256 : size > 32 ? 128 : 64); surface.selected = isSelected; view.needsLayout = true
    view.setAccessibilityLabel(entry.name)
  }
  func setDesktopAppearance() {
    surface.desktopAppearance = true
    surface.color = .clear
    nameLabel.textColor = .white
    nameLabel.drawsBackground = false
    // Desktop layer updates can request custom image reps without a graphics context.
    if let image = icon.image {
      let pixels = Int(iconSize * (view.window?.backingScaleFactor ?? 2))
      if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) {
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        if let cgImage = bitmap.cgImage { icon.image = NSImage(cgImage: cgImage, size: NSSize(width: iconSize, height: iconSize)) }
      }
    }
  }
  override func prepareForReuse() { super.prepareForReuse(); surface.selected = false; icon.clear(); checkbox.changed = nil; nameLabel.delegate = nil; nameLabel.abortEditing(); nameLabel.isEditable = false; nameLabel.isSelectable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false }
}
