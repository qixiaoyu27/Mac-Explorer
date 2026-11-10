import AppKit

enum FileItemInput {
  case mouseUp(press: NSEvent, modifiers: FileSelectionModifiers, item: FileSelectionNode, hit: FilePaneHit?, releasedItem: FileSelectionNode?)
  case contextMenu(NSPoint)
  case drag(NSEvent, document: NSView)
  case activate
}

final class ItemActionsManager: NSObject, NSDraggingSource {
  var openSelection: (() -> Void)?
  var showContext: ((NSPoint) -> Void)?
  var draggedURLs: (() -> [URL])?
  var finishedDragging: ((NSDragOperation) -> Void)?

  func HandleInputEvent(_ input: FileItemInput) {
    switch input {
    case let .mouseUp(press, modifiers, item, hit, releasedItem):
      if press.clickCount == 2, modifiers.isEmpty, !_IsCheckboxTarget(hit), item == releasedItem {
        _ItemActivate()
      }
    case let .contextMenu(point):
      _ShowContextMenu(at: point)
    case let .drag(event, document):
      _BeginDragSource(event, from: document)
    case .activate:
      _ItemActivate()
    }
  }

  private func _ItemActivate() { openSelection?() }
  private func _ShowContextMenu(at point: NSPoint) { showContext?(point) }

  private func _IsCheckboxTarget(_ hit: FilePaneHit?) -> Bool {
    if case .checkbox? = hit { return true }
    return false
  }

  private func _BeginDragSource(_ event: NSEvent, from document: NSView) {
    guard let urls = draggedURLs?(), !urls.isEmpty else { return }
    let point = document.convert(event.locationInWindow, from: nil)
    let frame = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
    let items = urls.map { url in
      let item = NSDraggingItem(pasteboardWriter: url as NSURL)
      item.draggingFrame = frame
      item.imageComponentsProvider = {
        let icon = NSDraggingImageComponent(key: .icon)
        icon.frame = NSRect(origin: .zero, size: frame.size)
        icon.contents = NSWorkspace.shared.icon(forFile: url.path)
        return [icon]
      }
      return item
    }
    document.beginDraggingSession(with: items, event: event, source: self).draggingFormation = .stack
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    [.copy, .move]
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    finishedDragging?(operation)
  }
}
