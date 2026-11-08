import AppKit
import ExplorerCore

/// An application-owned desktop surface. Finder preferences and Desktop files are
/// never changed: removing these windows immediately exposes Finder again.
final class NativeDesktop: NSObject {
  static let preferenceKey = "desktopEnabled"
  static let didChange = Notification.Name("MacExplorerDesktopDidChange")
  private let defaults: UserDefaults
  let directory: URL
  private let openFolder: (URL) -> Void
  private let openFile: (URL) -> Void
  private let watcher = DirectoryWatcher()
  private var load: Task<Void, Never>?
  private var generation = 0
  private var observers: [NSObjectProtocol] = []
  private(set) var windows: [NSWindow] = []
  private(set) var entries: [FileEntry] = []
  private(set) var enabled = false
  private(set) var loading = false
  private(set) var error = ""
  var pasteboard: NSPasteboard = .general
  static func owns(_ window: NSWindow?) -> Bool { window is NativeDesktopWindow }

  init(defaults: UserDefaults, directory: URL, openFolder: @escaping (URL) -> Void,
       openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
    self.defaults = defaults; self.directory = directory
    self.openFolder = openFolder; self.openFile = openFile
    super.init()
  }

  func restore() { if defaults.bool(forKey: Self.preferenceKey) { setEnabled(true) } }

  func setEnabled(_ value: Bool) {
    guard value != enabled || (!value && loading) else { return }
    if !value {
      stop(); defaults.set(false, forKey: Self.preferenceKey); error = ""; changed(); return
    }
    enabled = true; error = ""
    // Read successfully before covering Finder. A denied Desktop permission must
    // leave the original desktop usable, with the switch and error in sync.
    watcher.watch(directory) { [weak self] in self?.reload() }
    reload()
  }

  func reload() {
    guard enabled else { return }
    generation += 1; let requested = generation
    load?.cancel(); loading = true; changed()
    let directory = directory
    load = Task { @MainActor [weak self] in
      let worker = Task.detached(priority: .userInitiated) { try DirectoryReader.read(directory) }
      do {
        let snapshot = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard let self, !Task.isCancelled, self.enabled, self.generation == requested else { return }
        self.entries = EntryQuery.apply(snapshot.entries, showHidden: false, query: "", sort: .name, ascending: true)
        self.loading = false; self.error = ""
        if self.windows.isEmpty { self.startWindows() }
        guard self.enabled else { return }
        self.refreshItems(); self.defaults.set(true, forKey: Self.preferenceKey); self.changed()
      } catch {
        guard let self, !Task.isCancelled, self.generation == requested else { return }
        self.stop(); self.defaults.set(false, forKey: Self.preferenceKey)
        self.error = NL("无法读取桌面：{0}", error.localizedDescription); self.changed()
      }
    }
  }

  /// Stop runtime resources without changing the user's launch preference.
  func stop() {
    enabled = false; loading = false; generation += 1; load?.cancel(); load = nil
    watcher.stop()
    observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
    windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll(); entries.removeAll()
  }

  func open(_ items: [FileEntry]) {
    for entry in items {
      // Refresh classification at activation time; an application bundle should
      // launch normally, never be browsed as a plain directory.
      guard let values = try? entry.url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { continue }
      if values.isDirectory == true && values.isPackage != true { openFolder(entry.url) }
      else { openFile(entry.url) }
    }
  }

  func showFolder() { openFolder(directory) }
  private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }

  private func startWindows() {
    rebuildWindows()
    guard enabled else { return }
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuildWindows() })
    // Refresh wallpaper when returning to the app (including after system wallpaper
    // changes). No screen recording or accessibility permission is needed.
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.windows.forEach { ($0.contentView as? NativeDesktopSurface)?.refreshWallpaper() }
    })
  }

  private func rebuildWindows() {
    windows.forEach { $0.orderOut(nil); $0.close() }; windows.removeAll()
    guard enabled else { return }
    for (index, screen) in NSScreen.screens.enumerated() {
      let window = NativeDesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
      window.setFrame(screen.frame, display: false)
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
      window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      window.isReleasedWhenClosed = false; window.hasShadow = false
      window.backgroundColor = .black; window.isOpaque = true
      window.title = NL("Mac Explorer 桌面")
      guard let surface = NativeDesktopSurface(desktop: self, screen: screen, showsItems: index == 0) else {
        stop(); defaults.set(false, forKey: Self.preferenceKey)
        error = NL("无法读取桌面壁纸，请选择静态壁纸后重试。")
        changed(); return
      }
      window.contentView = surface
      windows.append(window); window.orderBack(nil)
    }
    refreshItems()
  }

  private func refreshItems() {
    windows.forEach { ($0.contentView as? NativeDesktopSurface)?.reload(entries) }
  }
}

