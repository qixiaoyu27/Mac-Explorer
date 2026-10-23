import AppKit
import ExplorerCore

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

final class ExplorerTabBar: SurfaceView {
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
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

final class ExplorerRootView: SurfaceView {
  var onLayout: (() -> Void)?
  override func layout() { super.layout(); onLayout?() }
  override var mouseDownCanMoveWindow: Bool { false }
}

class ExplorerTextField: NSTextField {
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
    super.draw(dirtyRect)
    NSGraphicsContext.restoreGraphicsState()
  }
}

func label(_ text: String, size: CGFloat = 12, color: NSColor = ExplorerPalette.text) -> NSTextField {
  let field = ExplorerTextField(labelWithString: text)
  field.font = NSFont(name: "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size, weight: .regular); field.textColor = color; field.lineBreakMode = .byTruncatingTail
  return field
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
    let key = "\(entry.url.path)|\(entry.modified?.timeIntervalSince1970 ?? 0)|\(pixels)"
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
  func show(_ entry: FileEntry, pixels: Int = 64) {
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
  func clear() { cancel?(); cancel = nil; vcsMark = nil; image = nil }
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
  let icon = FileIconView(); let nameLabel = label(""); let checkbox = ExplorerCheckbox()
  var checkboxes = false { didSet { needsLayout = true } }
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame); [icon, nameLabel, checkbox].forEach(addSubview)
    icon.imageScaling = .scaleProportionallyUpOrDown; textField = nameLabel
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout(); checkbox.available = checkboxes
    checkbox.hovered = (superview as? FileRowView)?.hovered ?? false
    checkbox.frame = NSRect(x: 7, y: (bounds.height - 14) / 2, width: 14, height: 14)
    let left: CGFloat = checkboxes ? 30 : 12
    icon.frame = NSRect(x: left, y: (bounds.height - 22) / 2, width: 22, height: 22)
    let height: CGFloat = nameLabel.isEditable ? 24 : 17
    nameLabel.frame = NSRect(x: left + 31 - (nameLabel.isEditable ? 2 : 0), y: (bounds.height - height) / 2, width: max(0, min(nameLabel.isEditable ? 240 : bounds.width, bounds.width - left - 43)), height: height)
  }
  func configure(_ entry: FileEntry, name: String? = nil) {
    nameLabel.identifier = NSUserInterfaceItemIdentifier(entry.id)
    nameLabel.stringValue = name ?? entry.name; nameLabel.textColor = ExplorerPalette.text
    alphaValue = entry.isHidden ? 0.6 : 1; toolTip = entry.url.path; icon.show(entry)
  }
  override func prepareForReuse() { super.prepareForReuse(); icon.clear(); checkbox.changed = nil; nameLabel.delegate = nil; nameLabel.abortEditing(); nameLabel.isEditable = false; nameLabel.isSelectable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false }
}
final class TopStackView: NSStackView { override var isFlipped: Bool { true } }
final class MetadataCell: NSTableCellView {
  let value = label("", color: ExplorerPalette.secondary)
  override var isFlipped: Bool { true }
  override init(frame: NSRect) { super.init(frame: frame); addSubview(value); textField = value }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() { super.layout(); value.frame = NSRect(x: 12, y: (bounds.height - 17) / 2, width: max(0, bounds.width - 24), height: 17) }
}
final class ExplorerTableHeaderView: NSTableHeaderView {
  var onMenu: ((NSEvent) -> Void)?
  override func rightMouseDown(with event: NSEvent) { if let onMenu { onMenu(event) } else { super.rightMouseDown(with: event) } }
}

