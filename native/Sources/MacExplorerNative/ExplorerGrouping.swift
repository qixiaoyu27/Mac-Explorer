import AppKit
import ExplorerCore

struct ExplorerDisplayRow {
  var entry: Int?
  var group: Int?
  var selectionGroup: String?
}

final class ExplorerGroupCell: NSTableCellView {
  var title = "" { didSet { needsDisplay = true; setAccessibilityElement(true); setAccessibilityLabel(title) } }
  var collapsed = false { didSet { setAccessibilityValue(collapsed ? 0 : 1) } }
  var onToggle: (() -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .button }
  override func accessibilityPerformPress() -> Bool { onToggle?(); return onToggle != nil }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { onToggle?() } else { super.keyDown(with: event) }
  }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    drawGroupHeader(title, collapsed: collapsed, in: bounds)
    if window?.firstResponder === self && ExplorerFocus.keyboardVisible {
      ExplorerPalette.accent.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).stroke()
    }
  }
}
final class ExplorerGroupItem: NSCollectionViewItem {
  override func loadView() { view = ExplorerGroupCell() }
  func configure(title: String, collapsed: Bool) {
    let cell = view as! ExplorerGroupCell; cell.title = title; cell.collapsed = collapsed; cell.needsDisplay = true
  }
}
func drawGroupHeader(_ title: String, collapsed: Bool, in bounds: NSRect) {
  ExplorerPalette.surface.setFill(); bounds.fill()
  ExplorerIcons.image(collapsed ? "chevronRight" : "chevronDown", size: 12, color: ExplorerPalette.accent)
    .draw(in: NSRect(x: 9, y: bounds.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  let attributes: [NSAttributedString.Key: Any] = [.font: ExplorerTypography.font(weight: .semibold), .foregroundColor: ExplorerPalette.accent]
  let text = title as NSString, width = min(bounds.width - 40, text.size(withAttributes: attributes).width)
  let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
  var attrs = attributes; attrs[.paragraphStyle] = paragraph
  text.draw(in: NSRect(x: 28, y: bounds.midY - ExplorerTypography.lineHeight / 2, width: max(0, width + 2), height: ExplorerTypography.lineHeight), withAttributes: attrs)
  ExplorerPalette.border.setFill(); NSRect(x: 38 + width, y: bounds.midY, width: max(0, bounds.width - width - 50), height: 1).fill()
}

/// Navigate around at most a few headers, without scanning a large directory per key.
func nextFileRow(key: UInt16, previous: Int, count: Int, accepts: (Int) -> Bool) -> Int? {
  guard count > 0 else { return nil }
  let step = key == 119 || key == 126 && previous >= 0 ? -1 : 1
  var index = key == 115 ? 0 : key == 119 ? count - 1 : previous < 0 ? 0 : max(0, min(count - 1, previous + step))
  while index >= 0 && index < count { if accepts(index) { return index }; index += step }
  if previous >= 0 && previous < count && accepts(previous) { return previous }
  return nil
}
