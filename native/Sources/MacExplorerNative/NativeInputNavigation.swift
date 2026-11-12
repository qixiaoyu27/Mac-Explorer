import AppKit

/// Wheel deltas use DOM direction here; AppKit's scrolling deltas have the opposite sign.
struct NativeNavigationStroke {
  enum Mode { case pending, horizontal, ignored, done }
  private(set) var mode: Mode = .pending
  private var last = -Double.infinity
  private var x: CGFloat = 0, y: CGFloat = 0
  private var context = ""

  mutating func reset() { mode = .pending; last = -.infinity; x = 0; y = 0; context = "" }
  mutating func consume(x deltaX: CGFloat, y deltaY: CGFloat, timestamp: Double, began: Bool, blocked: Bool, horizontalScroll: Bool, context: String) -> (consume: Bool, direction: Int?) {
    if began { reset() }
    guard deltaX != 0 || deltaY != 0 else { return (false, nil) }
    if timestamp - last > 0.25 { mode = .pending; x = 0; y = 0; self.context = context }
    last = timestamp
    if blocked { mode = .ignored; return (false, nil) }
    if mode == .done { return (true, nil) }
    if self.context != context { mode = .ignored }
    if mode == .ignored { return (false, nil) }
    if mode == .pending && horizontalScroll { mode = .ignored; return (false, nil) }
    x += deltaX; y += abs(deltaY)
    if mode == .pending {
      // Keep a horizontal start out of NSScrollView tracking while distance accumulates.
      if max(abs(x), y) < 10 { return (abs(x) > y * 1.25, nil) }
      if y > abs(x) * 1.5 { mode = .ignored; return (false, nil) }
      if abs(x) <= y * 1.25 { return (false, nil) }
      mode = .horizontal
    }
    guard abs(x) >= 36 else { return (true, nil) }
    mode = .done
    return (true, x < 0 ? -1 : 1)
  }
}

final class NativeInputNavigation {
  private weak var content: NSView?
  private let blocked: () -> Bool
  private let context: () -> String
  private let navigate: (Int) -> Void
  private var monitor: Any?
  private var blur: NSObjectProtocol?
  private var stroke = NativeNavigationStroke()
  private var armed = -1

  static func bind(to content: NSView, blocked: @escaping () -> Bool, context: @escaping () -> String, navigate: @escaping (Int) -> Void) -> NativeInputNavigation {
    NativeInputNavigation(content: content, blocked: blocked, context: context, navigate: navigate)
  }
  private init(content: NSView, blocked: @escaping () -> Bool, context: @escaping () -> String, navigate: @escaping (Int) -> Void) {
    self.content = content; self.blocked = blocked; self.context = context; self.navigate = navigate
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp, .scrollWheel]) { [weak self] event in guard let self else { return event }; return self.handle(event) }
    blur = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
      guard let self, note.object as? NSWindow === self.content?.window else { return }; self.armed = -1; self.stroke.reset()
    }
  }
  func close() {
    if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    if let blur { NotificationCenter.default.removeObserver(blur) }; blur = nil
    armed = -1; stroke.reset()
  }
  deinit { close() }

  private func isBlocked(_ window: NSWindow) -> Bool {
    blocked() || window.attachedSheet != nil || NSApp.modalWindow != nil || ExplorerDialogs.isPresenting(in: window) || window.firstResponder is NSTextView
  }
  @discardableResult
  func handle(_ event: NSEvent) -> NSEvent? {
    guard let content, let window = content.window, event.window === window else { return event }
    if event.type == .otherMouseDown || event.type == .otherMouseUp {
      guard event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
      if event.type == .otherMouseDown { armed = isBlocked(window) ? -1 : event.buttonNumber }
      else { let valid = armed == event.buttonNumber && !isBlocked(window); armed = -1; if valid { navigate(event.buttonNumber == 3 ? -1 : 1) } }
      return nil
    }
    guard event.type == .scrollWheel else { return event }
    let point = content.convert(event.locationInWindow, from: nil)
    let inside = content.bounds.contains(point), hit = inside ? content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? point) : nil
    var horizontalScroll = false, view = hit
    while let current = view {
      if let scroll = (current as? NSScrollView) ?? (current as? ExplorerScroller)?.scrollView,
         let document = scroll.documentView {
        let insets = scroll.contentInsets
        if document.bounds.width + insets.left + insets.right > scroll.contentView.bounds.width + 1 {
          horizontalScroll = true
          break
        }
      }
      if current === content { break }; view = current.superview
    }
    let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    let editableHit = (hit as? NSTextField)?.isEditable == true || hit is NSText || hit is NSPopUpButton || hit is NSButton || hit is NSSlider
    let result = stroke.consume(x: -event.scrollingDeltaX, y: -event.scrollingDeltaY, timestamp: event.timestamp,
      began: event.phase.contains(.began) && event.momentumPhase.isEmpty,
      blocked: !inside || editableHit || !event.hasPreciseScrollingDeltas || modified || isBlocked(window), horizontalScroll: horizontalScroll, context: context())
    if let direction = result.direction { navigate(direction) }
    return result.consume ? nil : event
  }
}

