import AppKit
import ExplorerCore

@main
enum NativeExplorer {
  static func main() {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
    withExtendedLifetime(delegate) {}
  }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
  var window: NSWindow!
  var browser: BrowserController!
  private(set) var browserWindows: [NSWindow] = []
  private let arguments = CommandLine.arguments
  private var focusMonitor: Any?
  private var systemIntegration: NativeSystemIntegration?
  private lazy var versionControl = NativeVersionControl(backupDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mac Explorer Native/vcs-backups"))
  private var pendingExternalURLs: [URL] = []
  private var sessionDefaults: UserDefaults?
  private var lastHomeDirectory: URL?
  private var preserveWindowsOnExit: Bool?
  private var updateInstaller: (() throws -> Void)?
  private var updateTerminationError: Error?

  private func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    let smoke = argument("--smoke-test")
    let comparison = argument("--compare")
    let explicitLocation = smoke ?? comparison ?? argument("--path")
    let quitFixture = smoke.flatMap { NativeQuitChecks.fixture(root: $0, suite: argument("--quit-session-suite")) }
    let defaults: UserDefaults
    if let quitFixture { defaults = quitFixture }
    else if smoke != nil || comparison != nil {
      guard let isolated = UserDefaults(suiteName: "local.macexplorer.native-smoke.\(ProcessInfo.processInfo.processIdentifier)") else {
        fputs("Cannot initialize isolated smoke-test preferences\n", stderr)
        exit(1)
      }
      defaults = isolated
      defaults.set(false, forKey: "iconMode")
      defaults.set(false, forKey: "showHidden")
      defaults.set(["view": "details", "iconSize": 64, "sort": "name", "ascending": true], forKey: "defaultFolderView")
    } else {
      defaults = .standard
    }
    sessionDefaults = defaults
    NativeLanguage.load(from: Bundle.main.resourceURL!.appendingPathComponent("locales"))
    NativeLanguage.mode = smoke != nil || comparison != nil ? "zh-CN" : defaults.string(forKey: "language") ?? "system"
    let appearance = defaults.string(forKey: "theme") ?? "light"
    NSApp.appearance = appearance == "system" ? nil : NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    systemIntegration = NativeSystemIntegration(defaults: defaults, onWake: { [weak self] in
      self?.summon()
    })
    versionControl.setEnabled(defaults.object(forKey: "versionControl") as? Bool ?? true)
    let home = ProcessInfo.processInfo.environment["EXPLORER_NATIVE_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    browser = BrowserController(initial: NativeStartLocation.initialURL(explicit: quitFixture == nil ? explicitLocation : nil, defaults: defaults, home: home), defaults: defaults)
    if smoke != nil || comparison != nil { browser.filePasteboard = NSPasteboard(name: .init("local.macexplorer.native-test.\(ProcessInfo.processInfo.processIdentifier)")) }
    if let comparison {
      browser.home = URL(fileURLWithPath: comparison).deletingLastPathComponent()
      browser.testTrashDirectory = browser.home.appendingPathComponent(".Trash")
    }
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.title = "Mac Explorer"
    window.minSize = NSSize(width: 800, height: 530)
    window.setFrame(NSRect(x: 0, y: 0, width: 1260, height: 820), display: false)
    window.titlebarAppearsTransparent = true
    window.backgroundColor = .explorerChrome
    window.isReleasedWhenClosed = false
    window.contentViewController = browser
    register(window, browser: browser)
    if smoke == nil && comparison == nil { window.setFrameAutosaveName("NativeExplorerWindow") }
    if smoke != nil || comparison != nil { window.setFrame(NSRect(x: 0, y: 0, width: 1180, height: 780), display: false) }
    window.center()
    focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
      ExplorerFocus.keyboardVisible = event.type == .keyDown
      (NSApp.keyWindow?.firstResponder as? NSView)?.needsDisplay = true
      return event
    }
    if smoke == nil && comparison == nil { NativeUpdateCoordinator.current().startAutomaticChecks() }
    makeMenus()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if (quitFixture != nil || smoke == nil && comparison == nil) && argument("--path") == nil && pendingExternalURLs.isEmpty { restoreWindows(defaults: defaults) }
    if !pendingExternalURLs.isEmpty { let urls = pendingExternalURLs; pendingExternalURLs = []; openExternal(urls) }
    if let comparison, let report = argument("--report") {
      Task { @MainActor in
        await NativeSmoke.compare(browser: browser, window: window, root: URL(fileURLWithPath: comparison), report: URL(fileURLWithPath: report))
      }
    }
    if let smoke, let report = argument("--report") {
      Task { @MainActor in
        await NativeSmoke.run(browser: browser, window: window, root: URL(fileURLWithPath: smoke), report: URL(fileURLWithPath: report))
      }
    }
  }

