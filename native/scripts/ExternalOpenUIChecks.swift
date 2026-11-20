import AppKit
import ExplorerCore

private final class ExternalOpenCheckWindow: NSWindow {
  var simulatedMiniaturized = false
  var simulatedActiveSpace = true
  var simulatedSheet: NSWindow?
  var presentationCalls: [String] = []
  override var isMiniaturized: Bool { simulatedMiniaturized }
  override var isOnActiveSpace: Bool { simulatedActiveSpace }
  override var attachedSheet: NSWindow? { simulatedSheet }
  override func deminiaturize(_ sender: Any?) { simulatedMiniaturized = false; presentationCalls.append("restore") }
  override func makeKeyAndOrderFront(_ sender: Any?) { presentationCalls.append("present") }
}

@MainActor
enum NativeExternalOpenChecks {
  static func run() async throws -> [String] {
    precondition(NSApp.activationPolicy() == .prohibited)
    let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-external-open-" + UUID().uuidString)
    let child = root.appendingPathComponent("Child"), package = root.appendingPathComponent("Fixture.app")
    try fm.createDirectory(at: child, withIntermediateDirectories: true)
    try fm.createDirectory(at: package.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    for index in 0..<300 { try Data("fixture".utf8).write(to: root.appendingPathComponent(String(format: "File %03d.txt", index))) }
    let target = root.appendingPathComponent("File 290.txt")
    let elsewhere = child.appendingPathComponent("Elsewhere.txt"); try Data("fixture".utf8).write(to: elsewhere)
    let suite = "local.macexplorer.external-open." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl")
    defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    let browser = BrowserController(initial: root, defaults: defaults); browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    let window = ExternalOpenCheckWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; browser.reload()
    let delegate = ApplicationDelegate(); delegate.register(window, browser: browser); delegate.browser = browser; delegate.window = window
    defer { browser.stopObserving(); browser.filePasteboard.releaseGlobally(); window.close(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ condition: Bool, _ text: String) throws {
      guard condition else { throw NativeSmoke.Failure(description: text) }
      checks.append(text); print("PASS external open: " + text)
    }
    func loaded(_ directory: URL, in current: BrowserController? = nil) async throws {
      let current = current ?? browser
      let deadline = Date().addingTimeInterval(8)
      while current.loading || current.directory.path != directory.path || current.snapshot?.directory.path != directory.path {
        guard Date() < deadline else { throw NativeSmoke.Failure(description: "External open load timed out") }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      current.view.layoutSubtreeIfNeeded(); current.collection.layoutSubtreeIfNeeded()
    }
    func visible(_ url: URL, in current: BrowserController? = nil) -> Bool {
      let browser = current ?? browser
      guard let index = browser.entries.firstIndex(where: { $0.id == url.path }), let row = browser.displayRows.firstIndex(where: { $0.entry == index }) else { return false }
      if browser.mode == .details { return browser.table.visibleRect.intersects(browser.table.rect(ofRow: row)) }
      guard let rect = browser.collectionLayout.layoutAttributesForItem(at: IndexPath(item: row, section: 0))?.frame else { return false }
      return browser.collection.visibleRect.intersects(rect)
    }
    try await loaded(root)
    try check(!visible(target), "External target starts outside the visible file list")
    delegate.application(NSApp, open: [target]); try await loaded(root)
    try check(browser.selectedPaths == [target.path] && visible(target), "A running app selects and scrolls to the externally requested file")
    try check(window.presentationCalls == ["present"], "An external request presents the existing window")
    browser.navigate(to: child); try await loaded(child)
    delegate.application(NSApp, open: [target]); try await loaded(root)
    try check(browser.selectedPaths == [target.path] && visible(target) && !visible(child), "External reveal from a child folder overrides the parent-navigation scroll target")
    browser.setView(.icons, size: 64)
    delegate.application(NSApp, open: [root.appendingPathComponent("File 000.txt")]); try await loaded(root)
    try check(!visible(target), "Icon view target also starts outside its viewport")
    delegate.application(NSApp, open: [target]); try await loaded(root)
    try check(browser.selectedPaths == [target.path] && visible(target), "Icon view scrolls to the externally requested file")
    delegate.application(NSApp, open: [package]); try await loaded(root)
    try check(browser.selectedPaths == [package.path] && visible(package), "Application bundles are revealed in their parent rather than entered")
    delegate.application(NSApp, open: [child]); try await loaded(child)
    try check(browser.selectedPaths.isEmpty, "Ordinary external folders still open directly")
    window.presentationCalls = []; window.simulatedMiniaturized = true
    delegate.application(NSApp, open: [target]); try await loaded(root)
    try check(window.presentationCalls == ["restore", "present"], "External open restores a minimized window before presenting it")
    let previousTabCount = browser.tabs.count
    delegate.application(NSApp, open: [target, package]); try await loaded(root)
    try check(browser.tabs.count == previousTabCount && browser.selectedPaths == [target.path, package.path] && !browser.tabs.contains { $0.history.contains(package) }, "Same-folder files and packages share one selection without entering a bundle")
    let sourceTab = browser.activeTab
    delegate.application(NSApp, open: [target, elsewhere]); try await loaded(child)
    try check(browser.tabs.count == previousTabCount + 1 && browser.selectedPaths == [elsewhere.path], "External files in different folders open separate tabs")
    browser.switchTab(to: sourceTab); try await loaded(root)
    try check(browser.selectedPaths == [target.path] && visible(target), "Returning to an earlier external tab preserves its target and scroll position")
    delegate.application(NSApp, open: [root.appendingPathComponent("missing.txt")])
    try check(browser.directory.path == root.path && browser.lastError == NL("项目不存在或无法访问"), "An unavailable external target preserves the current location and reports an error")

    let spareBrowser = BrowserController(initial: child, defaults: defaults); spareBrowser.home = root; spareBrowser.filePasteboard = browser.filePasteboard
    let spareWindow = ExternalOpenCheckWindow(contentRect: window.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    spareWindow.isReleasedWhenClosed = false; spareWindow.contentViewController = spareBrowser
    delegate.register(spareWindow, browser: spareBrowser)
    defer { spareBrowser.stopObserving(); spareWindow.close() }
    window.simulatedSheet = NSOpenPanel()
    let blockedSelection = browser.selectedPaths, blockedTabCount = browser.tabs.count
    delegate.application(NSApp, open: [elsewhere]); try await loaded(child, in: spareBrowser)
    try check(delegate.window === spareWindow && spareBrowser.selectedPaths == [elsewhere.path], "An external request skips a window with a system file picker and uses an available window")
    try check(window.attachedSheet != nil && browser.directory.path == root.path && browser.selectedPaths == blockedSelection && browser.tabs.count == blockedTabCount, "External reveal preserves the file picker owner's location, selection and tabs")
    window.simulatedSheet = nil; spareWindow.simulatedActiveSpace = false
    delegate.application(NSApp, open: [target]); try await loaded(root)
    try check(delegate.window === window && delegate.browserWindows.count == 2, "Routing reuses the available active-Space window")
    try check(!window.isVisible && !spareWindow.isVisible, "External routing checks display no windows")

    let start = root.appendingPathComponent("Startup", isDirectory: true)
    try fm.createDirectory(at: start, withIntermediateDirectories: true)
    defaults.set(NativeStartLocation.custom.rawValue, forKey: NativeStartLocation.preferenceKey)
    defaults.set(start.path, forKey: NativeStartLocation.customPathKey)
    let savedMenu = NSApp.mainMenu, savedWindowsMenu = NSApp.windowsMenu
    var presented: [(directory: String, activate: Bool)] = []
    let reopened = ApplicationDelegate(presentBrowserWindow: { owner, activate in
      guard let controller = owner.contentViewController as? BrowserController else { return }
      presented.append((controller.directory.path, activate))
      _ = controller.view
      controller.viewDidAppear()
    })
    defer {
      for owner in reopened.browserWindows { owner.close() }
      NSApp.mainMenu = savedMenu; NSApp.windowsMenu = savedWindowsMenu
    }
    reopened.createWindow(tab: BrowserTab(history: [start]), source: browser, at: .zero, show: false).close()
    try check(reopened.browserWindows.isEmpty && reopened.browser == nil, "Closing the last browser leaves a running delegate with zero windows")
    reopened.application(NSApp, open: [target])
    try check(presented.map(\.directory) == [root.path] && presented.first?.activate == true, "A warm file-open request presents one window already at its target folder")
    guard let reopenedBrowser = reopened.browser, let reopenedWindow = reopened.window else { throw NativeSmoke.Failure(description: "File-open did not create a browser window") }
    if let bounds = (reopenedWindow.screen ?? NSScreen.main)?.visibleFrame {
      let frame = reopenedWindow.frame
      try check(abs(frame.midX - bounds.midX) < 1 && abs(frame.midY - bounds.midY) < 1, "The first window is centered in the screen's usable area")
    }
    try await loaded(root, in: reopenedBrowser)
    try check(reopened.browserWindows.count == 1 && reopenedBrowser.tabs.count == 1 && reopenedBrowser.tabs[0].history.map(\.path) == [root.path], "The configured startup folder does not enter the reopened window's history")
    try check(reopenedBrowser.selectedPaths == [target.path], "The reopened window selects the requested file on its first load")
    try check(visible(target, in: reopenedBrowser), "The reopened window scrolls to the requested file on its first load")
    try check(reopenedBrowser.defaults === defaults && !reopenedWindow.isVisible, "The reopened browser keeps its preferences and is tested without displaying a window")
    reopenedWindow.close()
    reopened.application(NSApp, open: [])
    try check(reopened.browserWindows.isEmpty && presented.count == 1, "An empty open request does not recreate the closed window")
    return checks
  }
}
