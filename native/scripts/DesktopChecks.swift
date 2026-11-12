import AppKit
import ExplorerCore

@main
enum DesktopChecks {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApp.appearance = NSAppearance(named: .aqua)
    NativeLanguage.load(from: URL(fileURLWithPath: CommandLine.arguments[1])); NativeLanguage.mode = "zh-CN"
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let fm = FileManager.default, suite = "local.macexplorer.desktop-check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let root = fm.temporaryDirectory.appendingPathComponent(suite)
    let folder = root.appendingPathComponent("Project folder"), file = root.appendingPathComponent("Read me.txt")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Desktop fixture; preserve this file.\n".utf8).write(to: file)
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("Folder link"), withDestinationURL: folder)
    let original = try Data(contentsOf: file)
    defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func expect(_ condition: Bool, _ message: String) throws {
      guard condition else { throw NativeSmoke.Failure(description: message) }; checks.append(message)
      fputs("PASS: \(message)\n", stderr)
    }
    var screens = [
      NativeDesktopDisplay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), visibleFrame: NSRect(x: 0, y: 60, width: 1280, height: 716)),
      NativeDesktopDisplay(frame: NSRect(x: -1024, y: 0, width: 1024, height: 768), visibleFrame: NSRect(x: -1024, y: 0, width: 1024, height: 744))
    ]
    var opened: [URL] = []
    let desktop = NativeDesktop(defaults: defaults, directory: root, showsWindows: false, displays: { screens }, openFolder: { opened.append($0) })
    defer { desktop.close() }
    desktop.restoreOnLaunch()
    try expect(!desktop.isEnabled && desktop.windows.isEmpty && defaults.object(forKey: NativeDesktop.preferenceKey) == nil, "Desktop mode is off by default and creates no windows")
    let settings = NativeDesktopSettingsView(desktop: desktop)
    try expect(!settings.toggle.checked && !settings.restore.isEnabled, "Settings reflect the disabled desktop without a test button")
    defaults.set([root.path: ["view": "details", "iconSize": 32]], forKey: "folderViews")
    let previousViews = defaults.dictionary(forKey: "folderViews")! as NSDictionary
    settings.toggle.performClick(nil)
    try expect(desktop.isEnabled && settings.toggle.checked && settings.restore.isEnabled && defaults.bool(forKey: NativeDesktop.preferenceKey), "Settings enable desktop mode and persist the explicit choice")
    guard let browser = desktop.browser else { throw NativeSmoke.Failure(description: "No desktop controller") }
    browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    defer { browser.filePasteboard.releaseGlobally() }
    try await NativeSmoke.until { !browser.loading && browser.entries.count == 3 }
    try expect(desktop.windows.count == 2 && desktop.windows.allSatisfy { !$0.isVisible }, "Isolated fixtures create two desktop windows without displaying them")
    try expect(desktop.windows.allSatisfy { $0.level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)) && $0.level < .normal && $0.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .ignoresCycle]) && !$0.canBecomeMain && $0.canBecomeKey }, "Desktop stays above Finder icons, below normal windows, across Spaces, outside window cycling")
    try expect(desktop.windows[0].frame == screens[0].frame && desktop.windows[1].frame == screens[1].frame && browser.view.frame == NSRect(x: 0, y: 60, width: 1280, height: 716), "Separate display origins and menu/Dock insets are respected")
    try expect(browser.mode == .icons && browser.tabsBar.isHidden && browser.navigationBar.isHidden && browser.footer.isHidden && !browser.fileScroll.isHidden, "Desktop shows only the file surface and keeps an icon layout")
    browser.selectedPaths = [folder.path]; browser.openSelected()
    try expect(opened.map(\.path) == [folder.path] && browser.directory.path == root.path && browser.tabs.count == 1, "Opening a desktop folder is dispatched to a normal window without navigating the desktop")
    browser.openTab(at: folder); browser.up(); browser.focusAddress(); browser.focusSearch(); browser.closeTab()
    try expect(opened.count == 5 && browser.directory == root && browser.tabs.count == 1 && desktop.isEnabled, "Tab, parent, address, search and close commands cannot replace or close the desktop")
    browser.setView(.details)
    try expect(browser.mode == .icons && previousViews == defaults.dictionary(forKey: "folderViews")! as NSDictionary, "Desktop layout stays separate from the normal folder view preferences")
    browser.selectedPaths = [file.path]; browser.executeAction("copy")
    try expect((browser.filePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == [file], "Copy uses the existing file workflow and isolated clipboard")
    try expect(browser.contextItems().contains { $0.title == "恢复 Finder 桌面" }, "Desktop context menu always includes Restore Finder")
    let window = desktop.windows[0]
    screens = [NativeDesktopDisplay(frame: NSRect(x: -1600, y: -200, width: 1600, height: 900), visibleFrame: NSRect(x: -1550, y: -200, width: 1550, height: 875))]
    desktop.updateDisplays()
    try expect(desktop.windows.count == 1 && desktop.windows[0] === window && desktop.browser === browser && browser.selectedPaths == [file.path], "Display removal and primary-screen changes preserve the controller and selection")
    try expect(browser.view.frame == NSRect(x: 50, y: 0, width: 1550, height: 875), "A side Dock and negative monitor origin keep all icons inside the work area")
    browser.runAsyncOperation { try? await Task.sleep(nanoseconds: 100_000_000); return FileActionResult(succeeded: [], errors: [], changes: []) }
    var blocked = false
    do { try desktop.setEnabled(false) } catch { blocked = true }
    try expect(blocked && desktop.isEnabled && defaults.bool(forKey: NativeDesktop.preferenceKey), "Restore refuses to interrupt an in-flight file operation")
    try await NativeSmoke.until { !browser.busy && !browser.loading }
    try await NativeSmoke.until { IconLoader.shared.isIdle }
    browser.view.layoutSubtreeIfNeeded()
    func capture(_ view: NSView, _ name: String) throws {
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NativeSmoke.Failure(description: "Cannot capture fixture") }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
    }
    try capture(window.contentView!, "desktop-fixture")
    for language in ["zh-CN", "en", "zh-TW"] {
      NativeLanguage.mode = language
      let localized = NativeDesktopSettingsView(desktop: desktop)
      localized.frame = NSRect(x: 0, y: 0, width: 480, height: localized.preferredHeight)
      let canvas = SurfaceView(frame: localized.bounds); canvas.addSubview(localized)
      try capture(canvas, "desktop-settings-" + language)
      try expect(localized.toggle.accessibilityRole() == .checkBox && !localized.toggle.title.isEmpty, "Desktop settings expose a labeled checkbox in \(language)")
    }
    NativeLanguage.mode = "zh-CN"
    try expect(try Data(contentsOf: file) == original && (try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Folder link").path)) == folder.path, "Desktop interactions preserve files and symbolic links")
    settings.restore.performClick(nil)
    try expect(!desktop.isEnabled && desktop.windows.isEmpty && !settings.toggle.checked && !defaults.bool(forKey: NativeDesktop.preferenceKey) && browser.view.window == nil, "One-click restore removes every overlay, stops the file view and updates settings")
    try desktop.setEnabled(true)
    desktop.close()
    try expect(!desktop.isEnabled && defaults.bool(forKey: NativeDesktop.preferenceKey), "Quitting removes overlays while retaining the opt-in for the next launch")
    desktop.restoreOnLaunch()
    try expect(desktop.isEnabled, "An explicit desktop preference is restored on the next launch")
    try desktop.setEnabled(false)
    let unavailable = NativeDesktop(defaults: defaults, directory: root.appendingPathComponent("missing"), showsWindows: false, displays: { screens }, openFolder: { _ in })
    var failed = false
    do { try unavailable.setEnabled(true) } catch { failed = true }
    try expect(failed && unavailable.windows.isEmpty && !defaults.bool(forKey: NativeDesktop.preferenceKey), "An unreadable desktop fails before any overlay or enabled preference is created")
    let empty = root.appendingPathComponent("Empty"); try fm.createDirectory(at: empty, withIntermediateDirectories: false)
    let emptyDesktop = NativeDesktop(defaults: defaults, directory: empty, showsWindows: false, displays: { screens }, openFolder: { _ in })
    defer { emptyDesktop.close() }
    try emptyDesktop.setEnabled(true)
    try await NativeSmoke.until { emptyDesktop.browser?.loading == false }
    try expect(emptyDesktop.browser?.fileScroll.isHidden == false && emptyDesktop.browser?.emptyLabel.isHidden == true && emptyDesktop.browser?.contextItems().contains(where: { $0.title == NL("新建") }) == true, "An empty desktop retains its drop and context-menu surface without an empty-state panel")
    try emptyDesktop.setEnabled(false)
    let data = try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "fixtureOnly": true, "physicalDisplaysTested": false], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: output.appendingPathComponent("report.json"))
    print("Desktop: \(checks.count) isolated checks passed")
  }
}