  private func register(_ window: NSWindow, browser: BrowserController) {
    browser.versionControl = versionControl; browser.systemIntegration = systemIntegration
    if !browserWindows.contains(where: { $0 === window }) { browserWindows.append(window) }; window.delegate = self
    browser.onLanguageChange = { [weak self, weak browser] mode in
      guard let self, let browser else { return }; self.setLanguage(mode, defaults: browser.defaults)
    }
    browser.onDetachTab = { [weak self, weak browser] tab, point in
      guard let self, let browser else { return false }
      _ = self.createWindow(tab: tab, source: browser, at: point)
      return true
    }
  }

  @discardableResult
  func createWindow(tab: BrowserTab, source: BrowserController, at point: NSPoint) -> NSWindow {
    if sessionDefaults == nil { sessionDefaults = source.defaults }
    lastHomeDirectory = source.home
    let controller = BrowserController(initial: tab.directory, defaults: source.defaults)
    controller.home = source.home; controller.testTrashDirectory = source.testTrashDirectory; controller.filePasteboard = source.filePasteboard
    controller.adopt(tab)
    let size = source.view.window?.frame.size ?? NSSize(width: 1260, height: 820)
    let next = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    next.titleVisibility = .hidden; next.titlebarAppearsTransparent = true; next.backgroundColor = .explorerChrome
    next.isReleasedWhenClosed = false; next.minSize = NSSize(width: 800, height: 530)
    next.setFrame(NSRect(origin: .zero, size: size), display: false)
    next.contentViewController = controller
    Self.position(next, at: point)
    register(next, browser: controller)
    next.makeKeyAndOrderFront(nil)
    activate(next)
    return next
  }

