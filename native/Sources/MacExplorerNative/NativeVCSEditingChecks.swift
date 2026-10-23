import AppKit
import ExplorerCore
import Quartz

@MainActor
enum NativeVCSEditingChecks {
  static func run() async throws -> [String] {
    var checks: [String] = [], failures: [String] = []
    let originalKey = NSApp.keyWindow
    defer { originalKey?.makeKeyAndOrderFront(nil) }
    for scenario in ["enable", "disable", "unchanged"] {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent("native-vcs-edit-\(UUID().uuidString)")
      try fm.createDirectory(at: root, withIntermediateDirectories: false)
      let repo = root.appendingPathComponent("repo"), file = repo.appendingPathComponent("tracked.txt")
      try fm.createDirectory(at: repo, withIntermediateDirectories: false)
      let gitEnvironment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
      func git(_ arguments: [String]) throws { _ = try NativeCommand.run(executable: "/usr/bin/git", arguments: arguments, directory: repo, environment: gitEnvironment) }
      try git(["init", "-b", "main"])
      try git(["config", "user.name", "Native UI Fixture"]); try git(["config", "user.email", "fixture@example.invalid"])
      try git(["config", "core.hooksPath", "/dev/null"]); try git(["config", "commit.gpgSign", "false"])
      try Data("original".utf8).write(to: file); try git(["add", "tracked.txt"]); try git(["commit", "-m", "Fixture"])
      try Data("modified".utf8).write(to: file)
      let suite = "NativeVCSEditingChecks.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
      defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
      defaults.set("preview", forKey: "paneMode")
      defaults.set(scenario != "enable", forKey: "versionControl")
      let service = NativeVersionControl(backupDirectory: root.appendingPathComponent("backups"))
      service.setEnabled(scenario != "enable")
      let browser = BrowserController(initial: repo, defaults: defaults)
      browser.home = root; browser.versionControl = service; browser.filePasteboard = NSPasteboard(name: .init(suite))
      let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 980, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentViewController = browser
      defer { browser.stopObserving(); service.setEnabled(false); window.close(); browser.filePasteboard.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); browser.reload()
      try await until { NSApp.isActive && window.isKeyWindow && !browser.loading && reads(browser) == 0 }
      if scenario != "enable" { try await until { browser.entries.contains(where: { $0.name == "tracked.txt" && $0.vcsMark == "M" }) } }
      guard let index = browser.entries.firstIndex(where: { $0.name == "tracked.txt" }) else { throw NativeSmoke.Failure(description: "VCS editing fixture file is visible") }
      browser.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      window.contentView?.layoutSubtreeIfNeeded()
      func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
      guard let preview = descendants(browser.pane).first(where: { $0 is QLPreviewView }) else { throw NativeSmoke.Failure(description: "VCS editing fixture has a real preview") }
      if scenario == "unchanged" {
        let cell = browser.table.view(atColumn: 0, row: index, makeIfNecessary: true)
        browser.setVersionControl(true)
        try await until { reads(browser) == 0 }
        record(descendants(browser.pane).contains(where: { $0 === preview }), "Unchanged VCS status retains the existing Quick Look preview", checks: &checks, failures: &failures)
        record(browser.table.view(atColumn: 0, row: index, makeIfNecessary: true) === cell, "Unchanged VCS status retains the existing file row", checks: &checks, failures: &failures)
      }
      browser.executeAction("rename")
      guard let field = (browser.table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NameCell)?.nameLabel,
            let editor = field.currentEditor() as? NSTextView else { throw NativeSmoke.Failure(description: "VCS editing fixture starts an actual inline editor (\(scenario))") }
      // Earlier suite checks launch child applications; explicitly regain activation
      // before asserting this real window's editor focus.
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.makeFirstResponder(editor)
      try await until { window.isKeyWindow && window.firstResponder === editor && field.currentEditor() === editor }
      let draft = "unsaved-\(scenario).txt"; editor.string = draft
      browser.setVersionControl(scenario != "disable")
      try await until { reads(browser) == 0 }
      record(field.currentEditor() === editor && field.isEditable && editor.string == draft && editor.window === window, "VCS \(scenario) preserves the active inline editor and unsaved draft [key=\(window.isKeyWindow), active=\(NSApp.isActive), editor=\(field.currentEditor() === editor), editable=\(field.isEditable), draft=\(editor.string == draft), owner=\(editor.window === window), first=\(window.firstResponder === editor)]", checks: &checks, failures: &failures)
      record(fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: repo.appendingPathComponent(draft).path) && (try? String(contentsOf: file)) == "modified", "VCS \(scenario) never commits or discards the rename on disk", checks: &checks, failures: &failures)
      _ = browser.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }
    guard failures.isEmpty else { throw NativeSmoke.Failure(description: failures.joined(separator: "; ")) }
    return checks
  }

  // Observe the existing task counter so an unchanged result is checked after the real callback.
  // This keeps the production controller free of a test-only callback or polling API.
  private static func reads(_ browser: BrowserController) -> Int? { Mirror(reflecting: browser).children.first(where: { $0.label == "vcsReads" })?.value as? Int }
  private static func record(_ value: Bool, _ message: String, checks: inout [String], failures: inout [String]) {
    print("VCS EDIT \(value ? "PASS" : "FAIL"): \(message)")
    if value { checks.append(message) } else { failures.append(message) }
  }
  private static func until(line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() { guard Date() < deadline else { throw NativeSmoke.Failure(description: "VCS editor check timed out at line \(line)") }; try await Task.sleep(nanoseconds: 20_000_000) }
  }
}
