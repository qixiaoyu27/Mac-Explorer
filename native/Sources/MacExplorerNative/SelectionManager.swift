import AppKit

final class SelectionManager {
  enum InputResult {
    case ignored
    case handled
    case itemAction(FileItemInput)
  }

  private struct MouseDown {
    let event: NSEvent
    let document: any FilePaneDocument
    let item: FileSelectionNode?
    let modifiers: FileSelectionModifiers
    let selectsOnRelease: Bool
  }

  weak var itemsView: FilePaneSurface?
  private(set) var state = SelectionState()
  var topology = FileSelectionTopology()
  var onSelectionChanged: ((IndexSet?) -> Void)?
  var onGroupClick: ((Int) -> Void)?

  private var mouseDown: MouseDown?
  private var marquee: NativeMarqueeSelection?
  private var selectionBeforeMarquee: SelectionState?
  private var marqueeModifiers: FileSelectionModifiers = []
  private var resignObserver: NSObjectProtocol?

  var isMarqueeActive: Bool { marquee != nil }

  func IsSelected(_ node: FileSelectionNode) -> Bool { state.contains(node) }

  func GetSelection() -> [FileSelectionNode] { topology.items.filter(IsSelected) }

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

  func OnCollectionEvent(previous: FileSelectionTopology) {
    state.reconcile(with: topology, previous: previous)
  }

  func OnGroupByChanged(previous: FileSelectionTopology) {
    state.regroup(from: previous, to: topology)
  }

  func focusedRow(fallback: @autoclosure () -> Int?) -> Int? {
    state.focus.flatMap { topology.rowByNode[$0] } ?? fallback()
  }

  func SelectionChange(_ action: FileSelectionAction, affected: IndexSet? = nil) {
    state.apply(action, topology: topology)
    onSelectionChanged?(affected)
  }

  func SelectionChange(at row: Int, modifiers: FileSelectionModifiers) {
    guard let node = fileNode(at: row) else { return }
    SelectionChange(.click(node, modifiers), affected: modifiers == .toggle ? IndexSet(integer: row) : nil)
  }

  func UserMovedFocusWithKeyboard(to row: Int, modifiers: FileSelectionModifiers) {
    guard let node = fileNode(at: row) else { return }
    SelectionChange(.move(node, modifiers), affected: modifiers == .toggle ? IndexSet() : nil)
  }

  func HandleInputEvent(_ event: NSEvent) -> InputResult {
    guard let itemsView, let window = itemsView.window else { return .ignored }
    if event.type == .flagsChanged, window.isKeyWindow, event.window == nil || event.window === window {
      marqueeModifiers = FileSelectionModifiers(event.modifierFlags.subtracting(.control))
      return .ignored
    }
    guard event.window === window else { return .ignored }
    switch event.type {
    case .leftMouseDown where !event.modifierFlags.contains(.control):
      return _HandleLeftMouseDown(event, in: itemsView) ? .handled : .ignored
    case .leftMouseDown, .rightMouseDown:
      return HandleContextMenu(event)
    case .leftMouseDragged, .leftMouseUp:
      guard let mouseDown else { return .ignored }
      guard itemsView.scroll.documentView === mouseDown.document else {
        endTracking(restoreSelection: true)
        return .ignored
      }
      let pointer = event.locationInWindow
      let origin = mouseDown.event.locationInWindow
      let moved = abs(pointer.x - origin.x) > 4 || abs(pointer.y - origin.y) > 4
      if event.type == .leftMouseDragged {
        if let marquee {
          marqueeModifiers = FileSelectionModifiers(event.modifierFlags.subtracting(.control))
          if moved, !marquee.isDragging {
            selectionBeforeMarquee = state
            if let item = mouseDown.item {
              SelectionChange(.click(item, mouseDown.modifiers))
            } else if marqueeModifiers.isEmpty {
              SelectionChange(.clearItems)
            }
          }
          marquee.OnMouseMoved(to: pointer, crossedThreshold: moved)
        } else if moved {
          if mouseDown.modifiers == .toggle,
             case let .file(row)? = itemsView.pointerTarget(at: event)?.hit,
             let node = fileNode(at: row), !IsSelected(node) {
            SelectionChange(at: row, modifiers: mouseDown.modifiers)
          }
          endTracking()
          return .itemAction(.drag(event, document: mouseDown.document))
        }
        return .handled
      }
      let armedMarquee = isMarqueeActive
      let completedMarquee = marquee?.isDragging == true
      endTracking()
      guard !completedMarquee else { return .handled }
      let hit = itemsView.pointerTarget(at: event)?.hit
      _HandleLeftMouseUp(hit, down: mouseDown, armedMarquee: armedMarquee)
      guard let item = mouseDown.item else { return .handled }
      let releasedItem: FileSelectionNode?
      if case let .file(row)? = hit { releasedItem = fileNode(at: row) } else { releasedItem = nil }
      return .itemAction(.mouseUp(press: mouseDown.event, modifiers: mouseDown.modifiers, item: item, hit: hit, releasedItem: releasedItem))
    case .keyDown where event.keyCode == 53 && isMarqueeActive:
      endTracking(restoreSelection: true)
      return .handled
    default:
      return .ignored
    }
  }

