import AppKit
import ExplorerCore

struct NativeDesktopDisplay {
  let frame: NSRect
  let visibleFrame: NSRect
  var imageURL: URL?
  var imageOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [:]

  static func connected() -> [NativeDesktopDisplay] {
    NSScreen.screens.map { NativeDesktopDisplay(frame: $0.frame, visibleFrame: $0.visibleFrame,
      imageURL: NSWorkspace.shared.desktopImageURL(for: $0), imageOptions: NSWorkspace.shared.desktopImageOptions(for: $0) ?? [:]) }
  }
}

final class NativeDesktop: NSObject, NSWindowDelegate {
  static let changed = Notification.Name("NativeDesktopChanged")
  static let preferenceKey = "desktopMode"
  let defaults: UserDefaults
  let directory: URL
  let openFolder: (URL) -> Void
  weak var integration: NativeSystemIntegration?
  var onFocus: (() -> Void)?
  var onLanguageChange: ((String) -> Void)?
  private(set) var browser: BrowserController?
  private(set) var windows: [NSWindow] = []
  private(set) var error = ""
  private let displays: () -> [NativeDesktopDisplay]
  private let showsWindows: Bool
  private var screenObserver: NSObjectProtocol?
  private var spaceObserver: NSObjectProtocol?
  private var appearanceObserver: NSObjectProtocol?
  var isEnabled: Bool { browser != nil }
  var isBusy: Bool { browser?.busy == true }
  var focusedBrowser: BrowserController? { windows.contains(where: { $0.isKeyWindow }) ? browser : nil }

  init(defaults: UserDefaults, directory: URL, showsWindows: Bool = true,
       displays: @escaping () -> [NativeDesktopDisplay] = NativeDesktopDisplay.connected,
       openFolder: @escaping (URL) -> Void) {
    self.defaults = defaults; self.directory = directory; self.showsWindows = showsWindows
    self.displays = displays; self.openFolder = openFolder
    super.init()
  }

  func restoreOnLaunch() {
    guard defaults.bool(forKey: Self.preferenceKey) else { return }
    do { try setEnabled(true) } catch { report(error) }
  }

  func setEnabled(_ enabled: Bool) throws {
    guard !isBusy else { throw NativeUpdateValidation.failure("文件操作正在进行中") }
    if enabled && !isEnabled {
      // Check permission before covering Finder; a denied desktop must remain usable.
      _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      guard !displays().isEmpty else { throw NativeUpdateValidation.failure("没有可用的显示器。") }
      browser = BrowserController(initial: directory, defaults: defaults, desktop: self)
      browser?.systemIntegration = integration
      browser?.onLanguageChange = onLanguageChange
      updateDisplays()
      screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.updateDisplays() }
      spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updateDisplays() }
      appearanceObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.updateDisplays() }
    } else if !enabled { close() }
    defaults.set(enabled, forKey: Self.preferenceKey)
    error = ""; notify()
  }

  func updateDisplays() {
    guard let browser else { return }
    let screens = displays()
    // Keep the controller and in-flight file operations alive while displays change.
    while windows.count > screens.count {
      let window = windows.removeLast(); window.contentViewController = nil; window.close()
    }
    for (index, screen) in screens.enumerated() {
      if index == windows.count {
        let window = NativeDesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hasShadow = false; window.isOpaque = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false; window.isExcludedFromWindowsMenu = true; window.delegate = self
        let wallpaper = NativeDesktopWallpaper()
        wallpaper.desktop = self
        let host = NSViewController(); host.view = wallpaper; window.contentViewController = host
        windows.append(window)
      }
      let window = windows[index]
      window.setFrame(screen.frame, display: true)
      let wallpaper = window.contentView as! NativeDesktopWallpaper
      wallpaper.configure(screen)
      if index == 0 {
        if let host = window.contentViewController, browser.parent !== host { browser.removeFromParent(); host.addChild(browser) }
        if browser.view.superview !== wallpaper { wallpaper.addSubview(browser.view) }
        let visible = screen.visibleFrame.intersection(screen.frame)
        browser.view.frame = NSRect(x: visible.minX - screen.frame.minX, y: visible.minY - screen.frame.minY, width: visible.width, height: visible.height)
        browser.view.layoutSubtreeIfNeeded()
      }
      if showsWindows { window.orderFront(nil) }
    }
    if !screens.isEmpty, browser.snapshot == nil, !browser.loading { browser.reload() }
  }

  func windowDidBecomeKey(_ notification: Notification) { onFocus?() }
  func windowDidResignKey(_ notification: Notification) { onFocus?() }
  func windowShouldClose(_ sender: NSWindow) -> Bool { restoreFinder(); return false }

  @objc func restoreFinder() {
    do { try setEnabled(false) }
    catch { report(error); let alert = NSAlert(); alert.messageText = NL(error.localizedDescription); alert.runModal() }
  }

  func menuItems() -> [ExplorerMenuItem] {
    [ExplorerMenuItem(title: NL("在 Mac Explorer 中打开桌面"), icon: "folder", action: { [weak self] in guard let self else { return }; self.openFolder(self.directory) }),
     ExplorerMenuItem(title: NL("恢复 Finder 桌面"), divider: true, action: { [weak self] in self?.restoreFinder() })]
  }

  func close() {
    if isEnabled { ExplorerMenu.dismiss() }
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
    if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }; spaceObserver = nil
    if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }; appearanceObserver = nil
    browser?.stopObserving(); browser?.view.removeFromSuperview(); browser?.removeFromParent(); browser = nil
    let old = windows; windows = []
    for window in old { ExplorerDialogs.close(in: window); window.delegate = nil; window.close() }
    onFocus?()
  }

  private func report(_ failure: Error) { error = NL(failure.localizedDescription); notify() }
  private func notify() { NotificationCenter.default.post(name: Self.changed, object: self); onFocus?() }
  deinit { close() }
}

final class NativeDesktopWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class NativeDesktopWallpaper: NSView {
  weak var desktop: NativeDesktop?
  private var image: NSImage?
  private var imageURL: URL?
  private var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
  override var isOpaque: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  func configure(_ display: NativeDesktopDisplay) {
    if imageURL != display.imageURL { imageURL = display.imageURL; image = imageURL.flatMap(NSImage.init(contentsOf:)) }
    options = display.imageOptions; needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    (options[.fillColor] as? NSColor ?? NSColor(calibratedWhite: 0.16, alpha: 1)).setFill(); bounds.fill()
    guard let image, image.size.width > 0, image.size.height > 0 else { return }
    let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
    let clip = options[.allowClipping] as? Bool ?? true
    let ratio = clip ? max(bounds.width / image.size.width, bounds.height / image.size.height) : min(bounds.width / image.size.width, bounds.height / image.size.height)
    let scale = scaling == .scaleNone ? 1 : scaling == .scaleProportionallyDown ? min(1, ratio) : ratio
    let size = scaling == .scaleAxesIndependently ? bounds.size : NSSize(width: image.size.width * scale, height: image.size.height * scale)
    image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
  }
  override func mouseDown(with event: NSEvent) { window?.makeKey(); if event.clickCount == 2, let desktop { desktop.openFolder(desktop.directory) } }
  override func rightMouseDown(with event: NSEvent) {
    guard let window, let desktop else { return }
    window.makeKey(); ExplorerMenu.show(desktop.menuItems(), at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
  }
}
