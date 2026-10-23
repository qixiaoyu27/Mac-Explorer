import AppKit
import ExplorerCore

@MainActor
enum NativeFinderServersChecks {
  private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  static func run(output: URL) async throws -> [String] {
    let suite = "local.macexplorer.finder-servers." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 760, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close(); defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
    var checks: [String] = []
    func check(_ ok: Bool, _ text: String) throws { guard ok else { throw NativeSmoke.Failure(description: text) }; checks.append(text) }
    let browser = BrowserController(initial: URL(string: "explorer://computer")!, defaults: defaults)
    let settings = NativeSettingsView(browser: browser); settings.frame = NSRect(x: 20, y: 20, width: 460, height: 62)
    let content = SurfaceView(frame: NSRect(x: 0, y: 0, width: 760, height: 620)); window.contentView = content; content.addSubview(settings)
    window.makeKeyAndOrderFront(nil); settings.layoutSubtreeIfNeeded()
    let buttons = descendants(settings).compactMap { $0 as? EDButton }
    guard let folders = buttons.first(where: { $0.title == NL("从 Finder 导入收藏夹") }), let servers = buttons.first(where: { $0.title == NL("从 Finder 导入服务器") }) else { throw NativeSmoke.Failure(description: "Missing adjacent Finder import buttons") }
    try check(folders.frame.minY == servers.frame.minY && folders.frame.maxX < servers.frame.minX, "Finder server import sits beside folder import without overlap")
    for button in [folders, servers] {
      let needed = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 49
      try check(button.frame.width >= needed, "Finder import labels fit the standard settings width")
    }
    try check(servers.frame.maxX <= settings.bounds.width - 24, "Both import buttons leave room for the help control")
    let special = ExplorerSpecialView(defaults: defaults, volumeLoader: { [] }, discoveryEnabled: false)
    special.frame = NSRect(x: 0, y: 100, width: 760, height: 500); content.addSubview(special); special.show("network")
    let favorites = [FinderServer(address: "smb://fixture.invalid/first", name: "Fixture favorite"), FinderServer(address: "smb://offline.invalid/second", name: "Offline favorite")]
    try NativeServerFavorites.merge(favorites, into: defaults); special.layoutSubtreeIfNeeded()
    func texts() -> [String] { descendants(special).compactMap { ($0 as? NSTextField)?.stringValue } }
    try check(texts().contains(NL("收藏的服务器")) && texts().contains("Fixture favorite") && texts().contains("Offline favorite"), "Network page observes imports live and displays offline favorites")
    let connects = descendants(special).compactMap { $0 as? EDButton }.filter { $0.accessibilityLabel()?.hasPrefix("连接“") == true }
    try check(connects.count == 2 && connects.allSatisfy(\.isEnabled), "Imported servers expose connection buttons without automatically mounting")
    special.filter("second"); special.layoutSubtreeIfNeeded()
    try check(!texts().contains("Fixture favorite") && texts().contains("Offline favorite"), "Network search filters favorite names and addresses")
    special.filter(""); try NativeServerFavorites.remove(favorites[0].address, from: defaults); special.layoutSubtreeIfNeeded()
    try check(!texts().contains("Fixture favorite") && texts().contains("Offline favorite"), "Removing a server updates visible network favorites immediately")
    try NativeServerFavorites.merge([favorites[0]], into: defaults); special.layoutSubtreeIfNeeded()
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
      content.cacheDisplay(in: content.bounds, to: bitmap)
      if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent("finder-servers-fixture.png")) }
    }
    // Exercise the real read-only Finder import button into this disposable preference suite.
    servers.performClick(nil)
    let deadline = Date().addingTimeInterval(10)
    while !servers.isEnabled { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Finder server import did not finish") }; try await Task.sleep(nanoseconds: 20_000_000) }
    let statuses = descendants(settings).compactMap { ($0 as? NSTextField)?.stringValue }
    try check(!statuses.contains(where: { $0.contains(NL("无法读取 Finder 收藏的服务器。")) }), "The real Finder server reader completes through the import button without connecting")
    special.show("computer"); special.layoutSubtreeIfNeeded()
    try check(!texts().contains("Fixture favorite"), "Server favorites stay on Network rather than device cards")
    return checks
  }
}
