import AppKit
import ExplorerCore

@MainActor
enum NativeHistoryPropertiesChecks {
  static func run(output: URL) async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("native-history-properties-" + UUID().uuidString)
    let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), trash = root.appendingPathComponent("trash")
    for folder in [source, target, trash] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    let suite = "local.macexplorer.history-properties." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl"); defaults.set(true, forKey: "skipTrashConfirmation")
    let browser = BrowserController(initial: source, defaults: defaults); browser.home = root; browser.testTrashDirectory = trash
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    let key = NSApp.keyWindow, window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    defer { ExplorerDialogs.close(in: window); browser.stopObserving(); window.close(); key?.makeKeyAndOrderFront(nil); browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ value: @autoclosure () throws -> Bool, _ title: String) throws { guard try value() else { throw NativeSmoke.Failure(description: title) }; checks.append(title); print("PASS history/properties: " + title) }
    func until(_ predicate: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(10)
      while !predicate() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "History/properties timed out: " + (browser.lastError ?? "none")) }; try await Task.sleep(nanoseconds: 20_000_000) }
    }
    func idle() async throws { try await until { !browser.busy && !browser.loading } }
    func go(_ url: URL) async throws { browser.navigate(to: url); try await idle() }
    func enabled(_ id: String) -> Bool {
      let selection = browser.selectedPaths; browser.selectedPaths = []; defer { browser.selectedPaths = selection }
      return browser.contextItems().first { $0.title == NL(id == "undo" ? "撤销" : "重做") }?.enabled == true
    }
    func transfer(_ names: [String], move: Bool = false) async throws {
      try await go(source); browser.reload(); try await idle(); browser.selectedPaths = Set(names.map { source.appendingPathComponent($0).path })
      browser.executeAction(move ? "cut" : "copy"); try await go(target); browser.executeAction("paste"); try await idle()
    }
    func replay(_ id: String) async throws { browser.executeAction(id); try await idle() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func children(_ parent: NSWindow) -> [NSWindow] { (parent.childWindows ?? []).flatMap { [$0] + children($0) } }
    func views() -> [NSView] { children(window).compactMap(\.contentView).flatMap(descendants) }
    func button(_ title: String) throws -> EDButton {
      guard let value = views().compactMap({ $0 as? EDButton }).first(where: { $0.title == title }) else { throw NativeSmoke.Failure(description: "Missing property button: " + title) }; return value
    }
    func capture(_ name: String) throws {
      guard let content = children(window).last?.contentView else { throw NativeSmoke.Failure(description: "Missing properties capture") }; content.layoutSubtreeIfNeeded()
      guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw NativeSmoke.Failure(description: "Missing properties bitmap") }; content.cacheDisplay(in: content.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
    }
    let file = source.appendingPathComponent("copy.txt"), copy = target.appendingPathComponent("copy.txt")
    try Data("original".utf8).write(to: file); try await transfer(["copy.txt"])
    let identity = try FileActions.identity(copy)
    try Data("edited copy".utf8).write(to: copy, options: [])
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try await until { window.isKeyWindow && NSApp.isActive }
    try check(window.makeFirstResponder(browser.collection), "File history fixture focuses the active collection")
    try check(NSApp.sendAction(#selector(BrowserController.undo(_:)), to: nil, from: nil), "Edit-menu Undo reaches the active file browser through the responder chain")
    try await idle(); try check(!fm.fileExists(atPath: copy.path) && enabled("redo"), "Undo Copy retains a recoverable object and enables Redo")
    try Data("changed source".utf8).write(to: file)
    try await replay("redo")
    try check(try String(contentsOf: copy) == "edited copy" && FileActions.identity(copy) == identity, "Redo restores the actual edited copy, without reading a changed original")
    for _ in 0..<2 { try await replay("undo"); try await replay("redo") }
    try check(try String(contentsOf: copy) == "edited copy", "Repeated Undo/Redo preserves copied bytes")
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
    editor.allowsUndo = true; browser.view.addSubview(editor)
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try await until { window.isKeyWindow && NSApp.isActive }
    try check(window.makeFirstResponder(editor) && window.firstResponder === editor, "Text history fixture has actual keyboard focus")
    editor.undoManager?.beginUndoGrouping(); editor.insertText("text edit", replacementRange: NSRange(location: 0, length: 0)); editor.undoManager?.endUndoGrouping()
    try check(editor.undoManager?.canUndo == true, "Text fixture registers a real undoable edit")
    let textUndo = NSApp.sendAction(#selector(BrowserController.undo(_:)), to: nil, from: nil)
    try check(textUndo && editor.string.isEmpty && fm.fileExists(atPath: copy.path), "Edit-menu Undo edits focused text without consuming file history; handled=\(textUndo), text=\(editor.string), copyExists=\(fm.fileExists(atPath: copy.path))")
    try check(NSApp.sendAction(#selector(BrowserController.redo(_:)), to: nil, from: nil) && editor.string == "text edit" && !enabled("redo"), "Edit-menu Redo edits focused text without replaying file history")
    window.makeFirstResponder(browser.collection); editor.removeFromSuperview()
    // A new operation abandons the redo branch.
    try await replay("undo"); try Data("second".utf8).write(to: source.appendingPathComponent("new.txt")); try await transfer(["new.txt"])
    try check(!enabled("redo") && !fm.fileExists(atPath: copy.path), "A new successful file operation clears the abandoned redo branch")
    try Data("move".utf8).write(to: source.appendingPathComponent("move.txt")); try await transfer(["move.txt"], move: true)
    try await replay("undo"); try check(fm.fileExists(atPath: source.appendingPathComponent("move.txt").path), "Undo Move restores the original location")
    try await replay("redo"); try check(!fm.fileExists(atPath: source.appendingPathComponent("move.txt").path) && (try String(contentsOf: target.appendingPathComponent("move.txt"))) == "move", "Redo Move consumes only the restored source")
    browser.selectedPaths = [target.appendingPathComponent("move.txt").path]; browser.executeAction("trash"); try await idle(); try await replay("undo"); try await replay("redo")
    try check(!fm.fileExists(atPath: target.appendingPathComponent("move.txt").path), "Trash Undo/Redo reuses a protected reversible move")
    for name in ["batch-a.txt", "batch-b.txt"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
    try await transfer(["batch-a.txt", "batch-b.txt"]); try await replay("undo")
    let collision = target.appendingPathComponent("batch-a.txt"); try Data("do not overwrite".utf8).write(to: collision)
    try await replay("redo")
    try check(try String(contentsOf: collision) == "do not overwrite" && fm.fileExists(atPath: target.appendingPathComponent("batch-b.txt").path) && enabled("redo"), "Partial Redo preserves collisions and retains only failed history for retry")
    try fm.removeItem(at: collision); try await replay("redo")
    try check(try String(contentsOf: collision) == "batch-a.txt" && !enabled("redo"), "Retrying partial Redo restores the remaining item once")
    try await replay("undo")
    let saved = try fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("batch-a") }!
    try fm.moveItem(at: saved, to: root.appendingPathComponent("retained-original")); try Data("replacement".utf8).write(to: saved)
    try await replay("redo")
    try check(try String(contentsOf: saved) == "replacement" && !fm.fileExists(atPath: collision.path) && enabled("redo"), "Redo refuses a replaced history object and preserves its replacement")
    // General editing and extended property pages use an independent fixture.
    let property = target.appendingPathComponent("properties.txt"); try Data("property payload".utf8).write(to: property)
    browser.reload(); try await idle(); browser.selectedPaths = [property.path]; browser.executeAction("properties")
    try await until { ExplorerDialogs.isPresenting(in: window) && views().contains { ($0 as? EDButton)?.title == NL("保存") && ($0 as? EDButton)?.isEnabled == true } }
    guard let field = views().first(where: { $0.identifier?.rawValue == "property-name" }) as? NSTextField else { throw NativeSmoke.Failure(description: "Missing editable property name") }
    try check(field.isEditable, "Single-selection General page allows name editing")
    field.stringValue = "renamed.txt"
    try button(NL("详细信息")).onPress?()
    try check(views().contains { ($0 as? NSTextField)?.stringValue == property.path }, "Details page displays the complete filesystem path")
    try capture("native-properties-details.png")
    try button(NL("权限")).onPress?()
    try check(views().contains { ($0 as? NSTextField)?.stringValue == NL("POSIX 权限") }, "Permissions page displays filesystem ownership and mode without fabricating NTFS ACLs")
    try capture("native-properties-permissions.png")
    try button(NL("常规")).onPress?()
    try check(field.stringValue == "renamed.txt", "Switching property pages preserves an unsaved name")
    try capture("native-properties-general.png")
    try button(NL("取消")).onPress?()
    try check(fm.fileExists(atPath: property.path) && !fm.fileExists(atPath: target.appendingPathComponent("renamed.txt").path), "Cancelling property edits leaves the fixture unchanged")
    browser.executeAction("properties")
    try await until { views().contains { ($0 as? EDButton)?.title == NL("保存") && ($0 as? EDButton)?.isEnabled == true } }
    let edit = views().first { $0.identifier?.rawValue == "property-name" } as! NSTextField
    edit.stringValue = "renamed.txt"; try button(NL("保存")).onPress?(); try await idle()
    let renamed = target.appendingPathComponent("renamed.txt")
    try check(!fm.fileExists(atPath: property.path) && (try String(contentsOf: renamed)) == "property payload", "Saving General properties performs a protected rename")
    try await replay("undo"); try await replay("redo")
    try check(try String(contentsOf: renamed) == "property payload", "Property rename participates in Undo/Redo")
    browser.selectedPaths = [renamed.path, target.appendingPathComponent("new.txt").path]; browser.executeAction("properties")
    try await until { ExplorerDialogs.isPresenting(in: window) }
    try check(views().compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "property-name" }?.isEditable == false, "Multiple selections do not offer an ambiguous batch property rename")
    ExplorerDialogs.close(in: window)
    return checks
  }
}