final class ExplorerHeaderCell: NSTableHeaderCell {
  var ascending: Bool?
  override func draw(withFrame fullFrame: NSRect, in controlView: NSView) {
    ExplorerPalette.surface.setFill(); fullFrame.fill()
    let cellFrame = NSRect(x: fullFrame.minX, y: fullFrame.minY, width: fullFrame.width, height: fullFrame.height - 4)
    NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
    let text = stringValue as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ExplorerPalette.secondary]
    let isSize = stringValue == NL("大小")
    let x = isSize ? cellFrame.maxX - text.size(withAttributes: attrs).width - 12 : cellFrame.minX + 12
    text.draw(at: NSPoint(x: x, y: cellFrame.midY - 8), withAttributes: attrs)
    ExplorerPalette.border.setFill()
    NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 7, width: 1, height: 25).fill()
    NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
    if let ascending {
      ExplorerIcons.image(ascending ? "chevronUp" : "chevronDown", size: 12, color: ExplorerPalette.secondary).draw(in: NSRect(x: x + text.size(withAttributes: attrs).width + 8, y: cellFrame.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
  }
  override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {}
}
final class FileRowView: NSTableRowView {
  var hovered = false { didSet { for column in 0..<numberOfColumns { (view(atColumn: column) as? NameCell)?.checkbox.hovered = hovered }; needsDisplay = true } }
  override func updateTrackingAreas() {
    super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func drawBackground(in dirtyRect: NSRect) {
    ExplorerPalette.surface.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
  }
  override func drawSelection(in dirtyRect: NSRect) {
    ExplorerPalette.selection.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    if isEmphasized && ExplorerFocus.keyboardVisible { ExplorerPalette.accent.withAlphaComponent(0.25).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke() }
  }
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
final class FileTableView: NSTableView {
  var openSelection: (() -> Void)?; var previewSelection: (() -> Void)?; var showContext: ((NSEvent) -> Void)?; var renameSelection: (() -> Void)?; var trashSelection: (() -> Void)?
  private var marquee: NativeMarqueeSelection?
  private var selectionCursor: Int?
  private var selectionAnchor: Int?
  func cancelMarqueeSelection() { marquee?.end(cancelled: false); marquee = nil }
  override func reloadData() { cancelMarqueeSelection(); selectionCursor = nil; selectionAnchor = nil; super.reloadData() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { cancelMarqueeSelection() } }
  override func mouseDown(with event: NSEvent) {
    guard NativeSelection.canHandle(self) else { super.mouseDown(with: event); return }
    let point = convert(event.locationInWindow, from: nil), clicked = row(at: point)
    if clicked < 0, visibleRect.contains(point) {
      window?.makeFirstResponder(self)
      let previousAnchor = selectionAnchor
      if event.modifierFlags.intersection([.command, .control, .shift]).isEmpty { selectionAnchor = nil }
      let frames = (0..<numberOfRows).map { ($0, rect(ofRow: $0)) }
      marquee = NativeMarqueeSelection(host: self, event: event, original: Set(selectedRowIndexes), targets: frames, apply: { [weak self] selection in guard let self, self.selectedRowIndexes != IndexSet(selection) else { return }; self.selectRowIndexes(IndexSet(selection), byExtendingSelection: false) }, finished: { [weak self] in if self?.marquee?.wasCancelled == true { self?.selectionAnchor = previousAnchor }; self?.marquee = nil })
      marquee?.begin(); return
    }
    let original = Set(selectedRowIndexes), anchor = selectionAnchor
    if clicked >= 0 { selectionCursor = clicked; if !event.modifierFlags.contains(.shift) { selectionAnchor = clicked } }
    super.mouseDown(with: NativeSelection.commandClick(event))
    if clicked >= 0, !event.modifierFlags.intersection([.command, .control, .shift]).isEmpty {
      selectRowIndexes(IndexSet(NativeSelection.click(clicked, anchor: anchor, original: original, flags: event.modifierFlags)), byExtendingSelection: false)
    }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let clicked = row(at: convert(event.locationInWindow, from: nil))
    if clicked >= 0 && !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
    if clicked < 0 { deselectAll(nil) }
    showContext?(event); return nil
  }
  override func keyDown(with event: NSEvent) {
    guard NativeSelection.canHandle(self) else { super.keyDown(with: event); return }
    if event.keyCode == 53 { if marquee != nil { marquee?.end(cancelled: true) } else { deselectAll(nil); selectionCursor = nil; selectionAnchor = nil }; return }
    if [115, 119, 125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty, numberOfRows > 0 {
      let previous = selectionCursor ?? selectedRowIndexes.last ?? -1
      let next = event.keyCode == 115 ? 0 : event.keyCode == 119 ? numberOfRows - 1 : max(0, min(numberOfRows - 1, previous + (event.keyCode == 125 ? 1 : -1)))
      selectRowIndexes(IndexSet(integer: next), byExtendingSelection: event.modifierFlags.contains(.shift)); selectionCursor = next; selectionAnchor = next; scrollRowToVisible(next); return
    }
    if event.keyCode == 36 || event.keyCode == 76 { renameSelection?(); return }
    if event.keyCode == 49 { previewSelection?(); return }
    if event.keyCode == 120 { renameSelection?(); return }
    if event.keyCode == 51 && event.modifierFlags.contains(.command) { trashSelection?(); return }
    super.keyDown(with: event)
  }
}
final class FileCollectionView: NSCollectionView {
  override func setFrameSize(_ newSize: NSSize) {
    var size = newSize
    if let layout = collectionViewLayout as? ExplorerCollectionLayout, layout.mode == .list {
      // NSCollectionView can propose the viewport width during relayout. Horizontal
      // List content must keep its full document width for NSClipView to scroll it.
      size.width = max(size.width, layout.collectionViewContentSize.width)
    }
    super.setFrameSize(size)
  }
  var openSelection: (() -> Void)?; var previewSelection: (() -> Void)?; var showContext: ((NSEvent) -> Void)?; var renameSelection: (() -> Void)?; var trashSelection: (() -> Void)?
  private var marquee: NativeMarqueeSelection?
  private var selectionCursor: Int?
  private var selectionAnchor: Int?
  private(set) var isMarqueeSelecting = false
  func cancelMarqueeSelection() { marquee?.end(cancelled: false); marquee = nil }
  override func reloadData() { cancelMarqueeSelection(); selectionCursor = nil; selectionAnchor = nil; super.reloadData() }
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { cancelMarqueeSelection() } }
  private func applySelection(_ indexes: Set<Int>) {
    let previous = selectionIndexPaths, next = Set(indexes.map { IndexPath(item: $0, section: 0) })
    guard previous != next else { return }; selectionIndexPaths = next
    delegate?.collectionView?(self, didDeselectItemsAt: previous.subtracting(next)); delegate?.collectionView?(self, didSelectItemsAt: next.subtracting(previous))
  }
  private func refreshExpandedNames() { for item in visibleItems() { item.view.needsLayout = true } }
  override func menu(for event: NSEvent) -> NSMenu? {
    if indexPathForItem(at: convert(event.locationInWindow, from: nil)) == nil {
      let previous = selectionIndexPaths; selectionIndexPaths = []; delegate?.collectionView?(self, didDeselectItemsAt: previous)
    }
    if let clicked = indexPathForItem(at: convert(event.locationInWindow, from: nil)), !selectionIndexPaths.contains(clicked) {
      let previous = selectionIndexPaths; selectionIndexPaths = [clicked]
      delegate?.collectionView?(self, didDeselectItemsAt: previous); delegate?.collectionView?(self, didSelectItemsAt: [clicked])
    }
    showContext?(event); return nil
  }
  override func keyDown(with event: NSEvent) {
    guard NativeSelection.canHandle(self) else { super.keyDown(with: event); return }
    if event.keyCode == 53 { if marquee != nil { marquee?.end(cancelled: true) } else { applySelection([]); selectionCursor = nil; selectionAnchor = nil }; return }
    if [115, 119, 125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .control, .option]).isEmpty, numberOfSections > 0, numberOfItems(inSection: 0) > 0 {
      let count = numberOfItems(inSection: 0), previous = selectionCursor ?? selectionIndexPaths.map(\.item).max() ?? -1
      let next = event.keyCode == 115 ? 0 : event.keyCode == 119 ? count - 1 : max(0, min(count - 1, previous + (event.keyCode == 125 ? 1 : -1)))
      let paths = event.modifierFlags.contains(.shift) ? Set(selectionIndexPaths.map(\.item)).union([next]) : [next]
      applySelection(paths); selectionCursor = next; selectionAnchor = next; scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge.union(.nearestVerticalEdge)); return
    }
    if event.keyCode == 36 || event.keyCode == 76 { renameSelection?(); return }
    if event.keyCode == 49 { previewSelection?(); return }
    if event.keyCode == 120 { renameSelection?(); return }
    if event.keyCode == 51 && event.modifierFlags.contains(.command) { trashSelection?(); return }
    super.keyDown(with: event)
  }
  override func mouseDown(with event: NSEvent) {
    guard NativeSelection.canHandle(self) else { super.mouseDown(with: event); return }
    let point = convert(event.locationInWindow, from: nil), clicked = indexPathForItem(at: point)
    if clicked == nil, visibleRect.contains(point) {
      window?.makeFirstResponder(self); isMarqueeSelecting = true; refreshExpandedNames()
      let previousAnchor = selectionAnchor
      if event.modifierFlags.intersection([.command, .control, .shift]).isEmpty { selectionAnchor = nil }
      let count = numberOfSections > 0 ? numberOfItems(inSection: 0) : 0
      let frames = (0..<count).compactMap { index -> (Int, NSRect)? in guard let rect = collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return nil }; return (index, rect) }
      marquee = NativeMarqueeSelection(host: self, event: event, original: Set(selectionIndexPaths.map(\.item)), targets: frames, apply: { [weak self] in self?.applySelection($0) }, finished: { [weak self] in if self?.marquee?.wasCancelled == true { self?.selectionAnchor = previousAnchor }; self?.marquee = nil; self?.isMarqueeSelecting = false; self?.refreshExpandedNames() })
      marquee?.begin(); return
    }
    let original = Set(selectionIndexPaths.map(\.item)), anchor = selectionAnchor
    if let clicked { selectionCursor = clicked.item; if !event.modifierFlags.contains(.shift) { selectionAnchor = clicked.item } }
    super.mouseDown(with: NativeSelection.commandClick(event))
    if let clicked, !event.modifierFlags.intersection([.command, .control, .shift]).isEmpty {
      applySelection(NativeSelection.click(clicked.item, anchor: anchor, original: original, flags: event.modifierFlags))
    }
    if event.clickCount == 2, clicked != nil { openSelection?() }
  }
}