@MainActor
enum NativeInputNavigationChecks {
  static func runBrowser(browser: BrowserController, window: NSWindow) async throws -> [String] {
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw NSError(domain: "NativeInputNavigationChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    guard let navigation = browser.inputNavigation else { throw NSError(domain: "NativeInputNavigationChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Main browser must bind input navigation when its window appears"]) }
    let root = browser.directory, originalMode = browser.mode
    defer { browser.setView(originalMode, size: 64) }
    var checks: [String] = []
    for mode in [ExplorerLayoutMode.details, .icons] {
      browser.navigate(to: root.appendingPathComponent("Folder 2"))
      try await NativeSmoke.until { !browser.loading }
      browser.setView(mode, size: 64)
      window.contentView?.layoutSubtreeIfNeeded()
      let event = NavigationFixtureEvent(); event.fixtureWindow = window; event.fixtureType = .scrollWheel
      event.fixturePoint = browser.content.convert(NSPoint(x: browser.content.bounds.midX, y: browser.content.bounds.midY), to: nil)
      event.fixtureDelta = 60; event.fixturePhase = .began
      _ = navigation.handle(event)
      try check(browser.directory == root, "Main browser double-finger back works in \(mode)")
      try await NativeSmoke.until { !browser.loading }
      window.contentView?.layoutSubtreeIfNeeded()
      do {
        let scroll = browser.fileScroll
        let originalStyle = scroll.scrollerStyle
        defer {
          scroll.scrollerStyle = originalStyle
          browser.view.needsLayout = true
          window.contentView?.layoutSubtreeIfNeeded()
        }
        for style in [NSScroller.Style.legacy, .overlay] {
          scroll.scrollerStyle = style
          browser.view.needsLayout = true
          window.contentView?.layoutSubtreeIfNeeded()
          let documentWidth = scroll.documentView?.bounds.width ?? 0
          try check(documentWidth <= scroll.contentView.bounds.width + 1, "\(mode) content fits the viewport with \(style) scrollers")
          checks.append("\(mode) content fits the viewport with \(style) scrollers")
        }
      }
      event.fixturePoint = browser.content.convert(NSPoint(x: browser.content.bounds.midX, y: browser.content.bounds.midY), to: nil)
      event.fixtureDelta = -60; event.fixtureTimestamp = 2
      _ = navigation.handle(event)
      try check(browser.directory == root.appendingPathComponent("Folder 2"), "Main browser double-finger forward works in \(mode): current=\(browser.directory.absoluteString), expected=\(root.appendingPathComponent("Folder 2").absoluteString), loading=\(browser.loading), forwardEnabled=\(browser.forwardButton.isEnabled)")
      try await NativeSmoke.until { !browser.loading }
      browser.back()
      try await NativeSmoke.until { !browser.loading }
      checks.append("Main browser trackpad back and forward work in \(mode)")
    }
    return checks
  }
  static func run(window: NSWindow, content: NSView) throws -> [String] {
    var checks: [String] = []
    func check(_ condition: Bool, _ text: String) throws {
      guard condition else { throw NSError(domain: "NativeInputNavigationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }; checks.append(text)
    }
    var stroke = NativeNavigationStroke()
    let first = stroke.consume(x: -18, y: 0, timestamp: 1, began: true, blocked: false, horizontalScroll: false, context: "a")
    let second = stroke.consume(x: -18, y: 0, timestamp: 1.02, began: false, blocked: false, horizontalScroll: false, context: "a")
    try check(first.consume && first.direction == nil && second.direction == -1, "Horizontal navigation requires the 36 point threshold")
    try check(stroke.consume(x: -120, y: 0, timestamp: 1.05, began: false, blocked: false, horizontalScroll: false, context: "b").direction == nil, "Momentum cannot repeat navigation after directory change")
    try check(stroke.consume(x: 60, y: 0, timestamp: 1.07, began: true, blocked: false, horizontalScroll: false, context: "b").direction == 1, "Fresh native phase rearms a gesture during old momentum")
    try check(!stroke.consume(x: 60, y: 0, timestamp: 2, began: true, blocked: false, horizontalScroll: true, context: "a").consume, "Horizontal file lists keep their own scroll gesture")
    try check(stroke.consume(x: 60, y: 0, timestamp: 2.02, began: false, blocked: false, horizontalScroll: false, context: "a").direction == nil, "Scrollable lists own the entire stroke even at the edge")
    try check(!stroke.consume(x: 1, y: 20, timestamp: 3, began: true, blocked: false, horizontalScroll: false, context: "a").consume, "Vertical scrolling stays vertical")
    try check(stroke.consume(x: 60, y: 0, timestamp: 3.02, began: false, blocked: false, horizontalScroll: false, context: "a").direction == nil, "A vertical start cannot later trigger history navigation")
    let smallStart = stroke.consume(x: -2, y: 0, timestamp: 4, began: true, blocked: false, horizontalScroll: false, context: "a")
    try check(smallStart.consume && smallStart.direction == nil, "Small horizontal starts stay out of scroll-view tracking without navigating")
    try check(stroke.consume(x: -34, y: 0, timestamp: 4.02, began: false, blocked: false, horizontalScroll: false, context: "a").direction == -1, "A gentle horizontal stroke navigates after 36 accumulated points")
    try check(!stroke.consume(x: 0, y: 2, timestamp: 5, began: true, blocked: false, horizontalScroll: false, context: "a").consume, "Small vertical starts remain normal scrolling")
    var directions: [Int] = [], blocked = false
    let navigation = NativeInputNavigation.bind(to: content, blocked: { blocked }, context: { "fixture" }, navigate: { directions.append($0) })
    defer { navigation.close() }
    func side(_ type: NSEvent.EventType, button: Int) -> NSEvent { let event = NavigationFixtureEvent(); event.fixtureWindow = window; event.fixtureType = type; event.fixtureButton = button; return event }
    window.makeKeyAndOrderFront(nil); window.makeKey(); window.makeFirstResponder(content)
    _ = navigation.handle(side(.otherMouseUp, button: 3)); try check(directions.isEmpty, "Unmatched mouse release does not navigate")
    _ = navigation.handle(side(.otherMouseDown, button: 3)); _ = navigation.handle(side(.otherMouseUp, button: 3)); try check(directions == [-1], "Mouse side button 3 navigates back once on release")
    _ = navigation.handle(side(.otherMouseDown, button: 4)); _ = navigation.handle(side(.otherMouseUp, button: 4)); try check(directions == [-1, 1], "Mouse side button 4 navigates forward")
    blocked = true; _ = navigation.handle(side(.otherMouseDown, button: 3)); blocked = false; _ = navigation.handle(side(.otherMouseUp, button: 3)); try check(directions == [-1, 1], "Blocking at press time cannot be bypassed at release")
    _ = navigation.handle(side(.otherMouseDown, button: 3)); blocked = true; _ = navigation.handle(side(.otherMouseUp, button: 3)); try check(directions == [-1, 1], "Blocking at release cancels an armed navigation")
    blocked = false
    let wheel = NavigationFixtureEvent(); wheel.fixtureWindow = window; wheel.fixtureType = .scrollWheel
    wheel.fixturePoint = content.convert(NSPoint(x: content.visibleRect.midX, y: content.visibleRect.midY), to: nil)
    wheel.fixtureDelta = 60; wheel.fixturePhase = .began
    try check(navigation.handle(wheel) == nil && directions == [-1, 1, -1], "AppKit positive horizontal deltas match Electron backward navigation")
    wheel.fixturePhase = []; wheel.fixtureTimestamp = 1.02
    try check(navigation.handle(wheel) == nil && directions.count == 3, "Consumed momentum cannot leak into default scrolling")
    wheel.fixturePhase = .began; wheel.fixtureFlags = .shift; wheel.fixtureTimestamp = 2
    try check(navigation.handle(wheel) != nil && directions.count == 3, "Modified scrolling keeps normal application behavior")
    return checks
  }
}

private final class NavigationFixtureEvent: NSEvent {
  weak var fixtureWindow: NSWindow?
  var fixtureType: NSEvent.EventType = .otherMouseDown
  var fixtureButton = 3
  var fixturePoint = NSPoint.zero
  var fixtureDelta: CGFloat = 0
  var fixturePhase: NSEvent.Phase = []
  var fixtureFlags: NSEvent.ModifierFlags = []
  var fixtureTimestamp: Double = 1
  override var window: NSWindow? { fixtureWindow }
  override var type: NSEvent.EventType { fixtureType }
  override var buttonNumber: Int { fixtureButton }
  override var locationInWindow: NSPoint { fixturePoint }
  override var scrollingDeltaX: CGFloat { fixtureDelta }
  override var scrollingDeltaY: CGFloat { 0 }
  override var hasPreciseScrollingDeltas: Bool { true }
  override var phase: NSEvent.Phase { fixturePhase }
  override var momentumPhase: NSEvent.Phase { [] }
  override var modifierFlags: NSEvent.ModifierFlags { fixtureFlags }
  override var timestamp: TimeInterval { fixtureTimestamp }
}