  private func _HandleLeftMouseDown(_ event: NSEvent, in itemsView: FilePaneSurface) -> Bool {
    guard let (document, hit) = itemsView.pointerTarget(at: event) else { return false }
    if case .checkbox = hit { endTracking(); return false }
    endTracking()
    let point = document.convert(event.locationInWindow, from: nil)
    ExplorerFocus.keyboardVisible = false
    (document.window?.firstResponder as? NSView)?.needsDisplay = true
    document.window?.makeFirstResponder(document)
    let modifiers = FileSelectionModifiers(event.modifierFlags)
    switch hit {
    case let .file(row):
      guard let node = fileNode(at: row) else { return false }
      let selected = IsSelected(node)
      let whitespace = document.isClickInItemWhitespace(at: point, row: row)
      let startsMarquee = !selected && whitespace
      let selectsOnRelease = modifiers == .toggle || (modifiers.isEmpty && selected)
      mouseDown = MouseDown(event: event, document: document, item: node, modifiers: modifiers, selectsOnRelease: selectsOnRelease)
      if startsMarquee { _CreateMarquee(at: event.locationInWindow, in: itemsView, document: document) }
      else if !selectsOnRelease { SelectionChange(at: row, modifiers: modifiers) }
    case .background:
      mouseDown = MouseDown(event: event, document: document, item: nil, modifiers: modifiers, selectsOnRelease: false)
      _CreateMarquee(at: event.locationInWindow, in: itemsView, document: document)
    case let .group(row):
      onGroupClick?(row)
      return true
    case .checkbox:
      return false
    }
    if let window = itemsView.window {
      resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
        self?.endTracking(restoreSelection: true)
      }
    }
    if isMarqueeActive { (document as? FileCollectionView)?.refreshExpandedNames() }
    return true
  }

  private func _HandleLeftMouseUp(_ hit: FilePaneHit?, down: MouseDown, armedMarquee: Bool) {
    if armedMarquee, let item = down.item {
      SelectionChange(.click(item, down.modifiers), affected: down.modifiers == .toggle ? topology.rowByNode[item].map { IndexSet(integer: $0) } : nil)
    } else if down.item == nil, down.modifiers.isEmpty, case .background? = hit {
      SelectionChange(.clear)
    } else if down.selectsOnRelease, case let .file(row)? = hit {
      SelectionChange(at: row, modifiers: down.modifiers)
    }
  }

  func _HandleSpaceKey(_ flags: FileSelectionModifiers, fallbackRow: @autoclosure () -> Int?) -> Bool {
    guard flags == .toggle, let row = focusedRow(fallback: fallbackRow()) else { return false }
    SelectionChange(at: row, modifiers: flags)
    return true
  }

  func HandleContextMenu(_ event: NSEvent) -> InputResult {
    guard let hit = itemsView?.pointerTarget(at: event)?.hit else { return .ignored }
    if case .checkbox = hit { return .ignored }
    endTracking()
    _HandleRightMouseDown(hit)
    return .itemAction(.contextMenu(event.locationInWindow))
  }

  private func _HandleRightMouseDown(_ hit: FilePaneHit) {
    if case let .file(row) = hit, let node = fileNode(at: row) {
      if !IsSelected(node) { SelectionChange(at: row, modifiers: []) }
    } else {
      SelectionChange(.clear)
    }
  }

  private func _CreateMarquee(at start: NSPoint, in itemsView: FilePaneSurface, document: any FilePaneDocument) {
    marquee = NativeMarqueeSelection.StartMarquee(host: document, start: start, drawingIn: itemsView,
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
    marquee?.EndMarquee()
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

  deinit {
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }
}
