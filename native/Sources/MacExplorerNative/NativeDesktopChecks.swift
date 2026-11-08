import AppKit
import ExplorerCore

@MainActor
enum NativeDesktopChecks {
  static func run() async throws -> [String] {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("native-desktop-" + UUID().uuidString)
    let suite = "local.macexplorer.native-desktop." + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else { throw failure("Cannot create desktop fixture preferences") }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("Folder"), file = root.appendingPathComponent("keep.txt")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("preserve desktop content".utf8).write(to: file)
    try Data().write(to: root.appendingPathComponent(".hidden"))
    try fm.createSymbolicLink(atPath: root.appendingPathComponent("Linked Folder").path, withDestinationPath: folder.path)
    let package = root.appendingPathComponent("Fixture.app")
    try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "fixture.desktop"], format: .xml, options: 0)
    try info.write(to: package.appendingPathComponent("Contents/Info.plist"))
    var folders: [URL] = [], files: [URL] = []
    let desktop = NativeDesktop(defaults: defaults, directory: root, openFolder: { folders.append($0) }, openFile: { files.append($0) })
    let originalKey = NSApp.keyWindow
    desktop.pasteboard = NSPasteboard(name: .init(suite))
    defer { desktop.stop(); desktop.pasteboard.releaseGlobally(); originalKey?.makeKeyAndOrderFront(nil); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ condition: Bool, _ name: String) throws {
      guard condition else { throw failure(name) }; checks.append(name)
    }
    desktop.restore()
    try check(!desktop.enabled && desktop.windows.isEmpty, "Desktop takeover is off by default")
    desktop.setEnabled(true)
    try await until { !desktop.loading }
    try check(desktop.enabled && desktop.error.isEmpty && !desktop.windows.isEmpty, "Enabling creates desktop windows after a successful directory read")
    try check(desktop.windows.count == NSScreen.screens.count && desktop.windows.allSatisfy { !$0.canBecomeMain && $0.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 1 }, "One desktop-level window per display stays below normal browser windows")
    try check(desktop.entries.count == 4 && !desktop.entries.contains { $0.name == ".hidden" }, "Desktop displays files, folders, links and app bundles while excluding hidden files")
    desktop.open(desktop.entries)
    try check(Set(folders.map(\.lastPathComponent)) == ["Folder", "Linked Folder"] && Set(files.map(\.lastPathComponent)) == ["keep.txt", "Fixture.app"], "Folders and linked folders route to Mac Explorer; files and app bundles route to the default application")
    folders.removeAll(); files.removeAll()
    guard let window = desktop.windows.first, let collection = descendants(window.contentView!).compactMap({ $0 as? NSCollectionView }).first,
          let index = desktop.entries.firstIndex(where: { $0.name == "Folder" }) else { throw failure("Desktop collection was not installed") }
    window.contentView?.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded()
    guard let frame = collection.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { throw failure("Desktop item has no layout attributes") }
    let point = collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1) else { throw failure("Cannot create desktop double click") }
    collection.mouseDown(with: event)
    try check(folders.map(\.lastPathComponent) == ["Folder"] && files.isEmpty, "Double clicking a desktop folder opens it through Mac Explorer without opening Finder")
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(collection)
    guard let copy = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else { throw failure("Cannot create desktop copy shortcut") }
    try check(window.performKeyEquivalent(with: copy) && (desktop.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.map(\.lastPathComponent) == ["Folder"], "Desktop Command+C copies the desktop selection to an isolated pasteboard")
    if let target = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).compactMap({ $0.target as? BrowserController }).first {
      let command = NSMenuItem(title: "fixture", action: #selector(BrowserController.closeTab), keyEquivalent: "w")
      try check(!target.validateMenuItem(command), "Desktop focus disables menu actions on a background browser")
    } else { throw failure("Browser menu target not found") }
    // Allow the asynchronous vnode watch to arm before changing the fixture.
    try await Task.sleep(nanoseconds: 300_000_000)
    let added = root.appendingPathComponent("created.txt")
    try Data("external addition".utf8).write(to: added)
    try await until { desktop.entries.contains { $0.name == "created.txt" } }
    try check(true, "Desktop refreshes after an external directory change")
    desktop.stop()
    try check(desktop.windows.isEmpty && defaults.bool(forKey: NativeDesktop.preferenceKey), "Runtime shutdown removes the overlay while preserving the launch preference")
    desktop.restore(); try await until { !desktop.loading }
    try check(desktop.enabled && !desktop.windows.isEmpty, "The enabled preference restores desktop takeover")
    desktop.setEnabled(false)
    try check(desktop.windows.isEmpty && !defaults.bool(forKey: NativeDesktop.preferenceKey), "Disabling removes desktop windows and clears the launch preference")
    desktop.setEnabled(true); desktop.setEnabled(false)
    try await Task.sleep(nanoseconds: 200_000_000)
    try check(!desktop.enabled && desktop.windows.isEmpty, "Disabling during a read prevents a late overlay from appearing")
    let missing = NativeDesktop(defaults: defaults, directory: root.appendingPathComponent("missing"), openFolder: { _ in })
    defer { missing.stop() }
    missing.setEnabled(true); try await until { !missing.loading }
    try check(!missing.enabled && !missing.error.isEmpty && missing.windows.isEmpty && !defaults.bool(forKey: NativeDesktop.preferenceKey), "A failed Desktop read leaves Finder visible and rolls back the switch")
    try check(try Data(contentsOf: file) == Data("preserve desktop content".utf8) && fm.fileExists(atPath: folder.path), "Desktop takeover preserves all original fixture content")
    return checks
  }
  private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private static func failure(_ message: String) -> NativeSmoke.Failure { NativeSmoke.Failure(description: message) }
  private static func until(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard predicate() else { throw failure("Desktop check timed out") }
  }
}