private final class NativeDesktopWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let collection = firstResponder as? NativeDesktopCollection, collection.handleShortcut(event) { return true }
    return super.performKeyEquivalent(with: event)
  }
}

/// Uses the system's still wallpaper image. Dynamic/video wallpaper animation,
/// Finder icon coordinates and desktop widgets are not reproduced by this surface.
private final class NativeDesktopSurface: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
  private weak var desktop: NativeDesktop?
  private let screen: NSScreen
  private let showsItems: Bool
  private let scroll = NSScrollView()
  let collection = NativeDesktopCollection()
  private var entries: [FileEntry] = []
  private var wallpaper: NSImage?
  private var hasWallpaper = false
  private var wallpaperOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [:]

  init?(desktop: NativeDesktop, screen: NSScreen, showsItems: Bool) {
    self.desktop = desktop; self.screen = screen; self.showsItems = showsItems
    super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    refreshWallpaper()
    // Do not cover Finder with an unexpected black desktop when a video-only or
    // unavailable wallpaper cannot provide a still image.
    guard hasWallpaper else { return nil }
    let layout = NSCollectionViewFlowLayout()
    layout.itemSize = NSSize(width: 104, height: 108)
    layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 8
    layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    collection.collectionViewLayout = layout
    collection.register(NativeDesktopItem.self, forItemWithIdentifier: .init("desktop-file"))
    collection.dataSource = self; collection.delegate = self
    collection.isSelectable = true; collection.allowsMultipleSelection = true
    collection.backgroundColors = [.clear]
    collection.setDraggingSourceOperationMask(.copy, forLocal: false)
    collection.setDraggingSourceOperationMask(.copy, forLocal: true)
    collection.onOpen = { [weak self] in self?.openSelection() }
    collection.onCopy = { [weak self] in self?.copySelection() }
    collection.onMenu = { [weak self] event in self?.showMenu(event) }
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true; scroll.documentView = collection
    collection.autoresizingMask = [.width]
    scroll.isHidden = !showsItems; addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    scroll.frame = NSRect(x: visible.minX, y: bounds.height - visible.maxY, width: visible.width, height: visible.height)
    collection.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, collection.frame.height)))
  }
  func refreshWallpaper() {
    let url = NSWorkspace.shared.desktopImageURL(for: screen)
    let image = url.flatMap { NSImage(contentsOf: $0) }
    let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
    // Preserve the previous usable still image if a later wallpaper change is
    // unsupported, instead of suddenly obscuring the desktop with black.
    guard image != nil || (url == nil && options[.fillColor] is NSColor) else { return }
    wallpaper = image; wallpaperOptions = options; hasWallpaper = true
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    (wallpaperOptions[.fillColor] as? NSColor ?? .black).setFill(); bounds.fill()
    guard let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 else { return }
    let scaling = (wallpaperOptions[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
    var size = bounds.size
    if scaling != NSImageScaling.scaleAxesIndependently.rawValue {
      let clip = wallpaperOptions[.allowClipping] as? Bool ?? true
      var ratio = clip ? max(bounds.width / wallpaper.size.width, bounds.height / wallpaper.size.height) : min(bounds.width / wallpaper.size.width, bounds.height / wallpaper.size.height)
      if scaling == NSImageScaling.scaleNone.rawValue { ratio = 1 }
      if scaling == NSImageScaling.scaleProportionallyDown.rawValue { ratio = min(1, ratio) }
      size = NSSize(width: wallpaper.size.width * ratio, height: wallpaper.size.height * ratio)
    }
    wallpaper.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
  func reload(_ values: [FileEntry]) {
    let selected = Set(selectedEntries.map(\.id))
    entries = showsItems ? values : []
    collection.reloadData()
    collection.selectionIndexPaths = Set(entries.enumerated().compactMap { selected.contains($0.element.id) ? IndexPath(item: $0.offset, section: 0) : nil })
  }
  private var selectedEntries: [FileEntry] { collection.selectionIndexPaths.sorted().compactMap { entries.indices.contains($0.item) ? entries[$0.item] : nil } }
  private func openSelection() { desktop?.open(selectedEntries) }
  private func copySelection() {
    let urls = selectedEntries.map { $0.url as NSURL }
    guard !urls.isEmpty, let pasteboard = desktop?.pasteboard else { return }
    pasteboard.clearContents(); pasteboard.writeObjects(urls)
  }
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = collectionView.makeItem(withIdentifier: .init("desktop-file"), for: indexPath) as! NativeDesktopItem
    item.configure(entries[indexPath.item]); return item
  }
  func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? { entries[indexPath.item].url as NSURL }
  override func rightMouseDown(with event: NSEvent) { showMenu(event) }
  private func showMenu(_ event: NSEvent) {
    if let path = collection.indexPathForItem(at: collection.convert(event.locationInWindow, from: nil)) {
      if !collection.selectionIndexPaths.contains(path) { collection.selectionIndexPaths = [path] }
    } else { collection.selectionIndexPaths = [] }
    let menu = NSMenu()
    if !selectedEntries.isEmpty {
      menu.addItem(withTitle: NL("打开"), action: #selector(openFromMenu), keyEquivalent: "").target = self
      menu.addItem(withTitle: NL("复制"), action: #selector(copyFromMenu), keyEquivalent: "").target = self
      menu.addItem(.separator())
    }
    menu.addItem(withTitle: NL("在 Mac Explorer 中打开桌面"), action: #selector(showFolder), keyEquivalent: "").target = self
    menu.addItem(withTitle: NL("刷新"), action: #selector(refresh), keyEquivalent: "").target = self
    menu.addItem(withTitle: NL("关闭桌面接管"), action: #selector(disable), keyEquivalent: "").target = self
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }
  @objc private func openFromMenu() { openSelection() }
  @objc private func copyFromMenu() { copySelection() }
  @objc private func showFolder() { desktop?.showFolder() }
  @objc private func refresh() { desktop?.reload() }
  @objc private func disable() { desktop?.setEnabled(false) }
}

private final class NativeDesktopCollection: NSCollectionView {
  var onOpen: (() -> Void)?
  var onCopy: (() -> Void)?
  var onMenu: ((NSEvent) -> Void)?
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    // Capture before AppKit's tracking loop, which may consume the double click.
    let item = indexPathForItem(at: convert(event.locationInWindow, from: nil))
    if event.clickCount == 2, let item {
      if !selectionIndexPaths.contains(item) { selectionIndexPaths = [item] }
      onOpen?(); return
    }
    super.mouseDown(with: event)
  }
  override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
  @objc func copy(_ sender: Any?) { onCopy?() }
  func handleShortcut(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags == .command else { return false }
    if event.charactersIgnoringModifiers?.lowercased() == "c" { onCopy?(); return true }
    if event.charactersIgnoringModifiers?.lowercased() == "a" { selectAll(nil); return true }
    if event.keyCode == 125 || event.keyCode == 36 { onOpen?(); return true }
    return false
  }
  override func keyDown(with event: NSEvent) {
    if handleShortcut(event) { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 36 && flags.isEmpty { onOpen?(); return }
    if event.keyCode == 53 { selectionIndexPaths = []; return }
    super.keyDown(with: event)
  }
}

private final class NativeDesktopItem: NSCollectionViewItem {
  private let icon = FileIconView()
  private let name = NSTextField(wrappingLabelWithString: "")
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 108))
    view.wantsLayer = true; view.layer?.cornerRadius = 6
    icon.frame = NSRect(x: 28, y: 52, width: 48, height: 48)
    icon.imageScaling = .scaleProportionallyUpOrDown
    name.frame = NSRect(x: 2, y: 4, width: 100, height: 44)
    name.font = .systemFont(ofSize: 12); name.textColor = .white
    name.alignment = .center; name.maximumNumberOfLines = 2; name.lineBreakMode = .byTruncatingMiddle
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black; shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
    name.shadow = shadow
    view.addSubview(icon); view.addSubview(name)
    textField = name; imageView = icon
  }
  override var isSelected: Bool { didSet { view.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.75) : .clear).cgColor } }
  func configure(_ entry: FileEntry) {
    name.stringValue = entry.name; view.toolTip = entry.url.path; icon.show(entry, pixels: 128)
    view.setAccessibilityLabel(entry.name)
  }
  override func prepareForReuse() { super.prepareForReuse(); icon.clear() }
}
