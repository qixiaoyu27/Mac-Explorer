import AppKit

final class SelectionManager: NSObject, NSDraggingSource {
  private struct MouseDown {
    let event: NSEvent
    let row: Int?
    let modifiers: FileSelectionModifiers
    let selectsOnRelease: Bool
  }

  weak var itemsView: FilePaneSurface?
  private(set) var state = SelectionState()
  var topology = FileSelectionTopology()
  var onSelectionChanged: ((IndexSet?) -> Void)?
  var onGroupClick: ((Int) -> Void)?
  var openSelection: (() -> Void)?
  var showContext: ((NSPoint) -> Void)?
  var draggedURLs: (() -> [URL])?
  var finishedDragging: ((NSDragOperation) -> Void)?

  private var mouseDown: MouseDown?
  private var marquee: NativeMarqueeSelection?
  private var selectionBeforeMarquee: SelectionState?
  private var marqueeModifiers: FileSelectionModifiers = []
  private var resignObserver: NSObjectProtocol?

  var isMarqueeActive: Bool { marquee != nil }

  func IsSelected(_ node: FileSelectionNode) -> Bool { state.contains(node) }

  func fileNode(at row: Int) -> FileSelectionNode? {
    guard topology.fileRows.contains(row) else { return nil }
    return topology.rows[row]
  }

  func restoreSelection(_ snapshot: SelectionState) {
    endTracking()
    state = snapshot
  }

  func replaceSelection(paths: Set<String>, notify: Bool = true) {
    state.replace(paths: paths, topology: topology)
    if notify { onSelectionChanged?(nil) }
  }

  func onCollectionChanged(previous: FileSelectionTopology, regroupingFrom oldTopology: FileSelectionTopology?) {
    if let oldTopology { state.regroup(from: oldTopology, to: topology) }
    state.reconcile(with: topology, previous: previous)
  }

  func focusedRow(fallback: @autoclosure () -> Int?) -> Int? {
    state.focus.flatMap { topology.rowByNode[$0] } ?? fallback()
  }

  func SelectionChange(_ action: FileSelectionAction, affected: IndexSet? = nil) {
    state.apply(action, topology: topology)
    onSelectionChanged?(affected)
  }

  func SelectionChange(at row: Int, modifiers: FileSelectionModifiers, keyboard: Bool = false) {
    guard let node = fileNode(at: row) else { return }
    let affected = modifiers == .toggle ? (keyboard ? IndexSet() : IndexSet(integer: row)) : nil
    SelectionChange(keyboard ? .move(node, modifiers) : .click(node, modifiers), affected: affected)
  }

  func HandleInputEvent(_ event: NSEvent) -> Bool {
    guard let itemsView, let window = itemsView.window else { return false }
    if event.type == .flagsChanged, window.isKeyWindow, event.window == nil || event.window === window {
      marqueeModifiers = FileSelectionModifiers(event.modifierFlags.subtracting(.control))
      return false
    }
    guard event.window === window else { return false }
    switch event.type {
    case .leftMouseDown where !event.modifierFlags.contains(.control):
      return _HandleLeftMouseDown(event, in: itemsView)
    case .leftMouseDown, .rightMouseDown:
      guard let document = itemsView.document(at: event) else { return false }
      _HandleRightMouseDown(event, in: document)
      return true
    case .leftMouseDragged, .leftMouseUp:
      guard let mouseDown, let document = itemsView.scroll.documentView as? any FilePaneDocument else { return false }
      let pointer = event.locationInWindow
      let origin = mouseDown.event.locationInWindow
      let moved = abs(pointer.x - origin.x) > 4 || abs(pointer.y - origin.y) > 4
      if event.type == .leftMouseDragged {
        if let marquee {
          marqueeModifiers = FileSelectionModifiers(event.modifierFlags.subtracting(.control))
          if moved, !marquee.isDragging {
            selectionBeforeMarquee = state
            if let row = mouseDown.row {
              SelectionChange(at: row, modifiers: mouseDown.modifiers)
            } else if marqueeModifiers.isEmpty {
              SelectionChange(.clearItems)
            }
            marquee.beginDragging()
          }
          if marquee.isDragging { marquee.setEndpoint(pointer) }
        } else if moved {
          if mouseDown.modifiers == .toggle,
             case let .file(row) = document.selectableItem(at: document.convert(pointer, from: nil)),
             let node = fileNode(at: row), !IsSelected(node) {
            SelectionChange(at: row, modifiers: mouseDown.modifiers)
          }
          endTracking()
          beginFileDrag(event, from: document)
        }
        return true
      }
      let armedMarquee = isMarqueeActive
      let completedMarquee = marquee?.isDragging == true
      endTracking()
      if !completedMarquee { _HandleLeftMouseUp(event, down: mouseDown, in: itemsView, armedMarquee: armedMarquee) }
      return true
    case .keyDown where event.keyCode == 53 && isMarqueeActive:
      endTracking(restoreSelection: true)
      return true
    default:
      return false
    }
  }

