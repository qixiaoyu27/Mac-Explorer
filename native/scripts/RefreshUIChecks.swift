import AppKit
import ExplorerCore

@MainActor
enum NativeRefreshChecks {
  static func run() async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-refresh-" + UUID().uuidString)
    let folder = root.appendingPathComponent("files"), other = root.appendingPathComponent("other"), trash = root.appendingPathComponent("trash")
    for url in [folder, other, trash] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    for index in 0..<80 { try Data("fixture".utf8).write(to: folder.appendingPathComponent(String(format: "File %03d.txt", index))) }
    let suite = "local.macexplorer.refresh." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl"); defaults.set(true, forKey: "skipTrashConfirmation")
    let browser = BrowserController(initial: folder, defaults: defaults); browser.home = root; browser.testTrashDirectory = trash
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; browser.reload()
    defer { browser.stopObserving(); browser.filePasteboard.releaseGlobally(); window.close(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ value: Bool, _ text: String) throws {
      guard value else { throw NativeSmoke.Failure(description: text) }; checks.append(text); print("PASS refresh: " + text)
    }
    func until(_ condition: () -> Bool, visible: (() -> Bool)? = nil) async throws {
      let end = Date().addingTimeInterval(10)
      while !condition() {
        if let visible, !visible() { throw NativeSmoke.Failure(description: "Refresh hid the existing file list") }
        guard Date() < end else { throw NativeSmoke.Failure(description: "Refresh timed out") }
        try await Task.sleep(nanoseconds: 1_000_000)
      }
      window.contentView?.layoutSubtreeIfNeeded()
    }
    try await until { !browser.loading && browser.entries.count == 80 }
    for mode in [ExplorerLayoutMode.details, .icons, .list] {
      browser.setView(mode); window.contentView?.layoutSubtreeIfNeeded()
      let selected = folder.appendingPathComponent("File 040.txt").path
      browser.selectedPaths = [selected]; browser.updateMode(persist: false)
      let scroll = browser.fileScroll
      let before = browser.entries
      browser.reload()
      try check(browser.loading && browser.entries == before && !scroll.isHidden && browser.loadingView.isHidden, "\(mode): same-directory refresh retains contents without a loading placeholder")
      // A layout update while the read is pending must retain collection data too.
      browser.updateMode(persist: false)
      try check(!scroll.isHidden && (mode == .details || browser.collectionView(browser.collection, numberOfItemsInSection: 0) == before.count), "\(mode): rendering during refresh keeps the old rows available")
      try await until({ !browser.loading }, visible: { !scroll.isHidden && browser.loadingView.isHidden })
      try check(browser.selectedPaths == [selected], "\(mode): refresh preserves selection")
      browser.finishedDragging([])
      try check(!browser.loading && browser.entries == before && !scroll.isHidden, "\(mode): cancelling a drag leaves the list in place")
      browser.executeAction("trash")
      try await until({ !browser.busy && !browser.loading && browser.entries.count == before.count - 1 }, visible: { !scroll.isHidden && browser.loadingView.isHidden })
      try check(!fm.fileExists(atPath: selected) && fm.fileExists(atPath: trash.appendingPathComponent("File 040.txt").path), "\(mode): deletion completes without clearing the remaining rows")
      try fm.moveItem(at: trash.appendingPathComponent("File 040.txt"), to: URL(fileURLWithPath: selected))
      browser.reload(); try await until { !browser.loading && browser.entries.count == 80 }
    }
    let moved = folder.appendingPathComponent("File 000.txt")
    try fm.moveItem(at: moved, to: other.appendingPathComponent(moved.lastPathComponent))
    browser.finishedDragging(.move)
    try check(!browser.loading && !browser.fileScroll.isHidden, "A successful drag refreshes in the background")
    try await until { !browser.entries.contains { $0.id == moved.path } }
    try check(browser.entries.count == 79, "Completed drag removes the moved file from the source listing")
    browser.navigate(to: other)
    try check(browser.entries.isEmpty && browser.fileScroll.isHidden && browser.loadingView.isHidden,
              "Navigating to a different directory clears the previous rows without flashing a loading placeholder")
    try await until { !browser.loading && browser.entries.count == 1 }
    try fm.moveItem(at: other, to: root.appendingPathComponent("renamed"))
    browser.reload(); try await until { !browser.loading }
    try check(browser.entries.isEmpty && browser.snapshot == nil && browser.lastError != nil, "A failed same-directory refresh clears stale files and reports the error")
    let restored = trash.appendingPathComponent("restored.txt")
    try Data("fixture".utf8).write(to: restored)
    browser.navigate(to: URL(string: "explorer://trash")!); try await until { !browser.loading && browser.entries.count == 1 }
    try fm.moveItem(at: restored, to: root.appendingPathComponent("restored.txt"))
    browser.finishedDragging(.move)
    try check(browser.loading && browser.entries.count == 1 && browser.loadingView.isHidden, "Dragging from virtual Trash keeps its existing rows while refreshing")
    try await until { !browser.loading && browser.entries.isEmpty }
    try check(true, "Virtual Trash still refreshes after dragging a file out")
    try check(!window.isVisible, "Refresh checks never display their window")
    return checks
  }
}
