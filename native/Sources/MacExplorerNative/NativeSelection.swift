import AppKit

enum NativeSelection {
  static func canHandle(_ view: NSView) -> Bool {
    guard let window = view.window, NSApp.modalWindow == nil, window.attachedSheet == nil,
          !ExplorerDialogs.isPresenting(in: window), !(window.firstResponder is NSTextView) else { return false }
    return true
  }

}

extension FileSelectionModifiers {
  init(_ flags: NSEvent.ModifierFlags) {
    self = []
    if flags.contains(.shift) { insert(.shift) }
    if !flags.intersection([.command, .control]).isEmpty { insert(.toggle) }
  }
}

final class NativeMarqueeSelection {
  private weak var host: NSView?
  private weak var drawingSurface: NSView?
  private let visibleArea: () -> NSRect
  private let hitTest: (NSRect) -> IndexSet
  private let itemsChanged: (IndexSet, IndexSet) -> Void
  private var previousHits = IndexSet()
  private var previousRectangle: NSRect?
  private let start: NSPoint
  private var pointer: NSPoint
  private var timer: Timer?
  private let overlay = MarqueeOverlay()

  var isDragging: Bool { timer != nil }

  init(host: NSView, start: NSPoint, drawingIn surface: NSView, visibleArea: @escaping () -> NSRect,
       hitTest: @escaping (NSRect) -> IndexSet, itemsChanged: @escaping (IndexSet, IndexSet) -> Void) {
    self.host = host
    drawingSurface = surface
    self.visibleArea = visibleArea
    self.hitTest = hitTest
    self.itemsChanged = itemsChanged
    pointer = start
    self.start = host.convert(start, from: nil)
  }

  func beginDragging() {
    guard let drawingSurface else { return }
    overlay.frame = visibleArea()
    drawingSurface.addSubview(overlay, positioned: .above, relativeTo: nil)
    let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.update() }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func setEndpoint(_ point: NSPoint) {
    pointer = point
    update()
  }

  private func update() {
    guard let host, let surface = drawingSurface, let scroll = host.enclosingScrollView else { return }
    let area = visibleArea()
    guard !area.isEmpty else { return }
    let viewport = host.convert(area, from: surface)
    var point = host.convert(pointer, from: nil)
    let x = min(viewport.maxX, max(viewport.minX, point.x)), y = min(viewport.maxY, max(viewport.minY, point.y))
    func speed(_ value: CGFloat, _ minimum: CGFloat, _ maximum: CGFloat) -> CGFloat { value < minimum + 24 ? -12 : value > maximum - 24 ? 12 : 0 }
    let dx = speed(x, viewport.minX, viewport.maxX), dy = speed(y, viewport.minY, viewport.maxY)
    let clip = scroll.contentView
    if dx != 0 || dy != 0 {
      let next = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: dx, dy: dy)).origin
      if next != clip.bounds.origin {
        scroll.scroll(clip, to: next)
        scroll.reflectScrolledClipView(clip)
      }
    }
    point = host.convert(pointer, from: nil)
    let visible = host.convert(visibleArea(), from: surface)
    point.x = max(visible.minX, min(visible.maxX, point.x)); point.y = max(visible.minY, min(visible.maxY, point.y))
    let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(start.x - point.x), height: abs(start.y - point.y))
    guard previousRectangle != rect else { return }
    previousRectangle = rect
    overlay.frame = area
    overlay.rectangle = overlay.convert(rect, from: host)
    overlay.needsDisplay = true
    let hits = hitTest(rect)
    let entered = hits.subtracting(previousHits), exited = previousHits.subtracting(hits)
    previousHits = hits
    if !entered.isEmpty || !exited.isEmpty { itemsChanged(entered, exited) }
  }

  func endMarquee() {
    timer?.invalidate()
    timer = nil
    overlay.removeFromSuperview()
  }

  deinit { endMarquee() }
}

