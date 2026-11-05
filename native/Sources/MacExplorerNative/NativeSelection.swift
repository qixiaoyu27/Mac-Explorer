import AppKit

enum NativeSelection {
  static func canHandle(_ view: NSView) -> Bool {
    guard let window = view.window, NSApp.modalWindow == nil, window.attachedSheet == nil,
          !ExplorerDialogs.isPresenting(in: window), !(window.firstResponder is NSTextView) else { return false }
    return true
  }

  static func click(_ index: Int, anchor: Int?, original: Set<Int>, flags: NSEvent.ModifierFlags) -> Set<Int> {
    let toggle = !flags.intersection([.command, .control]).isEmpty
    if flags.contains(.shift), let anchor {
      let range = Set(min(anchor, index)...max(anchor, index))
      return toggle ? original.union(range) : range
    }
    if toggle { return original.contains(index) ? original.subtracting([index]) : original.union([index]) }
    return [index]
  }

  static func rectangle(_ rect: NSRect, targets: [(Int, NSRect)], original: Set<Int>, flags: NSEvent.ModifierFlags) -> Set<Int> {
    let toggle = !flags.intersection([.command, .control]).isEmpty
    let hits = Set(targets.filter { $0.1.intersects(rect) }.map(\.0))
    return toggle ? original.symmetricDifference(hits) : flags.contains(.shift) ? original.union(hits) : hits
  }

  static func commandClick(_ event: NSEvent) -> NSEvent {
    guard event.modifierFlags.contains(.control) else { return event }
    return NSEvent.mouseEvent(with: event.type, location: event.locationInWindow,
      modifierFlags: event.modifierFlags.subtracting(.control).union(.command), timestamp: event.timestamp,
      windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber,
      clickCount: event.clickCount, pressure: event.pressure) ?? event
  }
}

/// Only blank-space drags enter this tracker; AppKit keeps ownership of file dragging.
final class NativeMarqueeSelection {
  private weak var host: NSView?
  private let original: Set<Int>
  private let flags: NSEvent.ModifierFlags
  private let targets: [(Int, NSRect)]
  private let apply: (Set<Int>) -> Void
  private let finished: () -> Void
  private let start: NSPoint
  private let down: NSPoint
  private var pointer: NSPoint
  private var dragged = false
  private var ended = false
  private(set) var wasCancelled = false
  private var monitor: Any?
  private var timer: Timer?
  private var blur: NSObjectProtocol?
  private let overlay = MarqueeOverlay()

  init(host: NSView, event: NSEvent, original: Set<Int>, targets: [(Int, NSRect)], apply: @escaping (Set<Int>) -> Void, finished: @escaping () -> Void) {
    self.host = host; self.original = original; self.targets = targets; self.apply = apply; self.finished = finished
    flags = event.modifierFlags; down = event.locationInWindow; pointer = down; start = host.convert(down, from: nil)
  }

  func begin() {
    guard let host, let window = host.window else { return }
    overlay.frame = host.bounds; host.addSubview(overlay)
    if flags.intersection([.command, .control, .shift]).isEmpty { apply([]) }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in guard let self else { return event }; return self.handle(event) }
    blur = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.end(cancelled: true) }
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.update() }; self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func handle(_ event: NSEvent) -> NSEvent? {
    guard !ended, event.window === host?.window else { return event }
    if event.type == .keyDown {
      if event.keyCode == 53 { end(cancelled: true); return nil }; return event
    }
    guard event.type == .leftMouseDragged || event.type == .leftMouseUp else { return event }
    pointer = event.locationInWindow
    if hypot(pointer.x - down.x, pointer.y - down.y) >= 4 { dragged = true }
    update()
    if event.type == .leftMouseUp { end(cancelled: false) }
    return nil
  }

  private func update() {
    guard !ended, dragged, let host, let scroll = host.enclosingScrollView else { return }
    let viewport = host.visibleRect
    var point = host.convert(pointer, from: nil)
    let x = min(viewport.maxX, max(viewport.minX, point.x)), y = min(viewport.maxY, max(viewport.minY, point.y))
    func speed(_ value: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat) -> CGFloat { value < minimum + 24 ? -12 : value > maximum - 24 ? 12 : 0 }
    let dx = speed(x, viewport.minX, viewport.maxX), dy = speed(y, viewport.minY, viewport.maxY)
    let origin = scroll.contentView.bounds.origin
    let next = NSPoint(x: max(0, min(max(0, host.bounds.width - viewport.width), origin.x + dx)), y: max(0, min(max(0, host.bounds.height - viewport.height), origin.y + dy)))
    scroll.contentView.scroll(to: next); scroll.reflectScrolledClipView(scroll.contentView)
    point = host.convert(pointer, from: nil)
    let visible = host.visibleRect
    point.x = max(visible.minX, min(visible.maxX, point.x)); point.y = max(visible.minY, min(visible.maxY, point.y))
    let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
    overlay.frame = host.bounds; overlay.rectangle = rect; overlay.needsDisplay = true
    apply(NativeSelection.rectangle(rect, targets: targets, original: original, flags: flags))
  }

  func end(cancelled: Bool) {
    guard !ended else { return }; ended = true; wasCancelled = cancelled
    if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    if let blur { NotificationCenter.default.removeObserver(blur) }; blur = nil
    timer?.invalidate(); timer = nil; overlay.removeFromSuperview()
    if cancelled { apply(original) }
    finished()
  }
  deinit { if let monitor { NSEvent.removeMonitor(monitor) }; if let blur { NotificationCenter.default.removeObserver(blur) }; timer?.invalidate() }
}

