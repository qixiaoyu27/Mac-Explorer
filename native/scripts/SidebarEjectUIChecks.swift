import AppKit
import ExplorerCore

@MainActor
enum NativeSidebarEjectChecks {
  static func run(output: URL) async throws -> [String] {
    var checks: [String] = []
    func check(_ value: Bool, _ text: String) throws {
      guard value else { throw NativeSmoke.Failure(description: text) }
      checks.append(text); print("PASS sidebar eject: " + text)
    }
    func until(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(15)
      while !condition() {
        guard Date() < deadline else { throw NativeSmoke.Failure(description: "Sidebar eject timed out") }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
    }
    func button(_ row: ExplorerSidebarRow) -> ExplorerButton? {
      row.subviews.compactMap { $0 as? ExplorerButton }.first { $0.iconName == "eject" }
    }
    var opened = 0, expanded = 0, ejected = 0
    let row = ExplorerSidebarRow(title: "Installer with a long name 安装程序", icon: "drive", level: 1) { opened += 1 }
    try check(button(row)?.isHidden == true, "Ordinary rows have no visible eject control")
    row.onExpand = { expanded += 1 }; row.onEject = { ejected += 1 }
    for width: CGFloat in [176, 240] {
      row.frame.size = NSSize(width: width, height: 36); row.needsLayout = true; row.layoutSubtreeIfNeeded()
      guard let eject = button(row) else { throw NativeSmoke.Failure(description: "Missing eject button") }
      try check(!eject.isHidden && row.bounds.contains(eject.frame) && row.hitTest(NSPoint(x: eject.frame.midX, y: eject.frame.midY)) === eject, "Eject is visible and independently clickable at width \(Int(width))")
    }
    button(row)?.performClick(nil)
    try check(ejected == 1 && opened == 0 && expanded == 0, "Eject does not navigate or expand the row")
    row.ejectEnabled = false; button(row)?.performClick(nil)
    try check(ejected == 1 && button(row)?.isEnabled == false, "Disabled eject cannot be clicked again")
    try check(row.accessibilityCustomActions()?.contains { $0.name == NL("推出") } == true && button(row)?.accessibilityLabel()?.contains("Installer") == true, "Eject has a named accessibility action and volume label")

    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("explorer-eject-" + UUID().uuidString)
    let source = root.appendingPathComponent("source"), name = "ME-Eject-" + UUID().uuidString
    let mount = URL(fileURLWithPath: "/Volumes/" + name), image = root.appendingPathComponent("fixture.dmg")
    try fm.createDirectory(at: source.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: source.appendingPathComponent("Folder/file.txt"))
    defer {
      if fm.fileExists(atPath: mount.path) { _ = try? NativeCommand.run(executable: "/usr/bin/hdiutil", arguments: ["detach", mount.path], timeout: 15) }
      try? fm.removeItem(at: root)
    }
    _ = try NativeCommand.run(executable: "/usr/bin/hdiutil", arguments: ["create", "-srcfolder", source.path, "-fs", "HFS+", "-volname", name, "-format", "UDRO", image.path])
    _ = try NativeCommand.run(executable: "/usr/bin/hdiutil", arguments: ["attach", "-readonly", "-noautoopen", image.path])
    try check(try NativeVolumes.list().contains { $0.path == mount.path && $0.canEject }, "A real fixture disk image is recognized as ejectable")

    let suite = "local.macexplorer.eject." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(false, forKey: "versionControl")
    let browser = BrowserController(initial: mount.appendingPathComponent("Folder"), defaults: defaults); browser.home = source
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; browser.reload()
    defer { browser.stopObserving(); browser.filePasteboard.releaseGlobally(); window.close(); defaults.removePersistentDomain(forName: suite) }
    func rows() -> [ExplorerSidebarRow] { browser.sidebarDocument.subviews.compactMap { $0 as? ExplorerSidebarRow } }
    try await until { !browser.loading && browser.entries.count == 1 }
    window.contentView?.layoutSubtreeIfNeeded()
    guard let mountedRow = rows().first(where: { $0.toolTip == mount.path }), let eject = button(mountedRow) else { throw NativeSmoke.Failure(description: "Fixture mount is missing from sidebar") }
    try check(!eject.isHidden && eject.isEnabled, "The mounted installer has an enabled sidebar eject button")
    try check(rows().filter { $0.toolTip == "/" || $0.placePath != nil || $0.toolTip == source.path }.allSatisfy { button($0)?.isHidden == true }, "System disk and quick access keep eject hidden")
    let sidebar = browser.sidebarDocument
    sidebar.layoutSubtreeIfNeeded(); sidebar.displayIfNeeded()
    if let bitmap = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
      sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("sidebar-eject-fixture.png"))
    }
    eject.performClick(nil)
    try check(!eject.isEnabled && browser.directory.path == mount.appendingPathComponent("Folder").path, "Click immediately disables repeat eject without opening the mount")
    try await until { !fm.fileExists(atPath: mount.path) && !rows().contains { $0.toolTip == mount.path } && browser.directory.absoluteString == "explorer://computer" }
    try check(true, "Click unmounts only the fixture, removes its sidebar row and leaves the ejected folder")
    try check(!window.isVisible, "Eject checks keep their window hidden")
    return checks
  }
}