private final class MarqueeOverlay: NSView {
  var rectangle = NSRect.zero
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    NSBezierPath(rect: bounds).addClip()
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
  static func runContextMenuInput(browser: BrowserController, window: NSWindow) throws -> [String] {
    let layout = browser.mode, selection = browser.selectedPaths
    defer { ExplorerMenu.dismiss(); browser.setView(layout); browser.selectedPaths = selection }
    var checks: [String] = []
    func expect(_ condition: Bool, _ message: String) throws {
      guard condition else { throw NativeSmoke.Failure(description: message) }
      checks.append(message)
    }
    func menuIsOpen() -> Bool { window.childWindows?.contains { $0 is NSPanel && $0.isVisible } == true }
    func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
      let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
      NSApp.sendEvent(event)
    }
    let f10 = String(UnicodeScalar(NSF10FunctionKey)!)
    let menuKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: f10,
                                   charactersIgnoringModifiers: f10, isARepeat: false, keyCode: 109)!

    for mode in [ExplorerLayoutMode.details, .icons] {
      browser.setView(mode)
      window.contentView?.layoutSubtreeIfNeeded()
      guard let document = browser.fileScroll.documentView,
            let first = browser.entryIndex(at: 0), let second = browser.entryIndex(at: 1), let third = browser.entryIndex(at: 2) else {
        throw NativeSmoke.Failure(description: "Context menu input fixture requires three visible items")
      }
      func point(at row: Int) throws -> NSPoint {
        if mode == .details {
          let frame = browser.table.rect(ofRow: row)
          return document.convert(NSPoint(x: 70, y: frame.midY), to: nil)
        }
        guard let frame = browser.collection.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame else {
          throw NativeSmoke.Failure(description: "Context menu input fixture has no icon at row \(row)")
        }
        return document.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
      }
      func dismissMenu() {
        ExplorerMenu.dismiss(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(document)
      }
      let firstPath = browser.entries[first].id, secondPath = browser.entries[second].id, thirdPath = browser.entries[third].id
      let secondPoint = try point(at: 1), thirdPoint = try point(at: 2)
      dismissMenu()
      browser.selectedPaths = [firstPath]
      sendMouse(.leftMouseDown, at: secondPoint, modifiers: .command)
      sendMouse(.leftMouseUp, at: secondPoint, modifiers: .command)
      try expect(browser.selectedPaths == [firstPath, secondPath] && !menuIsOpen(), "\(mode.rawValue): Command-click extends the selection")

      sendMouse(.leftMouseDown, at: secondPoint, modifiers: .control)
      sendMouse(.leftMouseUp, at: secondPoint, modifiers: .control)
      try expect(browser.selectedPaths == [firstPath, secondPath] && menuIsOpen(), "\(mode.rawValue): Control-click on a selected item opens the menu and retains multi-selection")
      dismissMenu()

      NSApp.sendEvent(menuKey)
      try expect(browser.selectedPaths == [firstPath, secondPath] && menuIsOpen(), "\(mode.rawValue): Shift-F10 opens the menu for the existing selection")
      dismissMenu()

      sendMouse(.leftMouseDown, at: thirdPoint, modifiers: .control)
      sendMouse(.leftMouseUp, at: thirdPoint, modifiers: .control)
      try expect(browser.selectedPaths == [thirdPath] && menuIsOpen(), "\(mode.rawValue): Control-click selects an unselected target before opening its menu")
      dismissMenu()

      sendMouse(.rightMouseDown, at: secondPoint, modifiers: [])
      try expect(browser.selectedPaths == [secondPath] && menuIsOpen(), "\(mode.rawValue): Secondary mouse button still opens the item menu")
      dismissMenu()
    }
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    let addCenter = browser.addTabButton.convert(NSPoint(x: browser.addTabButton.bounds.midX, y: browser.addTabButton.bounds.midY), to: nil)
    let closeButtons = browser.tabsDocument.subviews.compactMap { $0 as? ExplorerTabView }.flatMap { $0.subviews.compactMap { $0 as? ExplorerButton } }.filter { $0.iconName == "close" && !$0.isHiddenOrHasHiddenAncestor }
    try expect(!closeButtons.isEmpty && closeButtons.allSatisfy {
      abs($0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil).y - addCenter.y) < 0.01
    }, "Tab add and close buttons have the same vertical center in window coordinates")
    return checks
  }

  static func runFileMarquee(browser: BrowserController, window: NSWindow) throws -> [String] {
    let selection = browser.selectedPaths, mode = browser.mode
    let collection = browser.collection, table = browser.table
    let pane = browser.content, scroll = browser.fileScroll, clip = scroll.contentView
    browser.setView(.list)
    defer {
      browser.selectionManager.endTracking()
      browser.setView(mode)
      browser.selectedPaths = selection
    }
    window.contentView?.layoutSubtreeIfNeeded()
    guard browser.fileScroll === scroll, scroll.contentView === clip, scroll.documentView === collection,
          let header = table.headerView, !header.isDescendant(of: scroll) else {
      throw NativeSmoke.Failure(description: "List installs its layout in the shared viewport without a table header")
    }
    let first = IndexPath(item: 0, section: 0), third = IndexPath(item: 2, section: 0)
    guard let a = collection.layoutAttributesForItem(at: first)?.frame,
          let b = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame,
          let c = collection.layoutAttributesForItem(at: third)?.frame else {
      throw NativeSmoke.Failure(description: "List marquee fixture has three visible items")
    }
    guard a.minX == 14, a.width < 220 else {
      throw NativeSmoke.Failure(description: "List reserves the measured left gutter and fits the first column's names")
    }
    func event(_ type: NSEvent.EventType, at point: NSPoint, in host: NSView,
               flags: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    func mouseDown(at point: NSPoint, in host: NSView) {
      NSApp.sendEvent(event(.leftMouseDown, at: point, in: host))
    }
    func sample(at point: NSPoint, in host: NSView) -> NSColor? {
      let rect = NSRect(origin: browser.content.convert(point, from: host), size: NSSize(width: 1, height: 1))
      guard let image = browser.content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
      browser.content.cacheDisplay(in: rect, to: image)
      return image.colorAt(x: 0, y: 0)
    }
    let hits = Set([first, IndexPath(item: 1, section: 0), third])
    for (startX, laneX, insideX) in [(a.minX - 10, a.minX - 2, a.minX + 10),
                                     (a.maxX + 8, a.maxX + 2, a.maxX - 8)] {
      let start = NSPoint(x: startX, y: a.midY)
      let lane = NSPoint(x: laneX, y: c.midY)
      let inside = NSPoint(x: insideX, y: c.midY)
      let samplePoint = NSPoint(x: (startX + laneX) / 2, y: (a.midY + c.midY) / 2)
      let before = sample(at: samplePoint, in: collection)
      mouseDown(at: start, in: collection)
      NSApp.sendEvent(event(.leftMouseDragged, at: lane, in: collection))
      guard browser.selectionManager.isMarqueeActive, browser.selectedPaths.isEmpty,
            let before, let during = sample(at: samplePoint, in: collection), during != before else {
        throw NativeSmoke.Failure(description: "List drag in a side lane draws a box without selecting files")
      }
      NSApp.sendEvent(event(.leftMouseDragged, at: inside, in: collection))
      guard collection.selectionIndexPaths == hits else {
        throw NativeSmoke.Failure(description: "List marquee selects the three intersected item frames")
      }
      NSApp.sendEvent(event(.leftMouseUp, at: inside, in: collection))
      guard !browser.selectionManager.isMarqueeActive, collection.selectionIndexPaths == hits,
            sample(at: samplePoint, in: collection) == before else {
        throw NativeSmoke.Failure(description: "Releasing List marquee hides the box and keeps the selection")
      }
    }
    let blankPrefix = NSPoint(x: a.minX + 10, y: a.midY)
    let icon = NSPoint(x: c.minX + 38, y: c.midY)
    browser.selectedPaths = []
    mouseDown(at: blankPrefix, in: collection)
    guard browser.selectionManager.isMarqueeActive, collection.selectionIndexPaths.isEmpty else {
      throw NativeSmoke.Failure(description: "List arms marquee on unselected item whitespace")
    }
    NSApp.sendEvent(event(.leftMouseUp, at: blankPrefix, in: collection))
    guard collection.selectionIndexPaths == [first] else {
      throw NativeSmoke.Failure(description: "Clicking List item whitespace selects that item")
    }
    mouseDown(at: blankPrefix, in: collection)
    guard !browser.selectionManager.isMarqueeActive, collection.selectionIndexPaths == [first] else {
      throw NativeSmoke.Failure(description: "A selected List item keeps selection on mouse down in its whitespace")
    }
    NSApp.sendEvent(event(.leftMouseUp, at: blankPrefix, in: collection))
    NSApp.sendEvent(event(.leftMouseDown, at: icon, in: collection, flags: .shift))
    NSApp.sendEvent(event(.leftMouseUp, at: icon, in: collection, flags: .shift))
    guard collection.selectionIndexPaths == hits else {
      throw NativeSmoke.Failure(description: "Shift click uses the anchor established in List item whitespace")
    }
    mouseDown(at: icon, in: collection)
    guard !browser.selectionManager.isMarqueeActive, collection.selectionIndexPaths == hits else {
      throw NativeSmoke.Failure(description: "Clicking a selected icon leaves the selection intact until mouse up")
    }
    NSApp.sendEvent(event(.leftMouseUp, at: icon, in: collection))
    guard collection.selectionIndexPaths == [third] else {
      throw NativeSmoke.Failure(description: "Releasing a click on a selected file narrows the selection")
    }
    let manager = browser.selectionManager
    let dragURLs = manager.draggedURLs
    var dragSelection: Set<IndexPath> = []
    manager.draggedURLs = { dragSelection = collection.selectionIndexPaths; return [] }
    browser.selectedPaths = []
    mouseDown(at: blankPrefix, in: collection)
    NSApp.sendEvent(event(.leftMouseDragged, at: NSPoint(x: a.midX, y: c.midY), in: collection))
    NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
    guard !manager.isMarqueeActive, collection.selectionIndexPaths.isEmpty else {
      throw NativeSmoke.Failure(description: "Escape during List marquee restores the selection before mouse down")
    }
    let firstIcon = NSPoint(x: a.minX + 38, y: a.midY)
    mouseDown(at: firstIcon, in: collection)
    NSApp.sendEvent(event(.leftMouseUp, at: firstIcon, in: collection))
    NSApp.sendEvent(event(.leftMouseDown, at: icon, in: collection, flags: .shift))
    NSApp.sendEvent(event(.leftMouseUp, at: icon, in: collection, flags: .shift))
    mouseDown(at: icon, in: collection)
    NSApp.sendEvent(event(.leftMouseDragged, at: NSPoint(x: icon.x + 20, y: icon.y), in: collection))
    manager.draggedURLs = dragURLs
    guard dragSelection == hits, collection.selectionIndexPaths == hits else {
      throw NativeSmoke.Failure(description: "Starting a file drag preserves all selected items")
    }
    let gutter = NSPoint(x: a.minX - 7, y: a.midY)
    mouseDown(at: gutter, in: collection)
    NSApp.sendEvent(event(.leftMouseUp, at: gutter, in: collection))
    guard collection.selectionIndexPaths.isEmpty else {
      throw NativeSmoke.Failure(description: "Clicking a List gutter clears selection")
    }

    guard a.maxY < b.minY else {
      throw NativeSmoke.Failure(description: "List item rectangles leave a vertical gap")
    }
    mouseDown(at: firstIcon, in: collection)
    NSApp.sendEvent(event(.leftMouseUp, at: firstIcon, in: collection))
    let gap = NSPoint(x: firstIcon.x, y: (a.maxY + b.minY) / 2)
    mouseDown(at: gap, in: collection)
    NSApp.sendEvent(event(.leftMouseUp, at: gap, in: collection))
    guard collection.selectionIndexPaths.isEmpty else {
      throw NativeSmoke.Failure(description: "Clicking between List item rectangles clears selection")
    }

    let listOrigin = clip.bounds.origin
    pane.scrollTo(NSPoint(x: listOrigin.x + 240, y: listOrigin.y))
    let scrolledListOrigin = clip.bounds.origin
    browser.setView(.details)
    window.contentView?.layoutSubtreeIfNeeded()
    guard browser.fileScroll === scroll, scroll.contentView === clip, scroll.documentView === table,
          header.isDescendant(of: scroll), pane.horizontalScroller.superview === pane, pane.verticalScroller.superview === pane else {
      throw NativeSmoke.Failure(description: "Details installs its native header in the viewport and the scrollers beside it")
    }
    let nameColumn = table.column(withIdentifier: .init("name"))
    guard nameColumn >= 0 else { throw NativeSmoke.Failure(description: "Details fixture has a name column") }
    let firstName = table.frameOfCell(atColumn: nameColumn, row: 0)
    let thirdName = table.frameOfCell(atColumn: nameColumn, row: 2)
    let detailsStart = NSPoint(x: firstName.midX, y: firstName.midY)
    let detailsEnd = NSPoint(x: thirdName.midX + 20, y: thirdName.midY)
    guard table.visibleRect.contains(detailsStart), table.visibleRect.contains(detailsEnd) else {
      throw NativeSmoke.Failure(description: "Details fixture exposes blank space in the name column")
    }
    mouseDown(at: detailsStart, in: table)
    NSApp.sendEvent(event(.leftMouseUp, at: detailsStart, in: table))
    guard table.selectedRowIndexes == [0] else {
      throw NativeSmoke.Failure(description: "Clicking Details item whitespace selects its row")
    }
    browser.selectedPaths = []
    let tableOrigin = browser.fileScroll.contentView.bounds.origin
    mouseDown(at: detailsStart, in: table)
    NSApp.sendEvent(event(.leftMouseDragged, at: detailsEnd, in: table))
    NSApp.sendEvent(event(.leftMouseUp, at: detailsEnd, in: table))
    guard table.selectedRowIndexes == [0, 1, 2] else {
      throw NativeSmoke.Failure(description: "Details drag along blank name-column space selects intersected rows")
    }
    guard browser.fileScroll.contentView.bounds.origin == tableOrigin else {
      throw NativeSmoke.Failure(description: "Details marquee away from viewport edges keeps the scroll origin")
    }
    func selectionPixels(_ row: Int) throws -> (top: NSColor, bottom: NSColor, fill: NSColor) {
      guard let view = table.rowView(atRow: row, makeIfNecessary: false) as? FileRowView else {
        throw NativeSmoke.Failure(description: "Details selection fixture has a visible row at \(row)")
      }
      let image = NSImage(size: NSSize(width: 8, height: view.bounds.height), flipped: view.isFlipped) { rect in
        ExplorerPalette.surface.setFill()
        rect.fill()
        view.drawSelection(in: view.bounds)
        return true
      }
      guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
            let top = bitmap.colorAt(x: 0, y: 0), let bottom = bitmap.colorAt(x: 0, y: bitmap.pixelsHigh - 1),
            let fill = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2) else {
        throw NativeSmoke.Failure(description: "Details selection pixels can be sampled")
      }
      return (top, bottom, fill)
    }
    let leading = try selectionPixels(0), middle = try selectionPixels(1), trailing = try selectionPixels(2)
    guard leading.top != leading.fill, trailing.bottom != trailing.fill,
          leading.bottom == leading.fill, middle.top == middle.fill, middle.bottom == middle.fill, trailing.top == trailing.fill else {
      throw NativeSmoke.Failure(description: "Adjacent Details selections paint square joins and retain their small outer corners")
    }
    table.selectRowIndexes([0, 2], byExtendingSelection: false)
    let splitLeading = try selectionPixels(0), splitTrailing = try selectionPixels(2)
    guard splitLeading.bottom != leading.fill, splitTrailing.top != trailing.fill else {
      throw NativeSmoke.Failure(description: "Deselecting the middle Details row restores the neighboring corners")
    }
    table.selectRowIndexes([0, 1, 2], byExtendingSelection: false)

    let firstPoint = pane.convert(detailsStart, from: table)
    let endPoint = pane.convert(detailsEnd, from: table)
    for (startX, sampleX) in [(pane.bounds.minX + 4, pane.bounds.minX + 8),
                              (pane.fileViewport.maxX - 4, pane.fileViewport.maxX - 8)] {
      let start = NSPoint(x: startX, y: firstPoint.y)
      let samplePoint = NSPoint(x: sampleX, y: (firstPoint.y + endPoint.y) / 2)
      let before = sample(at: samplePoint, in: pane)
      mouseDown(at: start, in: pane)
      NSApp.sendEvent(event(.leftMouseDragged, at: endPoint, in: pane))
      guard let before, let during = sample(at: samplePoint, in: pane), during != before,
            table.selectedRowIndexes == [0, 1, 2] else {
        throw NativeSmoke.Failure(description: "Details marquee starts and draws in both outer gutters")
      }
      NSApp.sendEvent(event(.leftMouseUp, at: endPoint, in: pane))
      guard sample(at: samplePoint, in: pane) == before else {
        throw NativeSmoke.Failure(description: "Details marquee clears the side gutters when released")
      }
    }
    let headerPoint = NSPoint(x: firstPoint.x - 10, y: pane.fileViewport.minY - 5)
    let headerBefore = sample(at: headerPoint, in: pane)
    let edge = NSPoint(x: firstPoint.x + 30, y: pane.fileViewport.maxY - 2)
    let topGutter = NSPoint(x: pane.bounds.minX + 4, y: firstPoint.y)
    mouseDown(at: topGutter, in: pane)
    for _ in 0..<30 { NSApp.sendEvent(event(.leftMouseDragged, at: edge, in: pane)) }
    guard clip.bounds.origin.y > tableOrigin.y,
          table.selectedRowIndexes.last.map({ $0 > 2 }) == true,
          let headerBefore, sample(at: headerPoint, in: pane) == headerBefore else {
      throw NativeSmoke.Failure(description: "Details marquee extends selection while edge scrolling and stays out of the header")
    }
    NSApp.sendEvent(event(.leftMouseUp, at: edge, in: pane))
    browser.content.scrollTo(NSPoint(x: tableOrigin.x, y: tableOrigin.y + 240))
    let scrolledOrigin = clip.bounds.origin
    let selectedFiles = browser.selectedPaths
    browser.setView(.list)
    window.contentView?.layoutSubtreeIfNeeded()
    guard browser.selectedPaths == selectedFiles, scroll.documentView === collection, !header.isDescendant(of: scroll),
          scrolledListOrigin.x > listOrigin.x, clip.bounds.origin == scrolledListOrigin else {
      throw NativeSmoke.Failure(description: "Switching back to List restores its horizontal scroll, keeps the Details selection and unmounts the header")
    }
    pane.scrollTo(listOrigin)
    browser.setView(.details)
    window.contentView?.layoutSubtreeIfNeeded()
    guard scrolledOrigin.y > tableOrigin.y, clip.bounds.origin == scrolledOrigin, browser.selectedPaths == selectedFiles else {
      throw NativeSmoke.Failure(description: "Switching back to Details restores its scroll origin and shared selection")
    }
    browser.content.scrollTo(tableOrigin)
    return ["List and Details keep one scroll view and clip while switching their layout and header",
            "Switching layouts restores List and Details scrolling and keeps the shared selection",
            "List reserves the measured left gutter and fits the first column's names",
            "List side-lane drags draw a visible box without hitting files",
            "List marquee selects intersected item frames and commits on mouse up",
            "List item whitespace can start marquee and a stationary click selects the item",
            "Shift click uses the anchor established in List item whitespace",
            "File drags preserve the current multi-selection",
            "Clicking a List gutter or the vertical gap between items clears selection",
            "Escape restores the selection before List marquee",
            "Clicking Details item whitespace selects its row",
            "Details drag along blank name-column space selects intersected rows",
            "Details marquee away from viewport edges keeps the scroll origin",
            "Adjacent Details selections share a continuous fill with small outer corners",
            "Removing a selected row splits the fill and restores rounded corners",
            "Details marquee starts and draws in both outer gutters",
            "Details marquee extends selection while edge scrolling and stays out of the header"]
  }

  static func run() throws -> [String] {
    var checks: [String] = []
    func check(_ value: Bool, _ description: String) throws {
      guard value else { throw NSError(domain: "NativeSelectionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
      checks.append(description)
    }
    let nodes = (0..<4).map { FileSelectionNode.item(String($0), group: nil) }
    let topology = FileSelectionTopology(rows: nodes)
    var state = SelectionState()
    state.apply(.all, topology: topology)
    try check(state.marks == [.root: true], "Select All stores a single root mark")
    state.apply(.click(nodes[1], .toggle), topology: topology)
    try check(state.marks == [.root: true, nodes[1]: false], "Toggle under Select All stores one exception")
    state.apply(.click(nodes[3], [.shift, .toggle]), topology: topology)
    try check(nodes.filter(state.contains) == [nodes[0]], "Control Shift removes the range from an unselected anchor")
    let grouped: [FileSelectionNode] = [.group("A"), .item("A1", group: "A"), .group("B"), .item("B1", group: "B"),
                                       .item("B2", group: "B"), .group("C"), .item("C1", group: "C")]
    let groups = FileSelectionTopology(rows: grouped)
    state.apply(.click(grouped[1], []), topology: groups)
    state.apply(.click(grouped[6], .shift), topology: groups)
    try check(state.marks[.group("B")] == true && state.contains(grouped[4]), "Shift selects fully crossed groups through inheritance")
    state.apply(.set(grouped[3], false), topology: groups)
    state.apply(.set(.group("B"), true), topology: groups)
    try check(state.contains(grouped[3]) && state.marks[grouped[3]] == nil, "Selecting a group clears its member exceptions")
    let previous = NSApp.keyWindow
    let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 460, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close(); previous?.makeKeyAndOrderFront(nil) }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
    let table = FileTableView(frame: scroll.bounds), data = SelectionFixtureRows()
    let column = NSTableColumn(identifier: .init("name")); column.width = 440; table.addTableColumn(column); table.rowHeight = 28; table.headerView = nil; table.dataSource = data; table.allowsMultipleSelection = true
    scroll.documentView = table; scroll.hasVerticalScroller = true; window.contentView = scroll; window.makeKeyAndOrderFront(nil); table.reloadData(); table.layoutSubtreeIfNeeded(); window.makeFirstResponder(table)
    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)! }
    let manager = SelectionManager()
    manager.topology = topology
    manager.onSelectionChanged = { [weak manager] _ in
      guard let manager else { return }
      table.selectRowIndexes(manager.state.visibleRows(in: topology), byExtendingSelection: false)
    }
    table.selectionManager = manager
    manager.SelectionChange(.click(nodes[0], []))
    table.keyDown(with: key(125, flags: .shift)); table.keyDown(with: key(125, flags: .shift))
    try check(table.selectedRowIndexes == [0, 1, 2], "Real table Shift Down expands from the fixed anchor")
    table.keyDown(with: key(126, flags: .shift))
    try check(table.selectedRowIndexes == [0, 1] && manager.state.anchor == nodes[0], "Real table reversing Shift contracts the range")
    table.keyDown(with: key(53)); try check(table.selectedRowIndexes.isEmpty, "Real table Escape clears selection")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24)); scroll.addSubview(field); window.makeFirstResponder(field)
    try check(!NativeSelection.canHandle(table), "Text editing blocks file selection shortcuts")
    window.makeFirstResponder(table); field.removeFromSuperview()
    let collection = FileCollectionView(frame: scroll.bounds), layout = ExplorerCollectionLayout(), collectionData = SelectionFixtureItems()
    defer {
      withExtendedLifetime(collectionData) {
        scroll.documentView = nil
        collection.dataSource = nil
      }
    }
    collection.collectionViewLayout = layout; collection.dataSource = collectionData; collection.isSelectable = true; collection.allowsMultipleSelection = true
    collection.register(SelectionFixtureItem.self, forItemWithIdentifier: .init("fixture")); scroll.documentView = collection; collection.reloadData(); collection.layoutSubtreeIfNeeded(); layout.prepare()
    window.makeFirstResponder(collection)
    var selected = IndexSet()
    let edge = NativeMarqueeSelection(host: collection, start: collection.convert(NSPoint(x: 1, y: 1), to: nil),
                                      drawingIn: scroll.contentView, visibleArea: { scroll.contentView.bounds },
                                      hitTest: { rect in
      IndexSet(layout.layoutAttributesForElements(in: rect).compactMap { $0.indexPath?.item })
    }, itemsChanged: { entered, exited in
      selected.subtract(exited); selected.formUnion(entered)
    })
    edge.beginDragging()
    let height = collection.visibleRect.height
    let pointer = collection.convert(NSPoint(x: 250, y: collection.visibleRect.maxY - 1), to: nil)
    for _ in 0..<30 { edge.setEndpoint(pointer) }
    try check(collection.visibleRect.minY > 0 && selected.contains(where: {
      layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0)).map { $0.frame.minY > height } ?? false
    }), "Edge scrolling extends marquee hits beyond the initial viewport")
    try check(collectionData.created < 200, "Marquee layout queries avoid instantiating all 10000 item views")
    edge.endMarquee()
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
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { String(row) }
}
private final class SelectionFixtureItems: NSObject, NSCollectionViewDataSource {
  var created = 0
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { 10_000 }
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem { created += 1; return collectionView.makeItem(withIdentifier: .init("fixture"), for: indexPath) }
}
private final class SelectionFixtureItem: NSCollectionViewItem { override func loadView() { view = NSView() } }
