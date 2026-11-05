import AppKit

/// AppKit supplies Latin and CJK fallback fonts and normal font smoothing.
enum ExplorerTypography {
  static let preferenceKey = "interfaceFontSize"
  static var baseSize: CGFloat = 13
  static func validSize(_ saved: Int) -> Int { (10...24).contains(saved) ? saved : 13 }
  static func configure(_ defaults: UserDefaults) { baseSize = CGFloat(validSize(defaults.integer(forKey: preferenceKey))) }
  static var lineHeight: CGFloat { ceil(font().ascender - font().descender) + 2 }
  static var rowHeight: CGFloat { max(28, lineHeight + 6) }
  static func resizeControls(in view: NSView, by delta: CGFloat) {
    if let field = view as? NSTextField, let font = field.font { field.font = NSFontManager.shared.convert(font, toSize: font.pointSize + delta) }
    if let button = view as? NSButton, let font = button.font { button.font = NSFontManager.shared.convert(font, toSize: font.pointSize + delta) }
    view.invalidateIntrinsicContentSize(); view.needsLayout = true; view.needsDisplay = true
    for child in view.subviews { resizeControls(in: child, by: delta) }
  }
  static func font(ofSize size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size + baseSize - 13, weight: weight)
  }
}