private final class MarqueeOverlay: NSView {
  var rectangle = NSRect.zero
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    ExplorerPalette.accent.withAlphaComponent(0.15).setFill(); rectangle.fill()
    ExplorerPalette.accent.withAlphaComponent(0.8).setStroke(); NSBezierPath(rect: rectangle.insetBy(dx: 0.5, dy: 0.5)).stroke()
  }
}

final class NativeExpandedNameView: SurfaceView {
  let text = label("")
  init(name: NSTextField, selected: Bool) {
    super.init(frame: .zero); color = selected ? ExplorerPalette.selection : ExplorerPalette.surface
    text.stringValue = name.stringValue; text.font = name.font; text.textColor = name.textColor; text.alignment = name.alignment
    text.maximumNumberOfLines = 0; text.lineBreakMode = .byWordWrapping; addSubview(text)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func layout() { super.layout(); text.frame = bounds.insetBy(dx: 7, dy: 1) }
}

@MainActor
enum NativeSelectionChecks {
  static func run() throws -> [String] {
    var checks: [String] = []
    func check(_ value: Bool, _ description: String) throws {
      guard value else { throw NSError(domain: "NativeSelectionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
      checks.append(description)
    }
    try check(NativeSelection.click(4, anchor: 2, original: [0, 2], flags: .shift) == [2, 3, 4], "Shift click selects the anchor range")
    try check(NativeSelection.click(4, anchor: 2, original: [0, 2], flags: [.shift, .command]) == [0, 2, 3, 4], "Command Shift click adds the anchor range")
    try check(NativeSelection.click(2, anchor: nil, original: [0, 2], flags: .control) == [0], "Control click toggles membership")
    let targets = [(0, NSRect(x: 10, y: 10, width: 40, height: 30)), (1, NSRect(x: 70, y: 10, width: 40, height: 30))]
    let box = NSRect(x: 0, y: 0, width: 60, height: 50)
    try check(NativeSelection.rectangle(box, targets: targets, original: [0, 1], flags: .command) == [1], "Command marquee toggles original membership")
    try check(NativeSelection.rectangle(box, targets: targets, original: [1], flags: .shift) == [0, 1], "Shift marquee appends")
    let previous = NSApp.keyWindow
    let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 460, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close(); previous?.makeKeyAndOrderFront(nil) }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
    let table = FileTableView(frame: scroll.bounds), data = SelectionFixtureRows()
    let column = NSTableColumn(identifier: .init("name")); column.width = 440; table.addTableColumn(column); table.rowHeight = 28; table.headerView = nil; table.dataSource = data; table.allowsMultipleSelection = true
    scroll.documentView = table; scroll.hasVerticalScroller = true; window.contentView = scroll; window.makeKeyAndOrderFront(nil); table.reloadData(); table.layoutSubtreeIfNeeded(); window.makeFirstResponder(table)
    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)! }
    table.selectRowIndexes([0, 2], byExtendingSelection: false); table.keyDown(with: key(125, flags: .shift))
    try check(table.selectedRowIndexes == [0, 2, 3], "Real table Shift Down preserves discontiguous selection")
    table.keyDown(with: key(53)); try check(table.selectedRowIndexes.isEmpty, "Real table Escape clears selection")
    data.count = 3; table.reloadData(); table.selectRowIndexes([1], byExtendingSelection: false)
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)! }
    let tracker = NativeMarqueeSelection(host: table, event: mouse(.leftMouseDown, NSPoint(x: 8, y: 150)), original: [1], targets: (0..<3).map { ($0, table.rect(ofRow: $0)) }, apply: { table.selectRowIndexes(IndexSet($0), byExtendingSelection: false) }, finished: {})
    tracker.begin(); _ = tracker.handle(mouse(.leftMouseDragged, NSPoint(x: 150, y: 8)))
    try check(table.selectedRowIndexes == [0, 1, 2], "Real table blank marquee selects intersected rows")
    _ = tracker.handle(key(53)); try check(table.selectedRowIndexes == [1], "Escape during marquee restores the original selection")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24)); scroll.addSubview(field); window.makeFirstResponder(field)
    try check(!NativeSelection.canHandle(table), "Text editing blocks file selection shortcuts")
    window.makeFirstResponder(table); field.removeFromSuperview()
    let collection = FileCollectionView(frame: scroll.bounds), layout = ExplorerCollectionLayout(), collectionData = SelectionFixtureItems()
    collection.collectionViewLayout = layout; collection.dataSource = collectionData; collection.isSelectable = true; collection.allowsMultipleSelection = true
    collection.register(SelectionFixtureItem.self, forItemWithIdentifier: .init("fixture")); scroll.documentView = collection; collection.reloadData(); collection.layoutSubtreeIfNeeded(); layout.prepare()
    let frames = (0..<10_000).compactMap { index -> (Int, NSRect)? in guard let attributes = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return nil }; return (index, attributes.frame) }
    try check(frames.count == 10_000 && collectionData.created < 200, "Marquee snapshots 10000 layout frames without creating 10000 views")
    window.makeFirstResponder(collection)
    var selected = Set<Int>()
    func collectionMouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent { NSEvent.mouseEvent(with: type, location: collection.convert(point, to: nil), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)! }
    let edge = NativeMarqueeSelection(host: collection, event: collectionMouse(.leftMouseDown, NSPoint(x: 1, y: 1)), original: [], targets: frames, apply: { selected = $0 }, finished: {})
    edge.begin()
    let height = collection.visibleRect.height
    for _ in 0..<30 { _ = edge.handle(collectionMouse(.leftMouseDragged, NSPoint(x: 250, y: collection.visibleRect.maxY - 1))) }
    try check(collection.visibleRect.minY > 0 && selected.contains(where: { frames[$0].1.minY > height }), "Edge scrolling extends marquee hits beyond the initial viewport")
    edge.end(cancelled: false)
    let longSurface = ItemSurface(frame: NSRect(x: 20, y: collection.visibleRect.minY + 20, width: 110, height: 122)), name = label(String(repeating: "Long file name ", count: 20))
    name.identifier = .init("fixture-name"); name.maximumNumberOfLines = 2; name.alignment = .center; name.frame = NSRect(x: 5, y: 78, width: 100, height: 36); longSurface.addSubview(name); collection.addSubview(longSurface); longSurface.selected = true; longSurface.layoutSubtreeIfNeeded()
    try check(collection.subviews.contains(where: { $0 is NativeExpandedNameView }), "Selected icon names expand without changing layout hit frames")
    let beforeScroll = scroll.contentView.bounds.origin
    scroll.contentView.scroll(to: NSPoint(x: 0, y: longSurface.frame.maxY + 100)); scroll.reflectScrolledClipView(scroll.contentView)
    try check(!collection.subviews.contains(where: { $0 is NativeExpandedNameView }), "Offscreen item names cannot cover the visible viewport")
    scroll.contentView.scroll(to: beforeScroll); scroll.reflectScrolledClipView(scroll.contentView); longSurface.needsLayout = true; longSurface.layoutSubtreeIfNeeded()
    name.isEditable = true; longSurface.needsLayout = true; longSurface.layoutSubtreeIfNeeded()
    try check(!collection.subviews.contains(where: { $0 is NativeExpandedNameView }), "Expanded labels disappear during inline editing")
    checks += try NativeInputNavigationChecks.run(window: window, content: collection)
    return checks
  }
}

private final class SelectionFixtureRows: NSObject, NSTableViewDataSource {
  var count = 4
  func numberOfRows(in tableView: NSTableView) -> Int { count }
}
private final class SelectionFixtureItems: NSObject, NSCollectionViewDataSource {
  var created = 0
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { 10_000 }
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem { created += 1; return collectionView.makeItem(withIdentifier: .init("fixture"), for: indexPath) }
}
private final class SelectionFixtureItem: NSCollectionViewItem { override func loadView() { view = NSView() } }