  static func position(_ window: NSWindow, at point: NSPoint) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? window.screen ?? NSScreen.main else { return }
    let bounds = screen.visibleFrame
    let size = NSSize(width: min(window.frame.width, bounds.width), height: min(window.frame.height, bounds.height))
    let origin = NSPoint(x: max(bounds.minX, min(point.x - 160, bounds.maxX - size.width)), y: max(bounds.minY, min(point.y - size.height + 24, bounds.maxY - size.height)))
    window.setFrame(NSRect(origin: origin, size: size), display: true)
  }

  private func activate(_ owner: NSWindow) {
    guard browserWindows.contains(where: { $0 === owner }) else { return }
    guard let controller = owner.contentViewController as? BrowserController else { return }
    window = owner; browser = controller; makeMenus()
  }
  func windowDidBecomeMain(_ notification: Notification) {
    if let owner = notification.object as? NSWindow { activate(owner) }
  }
  func windowWillClose(_ notification: Notification) {
    guard let owner = notification.object as? NSWindow else { return }
    (owner.contentViewController as? BrowserController)?.stopObserving()
    browserWindows.removeAll { $0 === owner }
    if window === owner {
      if let next = browserWindows.last { activate(next) } else { window = nil; browser = nil }
    }
  }
  @objc private func newWindow() {
    let home = lastHomeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    let source = browser ?? BrowserController(initial: home, defaults: sessionDefaults ?? .standard)
    if browser == nil { source.home = home }
    let top = window.map { NSPoint(x: $0.frame.minX + 180, y: $0.frame.maxY - 20) } ?? NSEvent.mouseLocation
    createWindow(tab: BrowserTab(history: [NativeStartLocation.load(source.defaults).url(home: source.home)]), source: source, at: top)
  }

  private func summon() {
    if window == nil { newWindow() }
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func dockNewTab() {
    if browser == nil { newWindow() } else { browser.newTab() }
    summon()
  }
  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    menu.addItem(withTitle: NL("新建窗口"), action: #selector(newWindow), keyEquivalent: "").target = self
    menu.addItem(withTitle: NL("新建标签页"), action: #selector(dockNewTab), keyEquivalent: "").target = self
    return menu
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { summon() }
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    if browser == nil && sessionDefaults == nil { pendingExternalURLs += urls; return }
    if browser == nil { newWindow() }
    openExternal(urls)
  }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    application(sender, open: filenames.map { URL(fileURLWithPath: $0) }); sender.reply(toOpenOrPrint: .success)
  }
  private func openExternal(_ urls: [URL]) {
    let files = urls.filter { $0.isFileURL && !$0.path.contains("\0") }
    if let first = files.first { browser.openExternal(first) }
    for url in files.dropFirst() { browser.openTab(at: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()); browser.openExternal(url) }
    window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func applicationWillTerminate(_ notification: Notification) {
    systemIntegration?.close(); versionControl.setEnabled(false)
    browserWindows.forEach { ($0.contentViewController as? BrowserController)?.stopObserving() }
    if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
  }

  @objc private func quitNormally() { preserveWindowsOnExit = nil; NSApp.terminate(nil) }
  @objc private func quitKeepingWindows() { preserveWindowsOnExit = true; NSApp.terminate(nil) }
  func installUpdateAndTerminate(_ install: @escaping () throws -> Void) throws {
    guard updateInstaller == nil else { throw NativeUpdateValidation.failure("正在准备更新安装。") }
    updateTerminationError = nil; updateInstaller = install
    NSApp.terminate(nil)
    if let error = updateTerminationError { updateTerminationError = nil; throw error }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let installingUpdate = updateInstaller != nil
    do {
      guard !browserWindows.contains(where: { ($0.contentViewController as? BrowserController)?.busy == true }) else { throw NativeUpdateValidation.failure("文件操作正在进行中") }
      if let defaults = sessionDefaults {
        let states = installingUpdate || (preserveWindowsOnExit ?? (defaults.object(forKey: NativeSessions.restoreAfterQuitKey) as? Bool ?? false)) ? browserWindows.compactMap { owner -> NativeSavedWindow? in
          guard let controller = owner.contentViewController as? BrowserController else { return nil }
          return NativeSavedWindow(locations: controller.tabs.map { $0.directory.absoluteString }, frame: NSStringFromRect(owner.frame))
        } : []
        try NativeSessions.save(states, to: defaults)
        guard defaults.synchronize() else { throw NativeUpdateValidation.failure("无法保存窗口状态。") }
      } else if installingUpdate { throw NativeUpdateValidation.failure("无法保存窗口状态。") }
      // No async gap: an installer starts only after the final busy check and durable session save.
      try updateInstaller?(); updateInstaller = nil
      return .terminateNow
    } catch {
      updateInstaller = nil; preserveWindowsOnExit = nil
      if installingUpdate { updateTerminationError = error }
      else { let alert = NSAlert(); alert.messageText = NL(error.localizedDescription); alert.addButton(withTitle: NL("取消")); alert.runModal() }
      return .terminateCancel
    }
  }

  private func restoreWindows(defaults: UserDefaults) {
    let states = NativeSessions.load(defaults)
    guard let first = states.first else { return }
    browser.restoreLocations(first.locations)
    restoreFrame(first.frame, for: window)
    for state in states.dropFirst() {
      let owner = createWindow(tab: BrowserTab(history: [browser.home]), source: browser, at: NSPoint(x: window.frame.minX + 160, y: window.frame.maxY))
      (owner.contentViewController as? BrowserController)?.restoreLocations(state.locations)
      restoreFrame(state.frame, for: owner)
    }
  }
  private func restoreFrame(_ value: String, for owner: NSWindow) {
    let frame = NSRectFromString(value)
    guard frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite, frame.width >= 800, frame.height >= 530,
          let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return }
    let region = screen.visibleFrame
    let size = NSSize(width: min(frame.width, region.width), height: min(frame.height, region.height))
    owner.setFrame(NSRect(x: max(region.minX, min(frame.minX, region.maxX - size.width)), y: max(region.minY, min(frame.minY, region.maxY - size.height)), width: size.width, height: size.height), display: false)
  }

  private func setLanguage(_ mode: String, defaults: UserDefaults) {
    guard ["system", "zh-CN", "zh-TW", "en"].contains(mode) else { return }
    defaults.set(mode, forKey: "language")
    Task { @MainActor [weak self] in
      guard let self else { return }
      while self.browserWindows.contains(where: { ($0.contentViewController as? BrowserController)?.busy == true }) { try? await Task.sleep(nanoseconds: 100_000_000) }
      NativeLanguage.mode = mode
      let current = self.window
      for owner in self.browserWindows {
        guard let old = owner.contentViewController as? BrowserController else { continue }
        let settingsOpen = ExplorerDialogs.isPresenting(in: owner)
        ExplorerDialogs.close(in: owner); old.stopObserving()
        let next = BrowserController(initial: old.directory, defaults: old.defaults); next.copySession(from: old)
        owner.contentViewController = next; self.register(owner, browser: next)
        if current === owner { self.activate(owner) }
        if settingsOpen { next.executeAction("settings") }
      }
      self.makeMenus()
    }
  }

  private func makeMenus() {
    let main = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: NL("关于 Mac Explorer"), action: #selector(about), keyEquivalent: "").target = self
    app.addItem(withTitle: NL("设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
    app.addItem(.separator())
    app.addItem(withTitle: NL("隐藏 Mac Explorer"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: NL("退出 Mac Explorer"), action: #selector(quitNormally), keyEquivalent: "q").target = self
    app.addItem(withTitle: NL("退出并保留窗口"), action: #selector(quitKeepingWindows), keyEquivalent: "").target = self
    addMenu("Mac Explorer", submenu: app, to: main)
    let file = NSMenu(title: NL("文件"))
    file.addItem(withTitle: NL("新建窗口"), action: #selector(newWindow), keyEquivalent: "n").target = self
    item(NL("新建标签页"), #selector(BrowserController.newTab), "t", in: file)
    let choose = file.addItem(withTitle: NL("打开文件夹…"), action: #selector(chooseDirectory), keyEquivalent: ""); choose.target = self
    item(NL("关闭标签页"), #selector(BrowserController.closeTab), "w", in: file)
    file.addItem(.separator())
    item(NL("打开选中项目"), #selector(BrowserController.openSelected), "\r", in: file)
    item(NL("快速查看"), #selector(BrowserController.previewSelected), "y", in: file)
    item(NL("在 Finder 中显示"), #selector(BrowserController.revealSelected), "", in: file)
    addMenu(NL("文件"), submenu: file, to: main)
    let edit = NSMenu(title: NL("编辑"))
    edit.addItem(withTitle: NL("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: NL("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: NL("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: NL("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    edit.addItem(withTitle: NL("撤销"), action: #selector(BrowserController.undo(_:)), keyEquivalent: "z")
    edit.addItem(withTitle: NL("重做"), action: #selector(BrowserController.redo(_:)), keyEquivalent: "z")
    edit.items.last?.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    item(NL("复制路径"), #selector(BrowserController.copyPaths), "", in: edit)
    addMenu(NL("编辑"), submenu: edit, to: main)
    let navigation = NSMenu(title: NL("前往"))
    item(NL("后退"), #selector(BrowserController.back), "[", in: navigation)
    item(NL("前进"), #selector(BrowserController.forward), "]", in: navigation)
    item(NL("上一级"), #selector(BrowserController.up), String(UnicodeScalar(NSUpArrowFunctionKey)!), in: navigation)
    item(NL("编辑地址"), #selector(BrowserController.focusAddress), "l", in: navigation)
    item(NL("搜索文件"), #selector(BrowserController.focusSearch), "f", in: navigation)
    item(NL("刷新"), #selector(BrowserController.reload), "r", in: navigation)
    addMenu(NL("前往"), submenu: navigation, to: main)
    let appearance = NSMenu(title: NL("外观"))
    for (index, title) in [NL("跟随系统"), NL("浅色"), NL("深色")].enumerated() {
      let option = appearance.addItem(withTitle: title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
      option.tag = index; option.target = self
    }
    addMenu(NL("外观"), submenu: appearance, to: main)
    let windowMenu = NSMenu(title: NL("窗口"))
    windowMenu.addItem(withTitle: NL("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: NL("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    addMenu(NL("窗口"), submenu: windowMenu, to: main)
    NSApp.windowsMenu = windowMenu
    NSApp.mainMenu = main
    browser.syncMenuShortcuts()
  }
  private func item(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu) {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = browser
  }
  private func addMenu(_ title: String, submenu: NSMenu, to menu: NSMenu) {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item)
  }
  @objc func chooseDirectory() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    guard let owner = window, let controller = browser else { return }
    panel.beginSheetModal(for: owner) { [weak controller] response in
      if response == .OK, let url = panel.url { controller?.navigate(to: url) }
    }
  }
  @objc func changeAppearance(_ sender: NSMenuItem) {
    NSApp.appearance = sender.tag == 0 ? nil : NSAppearance(named: sender.tag == 1 ? .aqua : .darkAqua)
  }
  @objc func about() {
    if browser == nil { newWindow() }
    summon(); browser?.executeAction("about")
  }
  @objc private func showSettings() {
    if browser == nil { newWindow() }
    summon(); browser?.executeAction("settings")
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(quitNormally) || menuItem.action == #selector(quitKeepingWindows) { return true }
    return window == nil || !ExplorerDialogs.isPresenting(in: window)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
