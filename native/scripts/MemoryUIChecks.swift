import AppKit
import ExplorerCore
import Darwin

@MainActor
enum NativeMemoryChecks {
  static func run() async throws -> [String] {
    let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("native-memory-" + UUID().uuidString)
    let repo = root.appendingPathComponent("repo"), other = root.appendingPathComponent("other")
    try fm.createDirectory(at: repo, withIntermediateDirectories: true); try fm.createDirectory(at: other, withIntermediateDirectories: true)
    _ = try NativeCommand.run(executable: "/usr/bin/git", arguments: ["init", "-b", "main", repo.path], environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"])
    let first = repo.appendingPathComponent("first.txt"), second = repo.appendingPathComponent("second.txt")
    try Data(String(repeating: "a", count: 20_000).utf8).write(to: first); try Data("latest selection".utf8).write(to: second)
    let link = repo.appendingPathComponent("link.txt"), fifo = repo.appendingPathComponent("pipe.txt")
    try fm.createSymbolicLink(at: link, withDestinationURL: second)
    guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(.EIO) }
    let image = repo.appendingPathComponent("image.png"), binary = repo.appendingPathComponent("binary.txt")
    try Data([0, 1, 2]).write(to: binary); try Data().write(to: image)
    try Data("other folder".utf8).write(to: other.appendingPathComponent("other.txt"))
    let suite = "local.macexplorer.memory." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "versionControl")
    let browser = BrowserController(initial: repo, defaults: defaults); browser.home = root
    browser.filePasteboard = NSPasteboard(name: .init(suite))
    let service = NativeVersionControl(backupDirectory: root.appendingPathComponent("backups"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = browser; browser.reload()
    defer { browser.stopObserving(); service.setEnabled(false); window.close(); browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
    var checks: [String] = []
    func check(_ ok: Bool, _ text: String) throws { guard ok else { throw NativeSmoke.Failure(description: text) }; checks.append(text); print("PASS memory: " + text) }
    func until(line: UInt = #line, _ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(6)
      while !condition() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "Memory check timed out at line \(line): loading=\(browser.loading), directory=\(browser.directory.path), vcsReads=\(field("vcsReads", as: Int.self) ?? -1)") }; try await Task.sleep(nanoseconds: 20_000_000) }
    }
    func field<T>(_ name: String, as type: T.Type) -> T? { Mirror(reflecting: browser).children.first { $0.label == name }?.value as? T }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func previewTask() -> Task<NativeFilePreview, Error>? { field("paneReadTask", as: Task<NativeFilePreview, Error>.self) }
    func vcsTask() -> Task<NativeVCSStatus?, Error>? { field("vcsTask", as: Task<NativeVCSStatus?, Error>.self) }
    func select(_ url: URL) { browser.selectedPaths = [url.path]; browser.updateMode(persist: false) }
    func paneText() -> String? { descendants(browser.pane).compactMap { ($0 as? NSTextView)?.string }.first }
    try await until { !browser.loading && browser.entries.count == 6 }
    let entries = browser.entries
    func entry(_ url: URL) -> FileEntry { entries.first { $0.url == url }! }
    let text = try NativeFilePreview.read(entry(first))
    try check(text.text?.utf8.count == 16_384 && text.truncated, "Text previews remain capped at 16 KB")
    try check(try NativeFilePreview.read(entry(link)).text == "latest selection", "Text preview still follows links to regular files")
    try check(try NativeFilePreview.read(entry(fifo)).text == nil, "A FIFO is rejected without blocking a preview worker")
    try check(try NativeFilePreview.read(entry(binary)).text == nil, "Binary files remain excluded from text previews")
    try check(!NativeFilePreview.supports(entry(image)), "Images use the bounded thumbnail service instead of raw preview data")
    browser.paneMode = "details"; select(first)
    guard let original = previewTask() else { throw NativeSmoke.Failure(description: "Details text read did not start") }
    for _ in 0..<100 { browser.updateMode(persist: false) }
    try check(previewTask() == original && !original.isCancelled, "Repeated renders of the same selection reuse one text read")
    for index in 0..<100 { select(index.isMultiple(of: 2) ? first : second) }
    try check(previewTask() == original && original.isCancelled, "Rapid selection replaces the pending file while keeping one active read")
    try await until { previewTask() == nil && paneText() == "latest selection" }
    browser.updateMode(persist: false)
    try check(previewTask() == nil && paneText() == "latest selection", "Unchanged selection reuses its completed preview and ignores stale results")
    let icon = descendants(browser.pane).first { $0.identifier?.rawValue == "icon" } as! FileIconView
    try check(Mirror(reflecting: icon).children.first { $0.label == "pixels" }?.value as? Int == 140, "Details request a 140 pixel thumbnail for the 70 point icon")
    select(first)
    let closing = previewTask()
    browser.paneMode = ""; browser.updateMode(persist: false)
    try check(closing?.isCancelled == true, "Closing the details pane cancels its active text read")
    try await until { previewTask() == nil }

    let index = repo.appendingPathComponent(".git/index")
    guard mkfifo(index.path, 0o600) == 0 else { throw POSIXError(.EIO) }
    browser.versionControl = service
    func refresh() { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window) }
    func blockedWriter() async throws -> Int32 {
      var descriptor: Int32 = -1
      try await until { descriptor = open(index.path, O_WRONLY | O_NONBLOCK); return descriptor >= 0 }
      return descriptor
    }
    refresh()
    guard let statusRead = vcsTask(), let generation = field("vcsGeneration", as: Int.self) else { throw NativeSmoke.Failure(description: "VCS read did not start") }
    for _ in 0..<100 { refresh() }
    try check(vcsTask() == statusRead && field("vcsReads", as: Int.self) == 1 && field("vcsPendingRefresh", as: Bool.self) == true, "A forced-refresh burst keeps one VCS task and one pending refresh")
    let writer = try await blockedWriter()
    try fm.removeItem(at: index); close(writer)
    try await until { field("vcsReads", as: Int.self) == 0 }
    try check(field("vcsGeneration", as: Int.self) == generation + 1 && browser.entries.first { $0.url == second }?.vcsMark == "?", "The coalesced forced refresh runs once and applies the latest repository state")

    guard mkfifo(index.path, 0o600) == 0 else { throw POSIXError(.EIO) }
    refresh()
    let navigating = vcsTask(), navigationWriter = try await blockedWriter()
    defer { close(navigationWriter) }
    browser.navigate(to: other)
    try check(navigating?.isCancelled == true, "Navigation cancels the old directory's active VCS read")
    try await until { !browser.loading && browser.directory.path == other.path && field("vcsReads", as: Int.self) == 0 }
    try check(browser.entries.count == 1 && browser.entries[0].vcsMark == nil, "Cancelled VCS results cannot mark files in the new directory")
    browser.paneMode = "details"; select(other.appendingPathComponent("other.txt"))
    refresh(); refresh()
    let stoppedPreview = previewTask(), stoppedVCS = vcsTask()
    browser.stopObserving()
    try check(stoppedPreview?.isCancelled == true && stoppedVCS?.isCancelled == true, "Closing the browser cancels both preview and VCS reads")
    try await until { previewTask() == nil && field("vcsReads", as: Int.self) == 0 }
    try check(field("vcsPendingRefresh", as: Bool.self) == nil && paneText() == nil, "A stopped browser starts no pending work and applies no late preview")
    try check(!NSApp.windows.contains { $0.isVisible }, "Memory regressions run without showing windows")
    return checks
  }
}