enum ExplorerLayoutMode: String { case details, icons, list, tiles, content }
final class ExplorerCollectionLayout: NSCollectionViewLayout {
  var mode: ExplorerLayoutMode = .icons
  var iconSize: CGFloat = 64
  var compact = false
  private var count = 0
  private var columns = 1
  private var rows = 1
  private var cell = NSSize.zero
  private var inset = NSSize.zero
  private var gap = NSSize.zero
  private var contentSize = NSSize.zero
  override func prepare() {
    guard let collectionView else { return }
    count = collectionView.numberOfItems(inSection: 0)
    let viewport = collectionView.enclosingScrollView?.contentSize ?? collectionView.bounds.size
    switch mode {
    case .list:
      inset = NSSize(width: 14, height: 10); gap = .zero; cell = NSSize(width: 240, height: compact ? 28 : 36)
      rows = max(1, Int((viewport.height - 20) / cell.height)); columns = max(1, Int(ceil(Double(count) / Double(rows))))
      contentSize = NSSize(width: max(viewport.width, CGFloat(columns) * cell.width + 28), height: viewport.height)
    case .content:
      inset = NSSize(width: 14, height: 8); gap = .zero; columns = 1; cell = NSSize(width: max(100, viewport.width - 28), height: compact ? 70 : 86)
      contentSize = NSSize(width: viewport.width, height: max(viewport.height, CGFloat(count) * cell.height + 28))
    default:
      let horizontal = mode == .tiles || iconSize == 32
      inset = NSSize(width: horizontal ? 14 : 22, height: horizontal ? 14 : compact ? 12 : 22)
      gap = NSSize(width: horizontal ? 8 : 5, height: horizontal ? 4 : compact ? 2 : 8)
      let minimum: CGFloat = horizontal ? 240 : iconSize + 44
      columns = max(1, Int((viewport.width - inset.width * 2 + gap.width) / (minimum + gap.width)))
      let width = max(40, (viewport.width - inset.width * 2 - CGFloat(columns - 1) * gap.width) / CGFloat(columns))
      let height: CGFloat = mode == .tiles ? (compact ? 60 : 74) : iconSize == 32 ? (compact ? 36 : 42) : iconSize + (compact ? 48 : 58)
      cell = NSSize(width: width, height: height); rows = max(1, Int(ceil(Double(count) / Double(columns))))
      contentSize = NSSize(width: viewport.width, height: max(viewport.height, inset.height + CGFloat(rows) * (height + gap.height) + 30))
    }
  }
  override var collectionViewContentSize: NSSize { contentSize }
  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
  override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
    guard indexPath.item < count else { return nil }
    let column = mode == .list ? indexPath.item / rows : indexPath.item % columns
    let row = mode == .list ? indexPath.item % rows : indexPath.item / columns
    let value = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
    value.frame = NSRect(x: inset.width + CGFloat(column) * (cell.width + gap.width), y: inset.height + CGFloat(row) * (cell.height + gap.height), width: cell.width, height: cell.height)
    return value
  }
  override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
    guard count > 0 else { return [] }
    var output: [NSCollectionViewLayoutAttributes] = []
    if mode == .list {
      let first = max(0, Int((rect.minX - inset.width) / cell.width)); let last = min(columns - 1, Int(rect.maxX / cell.width) + 1)
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
  var selected = false { didSet { needsDisplay = true; needsLayout = true } }; var hovered = false { didSet { subviews.compactMap { $0 as? ExplorerCheckbox }.forEach { $0.hovered = hovered }; needsDisplay = true } }
  var bottomLine = false
  private var expandedName: NativeExpandedNameView?
  private var scrollObserver: NSObjectProtocol?
  override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { expandedName?.removeFromSuperview(); expandedName = nil; if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }; scrollObserver = nil } }
  deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
  override func layout() {
    super.layout(); expandedName?.removeFromSuperview(); expandedName = nil
    guard selected, window != nil, let name = subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier != nil }),
          !name.isEditable, name.alignment == .center, name.maximumNumberOfLines == 2, name.frame.minY > 40 else { return }
    var ancestor = superview
    while ancestor != nil, !(ancestor is FileCollectionView) { ancestor = ancestor?.superview }
    guard let collection = ancestor as? FileCollectionView, !collection.isMarqueeSelecting else { return }
    if scrollObserver == nil, let clip = collection.enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.needsLayout = true; self?.layoutSubtreeIfNeeded() }
    }
    let rect = convert(name.frame, to: collection)
    guard convert(bounds, to: collection).intersects(collection.visibleRect), rect.intersects(collection.visibleRect) else { return }
    let measured = (name.stringValue as NSString).boundingRect(with: NSSize(width: max(1, rect.width - 4), height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: name.font ?? NSFont.systemFont(ofSize: 12)])
    guard measured.height > rect.height else { return }
    let overlay = NativeExpandedNameView(name: name, selected: true)
    overlay.frame = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: ceil(measured.height) + 4)
    collection.addSubview(overlay); expandedName = overlay
  }
  override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)) }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }
  override func draw(_ dirtyRect: NSRect) {
    ExplorerPalette.surface.setFill(); bounds.fill()
    if selected { ExplorerPalette.selection.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    if bottomLine { ExplorerPalette.border.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
  }
}
final class IconItem: NSCollectionViewItem {
  let icon = FileIconView(); let nameLabel = label(""); let kindLabel = label("", size: 11, color: ExplorerPalette.secondary); let dateLabel = label("", size: 11, color: ExplorerPalette.secondary); let pathLabel = label("", size: 11, color: ExplorerPalette.secondary)
  let checkbox = ExplorerCheckbox()
  private let surface = ItemSurface()
  var mode: ExplorerLayoutMode = .icons; var iconSize: CGFloat = 64; var checkboxes = false
  override func loadView() { view = surface; [icon, nameLabel, kindLabel, dateLabel, pathLabel, checkbox].forEach(view.addSubview); icon.imageScaling = .scaleProportionallyUpOrDown }
  override var isSelected: Bool { didSet { surface.selected = isSelected; checkbox.state = isSelected ? .on : .off } }
  override func viewDidLayout() {
    super.viewDidLayout(); let width = view.bounds.width, height = view.bounds.height
    let horizontal = mode != .icons || iconSize == 32
    let size: CGFloat = mode == .list ? 22 : mode == .tiles ? 48 : mode == .content ? 56 : iconSize
    let leading: CGFloat = checkboxes && horizontal ? 30 : 12
    checkbox.available = checkboxes; checkbox.hovered = surface.hovered; checkbox.frame = NSRect(x: 7, y: horizontal ? (height - 14) / 2 : 8, width: 14, height: 14)
    nameLabel.alignment = horizontal ? .left : .center; nameLabel.maximumNumberOfLines = horizontal ? 1 : 2
    kindLabel.isHidden = mode != .tiles && mode != .content; dateLabel.isHidden = mode != .content; pathLabel.isHidden = mode != .content
    surface.bottomLine = mode == .content
    if horizontal {
      icon.frame = NSRect(x: leading, y: (height - size) / 2, width: size, height: size)
      let textX = leading + size + 9, textWidth = max(20, (mode == .content ? width * 0.55 : width) - textX - 12)
      let twoLines = mode == .tiles || mode == .content
      nameLabel.frame = NSRect(x: textX, y: height / 2 - (twoLines ? 18 : 8), width: textWidth, height: 17)
      kindLabel.frame = NSRect(x: textX, y: height / 2 + 3, width: textWidth, height: 16)
      dateLabel.frame = NSRect(x: width * 0.57, y: height / 2 - 19, width: width * 0.43 - 12, height: 17)
      pathLabel.frame = NSRect(x: width * 0.57, y: height / 2 + 5, width: width * 0.43 - 12, height: 17)
    } else {
      icon.frame = NSRect(x: (width - size) / 2, y: 8, width: size, height: size)
      nameLabel.frame = NSRect(x: 5, y: size + 14, width: width - 10, height: 36)
    }
  }
  func configure(_ entry: FileEntry, name: String? = nil, mode: ExplorerLayoutMode = .icons, size: CGFloat = 64, checkboxes: Bool = false) {
    _ = view; self.mode = mode; iconSize = size; self.checkboxes = checkboxes
    nameLabel.identifier = NSUserInterfaceItemIdentifier(entry.id)
    nameLabel.stringValue = name ?? entry.name; kindLabel.stringValue = entry.kind + (entry.isDirectory ? "" : " · \(ExplorerFormat.size(entry.size))")
    dateLabel.stringValue = NL("修改日期：") + (entry.modified?.formatted(.dateTime.year().month().day()) ?? "—")
    pathLabel.stringValue = NL("位置：") + entry.url.deletingLastPathComponent().path
    view.toolTip = entry.url.path; icon.show(entry, pixels: size > 64 ? 256 : size > 32 ? 128 : 64); surface.selected = isSelected; view.needsLayout = true
    view.setAccessibilityLabel(entry.name)
  }
  override func prepareForReuse() { super.prepareForReuse(); icon.clear(); checkbox.changed = nil; nameLabel.delegate = nil; nameLabel.abortEditing(); nameLabel.isEditable = false; nameLabel.isSelectable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false }
}