  private func _HandleLeftMouseDown(_ event: NSEvent, in itemsView: FilePaneSurface) -> Bool {
    guard let document = itemsView.document(at: event) else { return false }
    endTracking()
    let point = document.convert(event.locationInWindow, from: nil)
    ExplorerFocus.keyboardVisible = false
    (document.window?.firstResponder as? NSView)?.needsDisplay = true
    document.window?.makeFirstResponder(document)
    let modifiers = FileSelectionModifiers(event.modifierFlags)
    switch document.selectableItem(at: point) {
    case let .file(row):
      guard let node = fileNode(at: row) else { return false }
      let selected = IsSelected(node)
      let whitespace = document.isClickInItemWhitespace(at: point, row: row)
      let startsMarquee = !selected && whitespace
      let selectsOnRelease = modifiers == .toggle || (modifiers.isEmpty && selected)
      mouseDown = MouseDown(event: event, row: row, modifiers: modifiers, selectsOnRelease: selectsOnRelease)
      if startsMarquee { _CreateMarquee(at: event.locationInWindow, in: itemsView, document: document) }
      else if !selectsOnRelease { SelectionChange(at: row, modifiers: modifiers) }
    case .background:
      mouseDown = MouseDown(event: event, row: nil, modifiers: modifiers, selectsOnRelease: false)
      _CreateMarquee(at: event.locationInWindow, in: itemsView, document: document)
    case let .group(row):
      onGroupClick?(row)
      return true
    }
    if let window = itemsView.window {
      resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
        self?.endTracking(restoreSelection: true)
      }
    }
    if isMarqueeActive { (document as? FileCollectionView)?.refreshExpandedNames() }
    return true
  }

  private func _HandleLeftMouseUp(_ event: NSEvent, down: MouseDown, in itemsView: FilePaneSurface, armedMarquee: Bool) {
    let hit = itemsView.document(at: event).map { document in
      document.selectableItem(at: document.convert(event.locationInWindow, from: nil))
    }
    if armedMarquee, let row = down.row {
      SelectionChange(at: row, modifiers: down.modifiers)
    } else if down.row == nil, down.modifiers.isEmpty, case .background? = hit {
      SelectionChange(.clear)
    } else if down.selectsOnRelease, case let .file(row)? = hit {
      SelectionChange(at: row, modifiers: down.modifiers)
    }
    if let row = down.row, down.event.clickCount == 2, down.modifiers.isEmpty, case .file(row)? = hit {
      openSelection?()
    }
  }

  func _HandleSpaceKey(_ flags: FileSelectionModifiers, fallbackRow: @autoclosure () -> Int?) -> Bool {
    guard flags == .toggle, let row = focusedRow(fallback: fallbackRow()) else { return false }
    SelectionChange(at: row, modifiers: flags)
    return true
  }

  func _HandleRightMouseDown(_ event: NSEvent, in document: any FilePaneDocument) {
    if case let .file(row) = document.selectableItem(at: document.convert(event.locationInWindow, from: nil)),
       let node = fileNode(at: row) {
      if !IsSelected(node) { SelectionChange(at: row, modifiers: []) }
    } else {
      SelectionChange(.clear)
    }
    showContext?(event.locationInWindow)
  }

  private func _CreateMarquee(at start: NSPoint, in itemsView: FilePaneSurface, document: any FilePaneDocument) {
    marquee = NativeMarqueeSelection(host: document, start: start, drawingIn: itemsView,
                                     visibleArea: { [weak itemsView] in itemsView?.fileViewport ?? .zero },
                                     hitTest: { [weak document] in document?.fileRows(intersecting: $0) ?? [] },
                                     itemsChanged: { [weak self] entered, exited in
      guard let self else { return }
      self.SelectionChange(.marquee(entered: entered.compactMap(self.fileNode),
                                   exited: exited.compactMap(self.fileNode),
                                   toggle: self.marqueeModifiers.contains(.toggle)), affected: entered.union(exited))
    })
  }

  func endTracking(restoreSelection: Bool = false) {
    let refreshNames = isMarqueeActive
    mouseDown = nil
    marquee?.endMarquee()
    marquee = nil
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
    if restoreSelection, let selectionBeforeMarquee {
      state = selectionBeforeMarquee
      onSelectionChanged?(nil)
    }
    selectionBeforeMarquee = nil
    if refreshNames { (itemsView?.scroll.documentView as? FileCollectionView)?.refreshExpandedNames() }
  }

  private func beginFileDrag(_ event: NSEvent, from document: NSView) {
    guard let urls = draggedURLs?(), let first = urls.first else { return }
    let items = urls.map { NSDraggingItem(pasteboardWriter: $0 as NSURL) }
    let point = document.convert(event.locationInWindow, from: nil)
    let frame = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
    items[0].setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: first.path))
    document.beginDraggingSession(with: items, event: event, source: self).draggingFormation = .stack
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    [.copy, .move]
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    finishedDragging?(operation)
  }

  deinit {
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }
}
