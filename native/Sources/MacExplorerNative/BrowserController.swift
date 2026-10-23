import AppKit
import ExplorerCore
import Quartz
import UniformTypeIdentifiers

struct BrowserLocationState: Codable {
  var selection = Set<String>()
  var origin = NSPoint.zero
  var layout = ""
  var anchor: String?
  var anchorOffset = NSPoint.zero
  var revealPath: String?
}

struct BrowserTab: Codable {
  var id = UUID()
  var history: [URL]
  var index = 0
  var selectedPaths = Set<String>()
  var locationStates: [Int: BrowserLocationState] = [:]
  enum CodingKeys: String, CodingKey { case id, history, index, selectedPaths }
  var directory: URL { history[index] }
}

final class BrowserController: NSViewController, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTextFieldDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  var versionControl: NativeVersionControl?
  var systemIntegration: NativeSystemIntegration?
  private var vcsStatus: NativeVCSStatus?
  private var vcsGeneration = 0
  private var vcsReads = 0
  private var vcsTimer: Timer?
  private var focusObserver: NSObjectProtocol?
  var onLanguageChange: ((String) -> Void)?
  var onDetachTab: ((BrowserTab, NSPoint) -> Bool)?
  private(set) var tabs: [BrowserTab]
  private(set) var activeTab = 0
  private(set) var snapshot: DirectorySnapshot?
  private(set) var entries: [FileEntry] = []
  private(set) var loading = false
  private(set) var lastError: String?
  private(set) var displayedMilliseconds = 0.0
  private var pendingLocationState: BrowserLocationState?
  var directory: URL { tabs[activeTab].directory }
  private var viewingTrash: Bool { directory.absoluteString == "explorer://trash" || directory.isFileURL && (directory.path == home.appendingPathComponent(".Trash").path || directory.path.hasPrefix(home.appendingPathComponent(".Trash").path + "/") || directory.pathComponents.contains(".Trashes")) }
  private var writable: Bool { directory.isFileURL && !searchActive && !viewingTrash }
  var selectedPaths: Set<String> { get { tabs[activeTab].selectedPaths } set { tabs[activeTab].selectedPaths = newValue } }
  var showHidden = false, ascending = true, compact = false, checkboxes = false, extensions = true, navigationPane = true
  var sort: EntrySort = .name
  var mode: ExplorerLayoutMode = .icons
  var iconSize: CGFloat = 64
  var iconMode: Bool { get { mode == .icons } set { mode = newValue ? .icons : .details } }
  var paneMode = ""
  var home: URL
  let defaults: UserDefaults
  private var generation = 0, queryGeneration = 0
  private var addressSubmission = 0
  private var startedAt = Date()
  private var loadTask: Task<DirectorySnapshot, Error>?
  private var queryTask: Task<[FileEntry], Never>?
  private var searchTask: Task<FileSearchResult, Error>?
  private var syncingSortDescriptors = false
  private var syncingSelection = false
  private var previewURLs: [NSURL] = []
  private var searchActive = false
  private static let filesType = NSPasteboard.PasteboardType("electron application/osclipboard;format=\"local.macexplorer.files\"")
  private var clipboard: [URL] = []
  private var isCut = false
  private var clipboardChange = -1
  private var shortcutOverrides: [String: String] = [:]
  private var toolbarOrder = ["cut", "copy", "paste", "rename", "share", "trash"]
  var fileErrorNetworkLocation: (URL) -> Bool? = NativeFileFailure.networkLocation
  var recycleItem: (URL, URL?, NSWindow) async throws -> URL = { try await NativeRecycle.recycle($0, cloudRoot: $1, window: $2) }
  private(set) var detailColumns = DetailColumns()
  private var syncingColumns = false
  private var undoChanges: [[FileActionChange]] = []
  private var redoChanges: [[FileActionChange]] = []
  private(set) var busy = false
  var filePasteboard = NSPasteboard.general
  private var renamingEntry: FileEntry?
  private weak var renameField: NSTextField?
  private var pendingRename: String?
  var testTrashDirectory: URL?
  private var message = ""
  private var operationError: String?
  private var needsFullDiskAccess = false
  var cloudDrive: URL? { let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"); return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : nil }
  private var virtualLocation = ""
  private var savedFolderViews: [String: [String: Any]] = [:]
  private var expanded = Set<String>()
  private var folderChildren: [String: [FileEntry]] = [:]
  private var folderErrors: [String: String] = [:]
  private var sidebarRows: [(URL, ExplorerSidebarRow)] = []
  private var places: QuickAccessState
  private var placeRows: [(URL, ExplorerSidebarRow, CGFloat)] = []
  private let placeMarker = SurfaceView()
  private var dragValidation: (Int, Int, Bool)?
  private var settingsObserver: NSObjectProtocol?
  private var preferencesObserver: NSObjectProtocol?
  private var preferencesWork: DispatchWorkItem?
  private var preferenceSnapshot: NSDictionary = [:]
  private(set) var inputNavigation: NativeInputNavigation?
  private static let placesChanged = Notification.Name("NativeExplorerPlacesChanged")
  private var stopped = false
  private let directoryWatcher = DirectoryWatcher()
  private var automaticRead: Task<(DirectorySnapshot, [FileEntry]), Error>?
  private var refreshWork: DispatchWorkItem?
  private var refreshPending = false
  private(set) var automaticRefreshCount = 0
  private var keyMonitor: Any?
  private var paletteObserver: NSObjectProtocol?

  let table = FileTableView(), collection = FileCollectionView()
  let tableScroll = NSScrollView(), collectionScroll = NSScrollView()
  let content = SurfaceView()
  lazy var specialView = ExplorerSpecialView(defaults: defaults)
  let addressBar = ExplorerAddressBar(), searchBox = ExplorerSearchBox()
  var address: NSTextField { addressBar.field }
  var search: NSTextField { searchBox.field }
  let status = label("", size: 12, color: ExplorerPalette.secondary)
  let emptyLabel = label("", size: 15, color: ExplorerPalette.secondary)
  let spinner = NSProgressIndicator()
  let loadingView = ExplorerLoadingView()
  let tabsBar = ExplorerTabBar(), navigationBar = SurfaceView(), commandBar = SurfaceView(), footer = SurfaceView(), sidebar = SurfaceView(), pane = SurfaceView()
  let tabsDocument = SurfaceView(), tabsScroll = NSScrollView(), sidebarScroll = NSScrollView(), sidebarDocument = SurfaceView()
  let errorBar = SurfaceView(), errorLabel = label("", size: 12)
  let errorClose = ExplorerButton(icon: "close"), exitSearch = ExplorerButton(title: NL("退出搜索"))
  let privacySettings = ExplorerButton(title: NL("前往设置"))
  let emptyIcon = NSImageView()
  private(set) var collectionLayout = ExplorerCollectionLayout()
  let addTabButton = ExplorerButton(icon: "plus")
  let backButton = ExplorerButton(icon: "arrowLeft"), forwardButton = ExplorerButton(icon: "arrowRight"), upButton = ExplorerButton(icon: "arrowUp"), refreshButton = ExplorerButton(icon: "refresh")
  let newButton = ExplorerButton(title: NL("新建"), icon: "plus", dropdown: true)
  let sortButton = ExplorerButton(title: NL("排序"), icon: "sort", dropdown: true), viewButton = ExplorerButton(title: NL("查看"), icon: "list", dropdown: true), moreButton = ExplorerButton(icon: "more"), previewButton = ExplorerButton(title: NL("预览"), icon: "panelRight")
  let detailViewButton = ExplorerButton(icon: "list"), iconViewButton = ExplorerButton(icon: "grid")
  let sizeLabel = label(NL("图标大小"), size: 11), sizeValue = label("64", size: 11)
  let sizeSlider = NSSlider(value: 64, minValue: 32, maxValue: 128, target: nil, action: nil)
  private var commands: [String: ExplorerButton] = [:]
  private let commandTools = SurfaceView(), commandToolsScroll = NSScrollView()
  private let firstDivider = SurfaceView(), secondDivider = SurfaceView()
  private let byteFormatter = ByteCountFormatter(), dateFormatter = DateFormatter()
  private var detailsPreview: QLPreviewView?
  private let paneScroll = NSScrollView(), paneBody = SurfaceView()
  private var paneRequest = UUID()

  init(initial: URL, defaults: UserDefaults) {
    self.defaults = defaults; places = QuickAccessState(defaults: defaults); tabs = [BrowserTab(history: [initial])]
    home = ProcessInfo.processInfo.environment["EXPLORER_NATIVE_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    super.init(nibName: nil, bundle: nil)
    shortcutOverrides = defaults.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
    if let saved = defaults.stringArray(forKey: "toolbar") {
      let allowed = Set(["cut", "copy", "paste", "rename", "share", "trash", "airdrop", "terminal", "undo", "refresh"])
      var seen = Set<String>(); toolbarOrder = saved.filter { allowed.contains($0) && seen.insert($0).inserted }
    }
    showHidden = defaults.bool(forKey: "showHidden")
    compact = defaults.bool(forKey: "compact"); checkboxes = defaults.bool(forKey: "checkboxes")
    extensions = defaults.object(forKey: "extensions") as? Bool ?? true
    paneMode = defaults.string(forKey: "paneMode").flatMap { ["details", "preview"].contains($0) ? $0 : nil } ?? ""
    navigationPane = defaults.object(forKey: "navigationPane") as? Bool ?? true
    savedFolderViews = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    if defaults.object(forKey: "iconMode") != nil { mode = defaults.bool(forKey: "iconMode") ? .icons : .details }
    restoreView(initial, touch: true)
    byteFormatter.countStyle = .file; byteFormatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    dateFormatter.dateFormat = "yyyy/M/d HH:mm"; dateFormatter.locale = NativeLanguage.formatLocale
  }
  required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    let root = ExplorerRootView(frame: NSRect(x: 0, y: 0, width: 1180, height: 780)); view = root
    root.onLayout = { [weak self] in self?.layoutChrome() }
    [tabsBar, navigationBar, commandBar, sidebar, content, pane, errorBar, footer].forEach(root.addSubview)
    tabsBar.color = ExplorerPalette.mica; tabsDocument.color = ExplorerPalette.mica
    navigationBar.color = ExplorerPalette.surface; commandBar.color = ExplorerPalette.toolbar; commandBar.bottomBorder = true
    sidebar.color = ExplorerPalette.sidebar; sidebarDocument.color = ExplorerPalette.sidebar
    pane.color = ExplorerPalette.sidebar; footer.color = ExplorerPalette.sidebar
    sidebar.rightBorder = true; pane.leftBorder = true; footer.topBorder = true
    status.font = .systemFont(ofSize: 11, weight: .regular)
    for scroll in [tabsScroll, sidebarScroll, tableScroll, collectionScroll] { scroll.automaticallyAdjustsContentInsets = false }
    tabsScroll.drawsBackground = false; tabsScroll.hasHorizontalScroller = false; tabsScroll.documentView = tabsDocument
    tabsBar.addSubview(tabsScroll); tabsBar.addSubview(addTabButton)
    addTabButton.onPress = { [weak self] in self?.newTab() }; addTabButton.toolTip = NL("新建标签页 ⌘T")
    for item in [backButton, forwardButton, upButton, refreshButton] { navigationBar.addSubview(item) }
    navigationBar.addSubview(addressBar); navigationBar.addSubview(searchBox)
    backButton.onPress = { [weak self] in self?.back() }; forwardButton.onPress = { [weak self] in self?.forward() }
    upButton.onPress = { [weak self] in self?.up() }; refreshButton.onPress = { [weak self] in IconLoader.shared.clear(); self?.reload() }
    for (control, tip) in [(backButton, NL("后退 ⌘[")), (forwardButton, NL("前进 ⌘]")), (upButton, NL("向上一级 ⌘↑")), (refreshButton, NL("刷新 ⌘R"))] { control.toolTip = tip }
    addressBar.recentPaths = defaults.stringArray(forKey: "typedPaths") ?? []
    addressBar.onNavigate = { [weak self] in self?.navigate(to: $0) }; addressBar.onSubmit = { [weak self] in self?.goAddress($0) }
    addressBar.labelForPath = { [weak self] in self?.locationLabel($0) ?? $0.lastPathComponent }
    addressBar.onCopyAddress = { [weak self] value in self?.filePasteboard.clearContents(); self?.filePasteboard.setString(value, forType: .string) }
    addressBar.onError = { [weak self] error in self?.lastError = self?.errorMessage(error); self?.render() }
    search.delegate = self; searchBox.onSearch = { [weak self] in self?.performSearch() }; searchBox.onClear = { [weak self] in self?.searchActive = false; self?.reload() }
    buildCommands(); buildFileViews()
    content.addSubview(specialView); specialView.isHidden = true
    specialView.onNavigate = { [weak self] in self?.navigate(to: $0) }
    specialView.onVolumesChanged = { [weak self] in self?.rebuildSidebar() }
    sidebarScroll.drawsBackground = false; sidebarScroll.hasVerticalScroller = true; sidebarScroll.autohidesScrollers = true; sidebarScroll.documentView = sidebarDocument; sidebar.addSubview(sidebarScroll)
    errorBar.color = ExplorerPalette.errorSurface; errorBar.addSubview(errorLabel); errorBar.addSubview(errorClose); errorBar.addSubview(exitSearch); errorBar.addSubview(privacySettings)
    errorClose.onPress = { [weak self] in self?.lastError = nil; self?.operationError = nil; self?.needsFullDiskAccess = false; self?.render() }
    privacySettings.toolTip = NL("打开系统设置中的完全磁盘访问权限")
    privacySettings.onPress = { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) } }
    exitSearch.onPress = { [weak self] in self?.search.stringValue = ""; self?.searchActive = false; self?.reload() }
    [status, sizeLabel, sizeSlider, sizeValue, detailViewButton, iconViewButton].forEach(footer.addSubview)
    sizeSlider.isContinuous = true; sizeSlider.target = self; sizeSlider.action = #selector(resizeIcons)
    sizeSlider.setAccessibilityLabel(NL("图标大小"))
    detailViewButton.onPress = { [weak self] in self?.setView(.details) }; detailViewButton.toolTip = NL("详细信息视图")
    iconViewButton.onPress = { [weak self] in self?.setView(.icons, size: 64) }; iconViewButton.toolTip = NL("大图标视图")
    emptyIcon.imageScaling = .scaleProportionallyUpOrDown; content.addSubview(emptyIcon); content.addSubview(emptyLabel)
    spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false; content.addSubview(spinner)
    content.addSubview(loadingView); loadingView.setAccessibilityLabel(NL("正在读取文件"))
    emptyLabel.alignment = .center
    settingsObserver = NotificationCenter.default.addObserver(forName: Self.placesChanged, object: defaults, queue: .main) { [weak self] _ in
      guard let self, !self.stopped else { return }; self.places = QuickAccessState(defaults: self.defaults); self.rebuildSidebar(); self.refreshVCS(force: true)
    }
    preferenceSnapshot = preferences()
    preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in self?.schedulePreferences() }
    placeMarker.color = ExplorerPalette.accent; placeMarker.isHidden = true
    rebuildTabs(); rebuildSidebar(); layoutChrome(); updateMode(persist: false)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in guard let self else { return event }; return self.handleKey(event) }
    vcsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      guard let self, self.vcsStatus != nil, self.view.window?.isKeyWindow == true, !self.automaticRefreshBlocked else { return }; self.refreshVCS()
    }
    focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
      guard let self, note.object as? NSWindow === self.view.window, !self.automaticRefreshBlocked else { return }; self.refreshVCS(force: true)
    }
    paletteObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.view.needsLayout = true }
  }
  override func viewDidAppear() {
    super.viewDidAppear()
    if inputNavigation == nil {
      inputNavigation = NativeInputNavigation.bind(to: content, blocked: { [weak self] in
        guard let self else { return true }; return self.busy || self.loading || self.renamingEntry != nil || self.addressBar.editing || self.view.window?.firstResponder is NSTextView || self.view.window.map { ExplorerDialogs.isPresenting(in: $0) || $0.attachedSheet != nil } == true
      }, context: { [weak self] in self?.directory.absoluteString ?? "" }, navigate: { [weak self] direction in if direction < 0 { self?.back() } else { self?.forward() } })
    }
    if snapshot == nil && !loading { reload() }
  }
  private func preferences() -> NSDictionary {
    var result: [String: Any] = [:]
    for key in ["theme", "toolbar", "shortcuts", "showHidden", "compact", "checkboxes", "extensions", "navigationPane", "folderViews", "defaultFolderView", "versionControl", "typedPaths", "paneMode"] { if let value = defaults.object(forKey: key) { result[key] = value } }
    return result as NSDictionary
  }
  private func schedulePreferences() {
    preferencesWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped else { return }
      if self.automaticRefreshBlocked || self.view.window?.firstResponder is NSTextView { self.schedulePreferences(); return }
      let current = self.preferences(); guard current != self.preferenceSnapshot else { return }
      let folderChanged = !NSDictionary(dictionary: self.preferenceSnapshot["folderViews"] as? [String: Any] ?? [:]).isEqual(to: current["folderViews"] as? [String: Any] ?? [:]) || !NSDictionary(dictionary: self.preferenceSnapshot["defaultFolderView"] as? [String: Any] ?? [:]).isEqual(to: current["defaultFolderView"] as? [String: Any] ?? [:])
      self.preferenceSnapshot = current
      self.shortcutOverrides = self.defaults.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
      if let saved = self.defaults.stringArray(forKey: "toolbar") { var seen = Set<String>(); self.toolbarOrder = saved.filter { self.commands[$0] != nil && seen.insert($0).inserted } }
      self.showHidden = self.defaults.bool(forKey: "showHidden"); self.compact = self.defaults.bool(forKey: "compact"); self.checkboxes = self.defaults.bool(forKey: "checkboxes")
      self.extensions = self.defaults.object(forKey: "extensions") as? Bool ?? true; self.navigationPane = self.defaults.object(forKey: "navigationPane") as? Bool ?? true
      self.paneMode = self.defaults.string(forKey: "paneMode").flatMap { ["details", "preview"].contains($0) ? $0 : nil } ?? ""
      self.addressBar.showHidden = self.showHidden; self.addressBar.recentPaths = self.defaults.stringArray(forKey: "typedPaths") ?? []
      if folderChanged { self.restoreView(self.directory) }
      self.collectionLayout.mode = self.mode; self.collectionLayout.iconSize = self.iconSize; self.collectionLayout.compact = self.compact; self.collectionLayout.invalidateLayout(); self.table.rowHeight = self.compact ? 28 : 36
      self.syncMenuShortcuts(); self.rebuildSidebar(); self.view.needsLayout = true; self.recompute(); self.render(); self.refreshVCS(force: true)
    }
    preferencesWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private func buildCommands() {
    commandTools.color = ExplorerPalette.toolbar; commandToolsScroll.documentView = commandTools; commandToolsScroll.drawsBackground = false; commandToolsScroll.hasHorizontalScroller = true; commandToolsScroll.autohidesScrollers = true; commandToolsScroll.automaticallyAdjustsContentInsets = false; commandBar.addSubview(commandToolsScroll)
    [newButton, firstDivider, sortButton, viewButton, moreButton, secondDivider, previewButton].forEach(commandBar.addSubview)
    newButton.iconColor = ExplorerPalette.commandAccent
    newButton.onPress = { [weak self] in guard let self else { return }; ExplorerMenu.present(self.newMenu(), below: self.newButton) }
    let definitions: [(String, String, String, () -> Void)] = [
      ("cut", "scissors", NL("剪切 ⌘X"), { [weak self] in self?.copySelection(cut: true) }),
      ("copy", "copy", NL("复制 ⌘C"), { [weak self] in self?.copySelection(cut: false) }),
      ("paste", "paste", NL("粘贴 ⌘V"), { [weak self] in self?.pasteFiles() }),
      ("rename", "rename", NL("重命名 F2"), { [weak self] in self?.renameSelected() }),
      ("share", "share", NL("共享"), { [weak self] in self?.shareSelected() }),
      ("trash", "trash", NL("移到回收站 ⌘⌫"), { [weak self] in self?.trashSelected() }),
      ("airdrop", "airdrop", NL("隔空投送"), { [weak self] in self?.sendAirDrop() }),
      ("terminal", "terminal", NL("在终端中打开"), { [weak self] in self?.openTerminal() }),
      ("undo", "undo", NL("撤销"), { [weak self] in self?.undoFiles() }),
      ("refresh", "refresh", NL("刷新"), { [weak self] in self?.executeAction("refresh") }),
    ]
    for (key, icon, tip, action) in definitions {
      let control = ExplorerButton(icon: icon, action: action); control.toolTip = tip; commands[key] = control; commandTools.addSubview(control)
      if ["cut", "copy", "rename"].contains(key) { control.iconColor = ExplorerPalette.commandAccent }
    }
    firstDivider.color = ExplorerPalette.border; secondDivider.color = ExplorerPalette.border
    sortButton.onPress = { [weak self] in guard let self else { return }; ExplorerMenu.present(self.sortMenu(), below: self.sortButton) }
    viewButton.onPress = { [weak self] in guard let self else { return }; ExplorerMenu.present(self.viewMenu(), below: self.viewButton) }
    moreButton.onPress = { [weak self] in guard let self else { return }; ExplorerMenu.present(self.moreMenu(), below: self.moreButton) }
    previewButton.onPress = { [weak self] in self?.togglePane("preview") }
  }
  private func buildFileViews() {
    table.style = .plain
    table.dataSource = self; table.delegate = self; table.rowHeight = compact ? 28 : 36; table.intercellSpacing = .zero
    table.allowsMultipleSelection = true; table.backgroundColor = ExplorerPalette.surface
    table.columnAutoresizingStyle = .noColumnAutoresizing; table.target = self; table.doubleAction = #selector(openSelected)
    table.setAccessibilityLabel(NL("文件列表"))
    let header = ExplorerTableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 41))
    header.onMenu = { [weak self] event in
      guard let self, let window = self.view.window else { return }
      ExplorerMenu.show(self.columnMenu(), at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
    }
    table.headerView = header; table.allowsColumnReordering = true; table.allowsColumnResizing = true
    for (id, title, width) in [("name", NL("名称"), 450.0), ("modified", NL("修改日期"), 165.0), ("created", NL("创建日期"), 165.0), ("kind", NL("类型"), 132.0), ("size", NL("大小"), 100.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.headerCell = ExplorerHeaderCell(textCell: title)
      column.width = width; column.minWidth = DetailColumns.minimumWidth(id); column.maxWidth = 2000; column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true); table.addTableColumn(column)
    }
    tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true; tableScroll.autohidesScrollers = true; tableScroll.backgroundColor = ExplorerPalette.surface; content.addSubview(tableScroll)
    collection.collectionViewLayout = collectionLayout; collection.isSelectable = true; collection.allowsMultipleSelection = true
    collection.backgroundColors = [ExplorerPalette.surface]; collection.dataSource = self; collection.delegate = self
    collection.register(IconItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("file")); collection.setAccessibilityLabel(NL("文件图标"))
    collectionScroll.documentView = collection; collectionScroll.hasVerticalScroller = true; collectionScroll.hasHorizontalScroller = true; collectionScroll.autohidesScrollers = true; content.addSubview(collectionScroll)
    table.registerForDraggedTypes([.fileURL]); collection.registerForDraggedTypes([.fileURL])
    table.setDraggingSourceOperationMask([.copy, .move], forLocal: true); table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
    collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true); collection.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
    table.openSelection = { [weak self] in self?.openSelected() }; collection.openSelection = table.openSelection
    table.previewSelection = { [weak self] in self?.previewSelected() }; collection.previewSelection = table.previewSelection
    table.renameSelection = { [weak self] in self?.renameSelected() }; collection.renameSelection = table.renameSelection
    table.trashSelection = { [weak self] in self?.trashSelected() }; collection.trashSelection = table.trashSelection
    table.showContext = { [weak self] in self?.showContext($0) }; collection.showContext = table.showContext
  }

  func layoutChrome() {
    let width = view.bounds.width, height = view.bounds.height
    let sidebarWidth: CGFloat = navigationPane ? (width <= 900 ? 175 : width <= 1100 ? 185 : 208) : 0
    let paneWidth: CGFloat = paneMode.isEmpty ? 0 : (width <= 900 ? 242 : 276)
    tabsBar.frame = NSRect(x: 0, y: 0, width: width, height: 48)
    navigationBar.frame = NSRect(x: 0, y: 48, width: width, height: 61)
    commandBar.frame = NSRect(x: 0, y: 109, width: width, height: 57)
    footer.frame = NSRect(x: 0, y: height - 30, width: width, height: 30)
    let bodyHeight = max(0, height - 196), errorHeight: CGFloat = lastError == nil && !searchActive ? 0 : 35
    sidebar.frame = NSRect(x: 0, y: 166, width: sidebarWidth, height: bodyHeight); sidebar.isHidden = !navigationPane; sidebarScroll.frame = sidebar.bounds
    sidebarDocument.frame.size.width = sidebarWidth; layoutSidebarRows()
    content.frame = NSRect(x: sidebarWidth, y: 166 + errorHeight, width: max(0, width - sidebarWidth - paneWidth), height: bodyHeight - errorHeight)
    errorBar.frame = NSRect(x: sidebarWidth, y: 166, width: width - sidebarWidth - paneWidth, height: errorHeight); errorBar.isHidden = errorHeight == 0
    errorLabel.frame = NSRect(x: 16, y: 9, width: max(0, errorBar.bounds.width - (privacySettings.isHidden ? 110 : 150)), height: 18)
    errorClose.frame = NSRect(x: errorBar.bounds.width - 35, y: 4, width: 27, height: 27)
    privacySettings.frame = NSRect(x: errorBar.bounds.width - 128, y: 4, width: 88, height: 27)
    exitSearch.frame = NSRect(x: errorBar.bounds.width - 91, y: 4, width: 80, height: 27)
    pane.frame = NSRect(x: width - paneWidth, y: 166, width: paneWidth, height: bodyHeight); pane.isHidden = paneMode.isEmpty
    let tabsWidth = min(CGFloat(tabs.count) * 218, width - 210)
    tabsScroll.frame = NSRect(x: 94, y: 12, width: max(0, tabsWidth), height: 36)
    tabsDocument.frame.size = NSSize(width: CGFloat(tabs.count) * 218, height: 36)
    addTabButton.frame = NSRect(x: 94 + tabsWidth + 8, y: 15, width: 32, height: 30)
    let navGap: CGFloat = width <= 900 ? 8 : 14, left: CGFloat = width <= 900 ? 10 : 14
    let historyGap: CGFloat = width <= 900 ? 3 : 9
    var x = left
    for control in [backButton, forwardButton, upButton, refreshButton] { control.frame = NSRect(x: x, y: 13, width: 30, height: 34); x += 30 + historyGap }
    x += navGap - historyGap
    let searchWidth: CGFloat = width <= 900 ? 182 : width <= 1100 ? 200 : 245
    searchBox.frame = NSRect(x: width - 18 - searchWidth, y: 13, width: searchWidth, height: 35)
    addressBar.frame = NSRect(x: x, y: 13, width: max(100, searchBox.frame.minX - navGap - x), height: 35)
    let gap: CGFloat = width <= 900 ? 4 : width <= 1100 ? 6 : 10
    x = width <= 900 ? 12 : 17
    newButton.frame = NSRect(x: x, y: 11, width: 90, height: 34); x += 90 + gap
    for (key, button) in commands { button.isHidden = !toolbarOrder.contains(key) }
    firstDivider.isHidden = toolbarOrder.isEmpty; secondDivider.isHidden = toolbarOrder.isEmpty; commandToolsScroll.isHidden = toolbarOrder.isEmpty
    if !toolbarOrder.isEmpty {
      firstDivider.frame = NSRect(x: x, y: 18, width: 1, height: 20); x += 1 + gap
      let fullWidth = CGFloat(toolbarOrder.count * 45 - 10)
      let groupWidth = min(fullWidth, max(35, width - x - (2 * gap + 1 + 90 + gap + 90 + gap + 35 + gap + (width <= 900 ? 35 : 73) + 17)))
      commandToolsScroll.frame = NSRect(x: x, y: 11, width: groupWidth, height: 34); commandTools.frame = NSRect(x: 0, y: 0, width: fullWidth, height: 34)
      for (index, key) in toolbarOrder.enumerated() { commands[key]?.frame = NSRect(x: CGFloat(index) * 45, y: 0, width: 35, height: 34) }
      x += groupWidth + gap; secondDivider.frame = NSRect(x: x, y: 18, width: 1, height: 20); x += 1 + gap
    }
    sortButton.frame = NSRect(x: x, y: 11, width: 90, height: 34); x += 90 + gap
    viewButton.frame = NSRect(x: x, y: 11, width: 90, height: 34); x += 90 + gap
    moreButton.frame = NSRect(x: x, y: 11, width: 35, height: 34)
    previewButton.frame = NSRect(x: width - (width <= 900 ? 47 : 90), y: 11, width: width <= 900 ? 35 : 73, height: 34)
    previewButton.title = width <= 900 ? "" : NL("预览")
    specialView.frame = content.bounds; loadingView.frame = content.bounds
    tableScroll.frame = NSRect(x: 14, y: 0, width: max(0, content.bounds.width - 38), height: content.bounds.height)
    collectionScroll.frame = content.bounds
    collectionLayout.invalidateLayout(); collectionLayout.prepare()
    collection.frame.size = collectionLayout.collectionViewContentSize
    let available = max(0, tableScroll.contentView.bounds.width)
    let dateWidth: CGFloat = width <= 900 ? 150 : width <= 1100 ? 153 : 165
    let metadata: [String: CGFloat] = ["modified": dateWidth, "created": dateWidth, "kind": width <= 1100 ? 110 : 132, "size": width <= 900 ? 80 : width <= 1100 ? 85 : 100]
    var hidden = Set<String>()
    if width <= 900 { hidden.insert("kind") }
    if paneWidth > 0 && width <= 1100 { hidden.formUnion(["kind", "size"]) }
    if paneWidth > 0 && width <= 900 { hidden.insert("modified") }
    let existingWidth = metadata.filter { $0.key != "created" && !hidden.contains($0.key) }.values.reduce(0, +)
    // Keep the established columns and a readable filename before adding a second date.
    if hidden.contains("modified") || available - existingWidth - dateWidth < 250 { hidden.insert("created") }
    let used = metadata.filter { !hidden.contains($0.key) }.values.reduce(0, +)
    syncingColumns = true
    for (index, id) in detailColumns.order.enumerated() {
      if let old = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }), old != index { table.moveColumn(old, toColumn: index) }
    }
    for column in table.tableColumns {
      let id = column.identifier.rawValue
      column.isHidden = detailColumns.automatic ? hidden.contains(id) : !detailColumns.visible.contains(id)
      column.width = detailColumns.automatic ? (id == "name" ? max(150, available - used) : metadata[id] ?? 100) : detailColumns.widths[id] ?? 100
    }
    syncingColumns = false
    emptyIcon.frame = NSRect(x: (content.bounds.width - 68) / 2, y: max(40, content.bounds.height * 0.35 - 60), width: 68, height: 68)
    emptyLabel.frame = NSRect(x: 20, y: emptyIcon.frame.maxY + 18, width: content.bounds.width - 40, height: 24)
    spinner.frame = NSRect(x: (content.bounds.width - 16) / 2, y: emptyIcon.frame.minY, width: 16, height: 16)
    status.frame = NSRect(x: 22, y: 7, width: max(100, width - 360), height: 17)
    iconViewButton.frame = NSRect(x: width - 36, y: 1, width: 30, height: 28); detailViewButton.frame = NSRect(x: width - 68, y: 1, width: 30, height: 28)
    sizeValue.frame = NSRect(x: width - 100, y: 7, width: 27, height: 17); sizeSlider.frame = NSRect(x: width - 210, y: 6, width: 100, height: 18); sizeLabel.frame = NSRect(x: width - 267, y: 7, width: 52, height: 17)
    for item in [sizeValue, sizeSlider, sizeLabel] { item.isHidden = mode != .icons }
    layoutPane()
  }

  func rebuildTabs() {
    tabsDocument.subviews.forEach { $0.removeFromSuperview() }
    for (index, tab) in tabs.enumerated() {
      let id = tab.id
      let item = ExplorerTabView(title: locationLabel(tab.directory), active: index == activeTab, onSelect: { [weak self] in guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }; self.switchTab(to: index) }, onClose: { [weak self] in guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }; self.closeTab(at: index) })
      item.onDragValidate = { [weak self] info in self?.dropOperation(info, target: tab.directory) ?? [] }
      item.onDrop = { [weak self] info in self?.acceptFiles(info, at: tab.directory, fromTab: true) ?? false }
      item.canDetach = { [weak self] in self?.canDetachTab == true }
      item.onDetach = { [weak self] point in self?.detachTab(id: id, at: point) ?? false }
      if tab.directory.deletingLastPathComponent().path == home.path || tab.directory.path == "/Applications" { item.badgeName = ["Applications": "applications", "Desktop": "desktop", "Documents": "document", "Downloads": "download", "Pictures": "image", "Music": "music", "Movies": "video"][tab.directory.lastPathComponent] }
      if tab.directory.scheme == "explorer" { item.locationIcon = tab.directory.host == "computer" ? "computer" : tab.directory.host }
      if tab.directory == home.appendingPathComponent(".Trash") { item.locationIcon = "trash" }
      item.frame = NSRect(x: CGFloat(index) * 218, y: 0, width: 214, height: 36); tabsDocument.addSubview(item)
    }
    view.needsLayout = true
  }
  func locationLabel(_ url: URL) -> String {
    if url.scheme == "explorer" { return ["computer": NL("此电脑"), "airdrop": NL("隔空投送"), "network": NL("网络"), "trash": NL("回收站")][url.host ?? ""] ?? NL("此电脑") }
    if url == cloudDrive { return "iCloud Drive" }
    if let name = places.importedNames[url.path] { return name }
    if url.path == "/" { return "Macintosh HD" }; if url.path == home.path { return NL("个人文件夹") }
    if url == home.appendingPathComponent(".Trash") { return NL("回收站") }
    let localized = ["Applications": NL("应用程序"), "Desktop": NL("桌面"), "Downloads": NL("下载"), "Documents": NL("文档"), "Pictures": NL("图片"), "Music": NL("音乐"), "Movies": NL("视频")]
    if url.deletingLastPathComponent().path == home.path || url.path == "/Applications" { return localized[url.lastPathComponent] ?? url.lastPathComponent }
    return url.lastPathComponent
  }
  private var defaultPlaces: [(URL, String)] {
    [("Applications", "applications"), ("Desktop", "desktop"), ("Downloads", "download"), ("Documents", "document"), ("Pictures", "image"), ("Music", "music"), ("Movies", "video")].compactMap { name, icon in
      let url = name == "Applications" && home == FileManager.default.homeDirectoryForCurrentUser ? URL(fileURLWithPath: "/Applications") : home.appendingPathComponent(name)
      return FileManager.default.fileExists(atPath: url.path) ? (url, icon) : nil
    }
  }
  var pinnedPaths: [String] { places.visible(defaultPaths: defaultPlaces.map { $0.0.path }).filter { $0 != cloudDrive?.path } }
  private func savePlaces() { places.save(to: defaults); NotificationCenter.default.post(name: Self.placesChanged, object: defaults) }
  func togglePin(_ url: URL) {
    guard url.isFileURL, url != cloudDrive else { return }
    places.toggle(url.standardizedFileURL.path, defaultPaths: defaultPlaces.map { $0.0.path }); savePlaces()
  }
  @discardableResult
  func reorderPin(_ path: String, at index: Int) -> Bool {
    guard pinnedPaths.contains(path) else { return false }
    places.insert([path], at: index, defaultPaths: defaultPlaces.map { $0.0.path }); savePlaces(); return true
  }
  @discardableResult
  func pinFolders(_ urls: [URL], at index: Int) async -> Bool {
    guard !urls.isEmpty, urls.count <= 10_000 else { return false }
    let trash = home.appendingPathComponent(".Trash").standardizedFileURL.path, cloud = cloudDrive?.resolvingSymlinksInPath().path
    let valid = await Task.detached(priority: .userInitiated) {
      urls.allSatisfy { url in
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"), url.host == nil || url.host == "" || url.host == "localhost" else { return false }
        let path = url.standardizedFileURL.path, resolved = url.resolvingSymlinksInPath()
        guard resolved.path != cloud, path != trash, !path.hasPrefix(trash + "/"), !resolved.pathComponents.contains(".Trash"), !resolved.pathComponents.contains(".Trashes"),
          let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true, values.isPackage != true else { return false }
        return true
      }
    }.value
    guard valid, !stopped else { return false }
    places.insert(urls.map { $0.standardizedFileURL.path }, at: index, defaultPaths: defaultPlaces.map { $0.0.path }); savePlaces(); return true
  }
  private func pinTarget() -> URL? {
    if selectedPaths.isEmpty { return writable && directory != cloudDrive ? directory : nil }
    let chosen = selectedEntries()
    return chosen.count == 1 && chosen[0].isDirectory && !chosen[0].isPackage && !viewingTrash && chosen[0].url != cloudDrive ? chosen[0].url : nil
  }
  private func rebuildSidebar() {
    let scroll = sidebarScroll.contentView.bounds.origin
    sidebarDocument.subviews.forEach { $0.removeFromSuperview() }; sidebarRows = []; placeRows = []
    var y: CGFloat = 10
    func divider() { let line = SurfaceView(frame: NSRect(x: 20, y: y + 10, width: max(0, sidebar.bounds.width - 40), height: 1)); line.color = ExplorerPalette.border; line.identifier = NSUserInterfaceItemIdentifier("divider"); sidebarDocument.addSubview(line); y += 21 }
    func row(_ title: String, _ url: URL, _ icon: String, level: Int = 0, pinned: Bool = false) {
      let item = ExplorerSidebarRow(title: title, icon: icon, level: level, pinned: pinned, onOpen: { [weak self] in self?.navigate(to: url) })
      item.selected = directory == url; item.expanded = expanded.contains(url.path)
      if url.isFileURL { item.onExpand = { [weak self] in self?.toggleFolder(url) } }
      item.onOpenTab = { [weak self] in self?.openTab(at: url) }
      item.onContext = { [weak self] event in self?.sidebarMenu(url, event: event) }
      item.placePath = pinned ? url.path : nil
      item.onDragUpdate = { [weak self, weak item] info, localY in self?.sidebarDrag(info, target: url, row: item, y: localY, pinned: pinned) ?? [] }
      item.onDrop = { [weak self, weak item] info, localY in self?.sidebarDrop(info, target: url, row: item, y: localY, pinned: pinned) ?? false }
      item.onDragExit = { [weak self] in self?.placeMarker.isHidden = true }
      item.tint = ExplorerPalette.place(icon); item.frame = NSRect(x: 8, y: y, width: max(0, sidebar.bounds.width - 16), height: 36); y += 36
      item.toolTip = url.path; sidebarDocument.addSubview(item); sidebarRows.append((url, item))
      if expanded.contains(url.path) {
        if let error = folderErrors[url.path] {
          let note = label(NL("无法访问"), size: 11, color: ExplorerPalette.secondary); note.toolTip = error
          note.frame = NSRect(x: 32 + CGFloat(min(level, 6)) * 12, y: y, width: max(0, sidebar.bounds.width - 44), height: 24); sidebarDocument.addSubview(note); y += 24
        } else if let children = folderChildren[url.path] {
          if children.isEmpty {
            let note = label(NL("没有子文件夹"), size: 11, color: ExplorerPalette.secondary)
            note.frame = NSRect(x: 32 + CGFloat(min(level, 6)) * 12, y: y, width: max(0, sidebar.bounds.width - 44), height: 24); sidebarDocument.addSubview(note); y += 24
          }
          for child in children { row(child.name, child.url, "folder", level: min(level + 1, 6)) }
        }
      }
      if pinned { placeRows.append((url, item, y)) }
    }
    row(NL("个人文件夹"), home, "folder"); divider()
    let icons = Dictionary(uniqueKeysWithValues: defaultPlaces.map { ($0.0.path, $0.1) })
    for path in pinnedPaths { let url = URL(fileURLWithPath: path); row(locationLabel(url), url, icons[path] ?? "folder", pinned: true) }
    divider()
    row(NL("此电脑"), URL(string: "explorer://computer")!, "computer")
    sidebarRows.last?.1.expanded = true; sidebarRows.last?.1.onExpand = nil
    row((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD", URL(fileURLWithPath: "/"), "drive", level: 1)
    for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] where volume.path.hasPrefix("/Volumes/") { row(volume.lastPathComponent, volume, "drive", level: 1) }
    if let cloudDrive { row("iCloud Drive", cloudDrive, "cloud") }
    row(NL("回收站"), URL(string: "explorer://trash")!, "trash")
    for (title, icon) in [(NL("隔空投送"), "airdrop"), (NL("网络"), "network")] { row(title, URL(string: "explorer://\(icon)")!, icon) }
    sidebarDocument.frame.size = NSSize(width: sidebar.bounds.width, height: y + 8)
    placeMarker.identifier = NSUserInterfaceItemIdentifier("marker"); placeMarker.isHidden = true; sidebarDocument.addSubview(placeMarker)
    sidebarScroll.contentView.scroll(to: NSPoint(x: 0, y: min(scroll.y, max(0, y + 8 - sidebarScroll.contentSize.height)))); sidebarScroll.reflectScrolledClipView(sidebarScroll.contentView)
  }
  private func sidebarMenu(_ url: URL, event: NSEvent) {
    guard let window = view.window else { return }
    var items = [ExplorerMenuItem(title: NL("在新标签页中打开"), icon: "plus", action: { [weak self] in self?.openTab(at: url) })]
    if url.isFileURL {
      items.append(ExplorerMenuItem(title: NL("在此处打开终端"), icon: "terminal", action: { [weak self] in self?.openTerminal(at: url) }))
      if url != cloudDrive && !url.pathComponents.contains(".Trash") && !url.pathComponents.contains(".Trashes") {
        items.append(ExplorerMenuItem(title: pinnedPaths.contains(url.path) ? NL("从快速访问取消固定") : NL("固定到快速访问"), icon: "pin", action: { [weak self] in self?.togglePin(url) }))
      }
    }
    if url.path.hasPrefix("/Volumes/"), (try? url.resourceValues(forKeys: [.volumeIsEjectableKey]).volumeIsEjectable) == true {
      items.append(ExplorerMenuItem(title: NL("推出"), icon: "eject", enabled: !busy, divider: true, action: { [weak self] in self?.ejectVolume(url) }))
    }
    ExplorerMenu.show(items, at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
  }
  private func sidebarInsertion(_ info: NSDraggingInfo, target: URL, y: CGFloat, pinned: Bool) -> Int? {
    guard pinned, let index = pinnedPaths.firstIndex(of: target.path) else { return nil }
    if info.draggingPasteboard.availableType(from: [ExplorerSidebarRow.placeType]) != nil { return index + (y >= 18 ? 1 : 0) }
    guard y < 9 || y >= 27 else { return nil }
    let board = info.draggingPasteboard
    if dragValidation?.0 != info.draggingSequenceNumber || dragValidation?.1 != board.changeCount {
      let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      let folders = !urls.isEmpty && urls.count <= 10_000 && urls.allSatisfy { url in
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
      }
      dragValidation = (info.draggingSequenceNumber, board.changeCount, folders)
    }
    return dragValidation?.2 == true ? index + (y >= 27 ? 1 : 0) : nil
  }
  private func sidebarDrag(_ info: NSDraggingInfo, target: URL, row: ExplorerSidebarRow?, y: CGFloat, pinned: Bool) -> NSDragOperation {
    placeMarker.isHidden = true
    guard !busy, let row else { return [] }
    if target.absoluteString == "explorer://airdrop", info.draggingPasteboard.availableType(from: [ExplorerSidebarRow.placeType]) == nil, info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
    if let index = sidebarInsertion(info, target: target, y: y, pinned: pinned), let place = placeRows.first(where: { $0.0.path == target.path }) {
      let after = index > (pinnedPaths.firstIndex(of: target.path) ?? 0)
      placeMarker.frame = NSRect(x: 16, y: (after ? place.2 : row.frame.minY) - 1, width: max(0, sidebar.bounds.width - 32), height: 2); placeMarker.isHidden = false
      return info.draggingPasteboard.availableType(from: [ExplorerSidebarRow.placeType]) != nil ? .move : .copy
    }
    guard info.draggingPasteboard.availableType(from: [ExplorerSidebarRow.placeType]) == nil, target.isFileURL, !target.pathComponents.contains(".Trash"), !target.pathComponents.contains(".Trashes"),
      info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
    return NSEvent.modifierFlags.contains(.option) || !info.draggingSourceOperationMask.contains(.move) ? .copy : .move
  }
  private func sidebarDrop(_ info: NSDraggingInfo, target: URL, row: ExplorerSidebarRow?, y: CGFloat, pinned: Bool) -> Bool {
    let operation = sidebarDrag(info, target: target, row: row, y: y, pinned: pinned)
    defer { placeMarker.isHidden = true; dragValidation = nil }
    guard !operation.isEmpty else { return false }
    if let index = sidebarInsertion(info, target: target, y: y, pinned: pinned) {
      if let path = info.draggingPasteboard.string(forType: ExplorerSidebarRow.placeType) { return reorderPin(path, at: index) }
      let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      Task { @MainActor [weak self] in _ = await self?.pinFolders(urls, at: index) }; return !urls.isEmpty
    }
    let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard !urls.isEmpty else { return false }
    if target.absoluteString == "explorer://airdrop" {
      guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { operationError = NL("隔空投送不可用"); render(); return false }
      service.perform(withItems: urls); return true
    }
    runTransferOperation { control in FileActions.transfer(urls, to: target, move: operation == .move, control: control) }; return true
  }
  private func layoutSidebarRows() { for item in sidebarDocument.subviews { item.frame.size.width = max(0, sidebar.bounds.width - (item.identifier?.rawValue == "divider" ? 40 : 16)) } }
  private func toggleFolder(_ url: URL) {
    if expanded.contains(url.path) { expanded.remove(url.path); rebuildSidebar(); return }
    expanded.insert(url.path); readFolderChildren(url)
  }
  private func readFolderChildren(_ url: URL) {
    folderChildren[url.path] = nil; folderErrors[url.path] = nil; rebuildSidebar()
    let hidden = showHidden
    Task { @MainActor [weak self] in
      do {
        let children = try await Task.detached { EntryQuery.apply(try DirectoryReader.read(url).entries, showHidden: hidden, query: "", sort: .name, ascending: true).filter { $0.isDirectory && !$0.isPackage && !$0.isSymbolicLink } }.value
        guard let self, self.showHidden == hidden else { return }; self.folderChildren[url.path] = children; self.rebuildSidebar()
      } catch {
        guard let self, self.showHidden == hidden else { return }; self.folderErrors[url.path] = error.localizedDescription; self.rebuildSidebar()
      }
    }
  }

  private func sameLocation(_ left: URL, _ right: URL) -> Bool {
    left.isFileURL && right.isFileURL ? left.standardizedFileURL.path == right.standardizedFileURL.path : left == right
  }
  private var locationLayout: String { "\(mode.rawValue):\(Int(iconSize)):\(compact)" }
  private func itemFrame(_ index: Int) -> NSRect? {
    guard entries.indices.contains(index) else { return nil }
    return mode == .details ? table.rect(ofRow: index) : collectionLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
  }
  private func rememberLocationState() {
    guard isViewLoaded, !loading, !searchActive, pendingLocationState == nil, lastError == nil, snapshot.map({ sameLocation($0.directory, directory) }) == true else { return }
    let scroll = mode == .details ? tableScroll : collectionScroll
    let origin = scroll.contentView.bounds.origin
    let first: Int?
    if mode == .details {
      let rows = table.rows(in: table.visibleRect)
      first = rows.length > 0 && entries.indices.contains(rows.location) ? rows.location : nil
    } else {
      first = collectionLayout.layoutAttributesForElements(in: collection.visibleRect).first?.indexPath?.item
    }
    var state = BrowserLocationState(selection: selectedPaths, origin: origin, layout: locationLayout)
    if let first, let frame = itemFrame(first) { state.anchor = entries[first].id; state.anchorOffset = NSPoint(x: frame.minX - origin.x, y: frame.minY - origin.y) }
    let current = tabs[activeTab].index
    tabs[activeTab].locationStates[current] = state
    // Transient state belongs to the tab, not global folder preferences or restart persistence.
    if tabs[activeTab].locationStates.count > 128 {
      for key in tabs[activeTab].locationStates.keys.sorted().filter({ $0 != current }).prefix(tabs[activeTab].locationStates.count - 128) { tabs[activeTab].locationStates.removeValue(forKey: key) }
    }
  }
  private func prepareLocationState(_ state: BrowserLocationState) {
    pendingLocationState = state; selectedPaths = state.selection
  }
  private func childLocation(from source: URL, in parent: URL) -> URL? {
    guard source.isFileURL, parent.isFileURL, source != parent else { return nil }
    let prefix = parent.path == "/" ? "/" : parent.path + "/"
    guard source.path.hasPrefix(prefix), let component = source.path.dropFirst(prefix.count).split(separator: "/").first else { return nil }
    return parent.appendingPathComponent(String(component), isDirectory: true)
  }
  private func travelHistory(_ delta: Int) {
    let next = tabs[activeTab].index + delta
    guard tabs[activeTab].history.indices.contains(next) else { return }
    let source = directory; rememberLocationState(); tabs[activeTab].index = next
    var state = tabs[activeTab].locationStates[next] ?? BrowserLocationState()
    if let child = childLocation(from: source, in: directory) { state.selection = [child.path]; state.revealPath = child.path }
    prepareLocationState(state)
    search.stringValue = ""; searchActive = false; restoreView(directory, touch: true); reload()
  }
  private func restoreLocationState() {
    guard let state = pendingLocationState, !loading else { return }
    pendingLocationState = nil
    view.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded()
    let scroll = mode == .details ? tableScroll : collectionScroll
    var point = state.layout == locationLayout ? state.origin : .zero
    if state.layout == locationLayout, let anchor = state.anchor, let index = entries.firstIndex(where: { $0.id == anchor }), let frame = itemFrame(index) {
      point = NSPoint(x: frame.minX - state.anchorOffset.x, y: frame.minY - state.anchorOffset.y)
    }
    if let document = scroll.documentView {
      point.x = min(max(0, point.x), max(0, document.bounds.width - scroll.contentSize.width))
      point.y = min(max(0, point.y), max(0, document.bounds.height - scroll.contentSize.height))
      scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
      if let path = state.revealPath, let index = entries.firstIndex(where: { $0.id == path }), let frame = itemFrame(index), !scroll.contentView.bounds.contains(frame) { document.scrollToVisible(frame) }
    }
  }

  func navigate(to url: URL, addHistory: Bool = true) {
    let target = url.standardizedFileURL
    let source = directory
    if addHistory && !sameLocation(target, source) {
      rememberLocationState()
      var state = BrowserLocationState()
      if let child = childLocation(from: source, in: target) {
        if let previous = tabs[activeTab].history.indices.reversed().first(where: { sameLocation(tabs[activeTab].history[$0], target) && tabs[activeTab].locationStates[$0] != nil }) { state = tabs[activeTab].locationStates[previous]! }
        state.selection = [child.path]; state.revealPath = child.path
      }
      let end = tabs[activeTab].index
      tabs[activeTab].history = Array(tabs[activeTab].history.prefix(end + 1)) + [target]
      tabs[activeTab].locationStates = tabs[activeTab].locationStates.filter { $0.key <= end }
      tabs[activeTab].index = tabs[activeTab].history.count - 1
      prepareLocationState(state)
    }
    operationError = nil; needsFullDiskAccess = false; search.stringValue = ""; searchActive = false; virtualLocation = ""; restoreView(target, touch: true); reload()
  }
  @objc func reload() {
    guard !stopped else { return }
    if pendingLocationState == nil {
      rememberLocationState()
      var state = tabs[activeTab].locationStates[tabs[activeTab].index] ?? BrowserLocationState()
      state.selection = selectedPaths
      prepareLocationState(state)
    }
    automaticRead?.cancel(); automaticRead = nil; refreshWork?.cancel(); refreshWork = nil; refreshPending = false
    directoryWatcher.watch(directory.isFileURL && !searchActive ? directory : nil) { [weak self] in self?.scheduleAutomaticRefresh() }
    cancelInlineRename()
    ExplorerMenu.dismiss(); generation += 1; queryGeneration += 1; loadTask?.cancel(); queryTask?.cancel(); searchTask?.cancel()
    vcsStatus = nil
    let token = generation, target = directory; startedAt = Date(); loading = true; lastError = nil; snapshot = nil; entries = []
    addressBar.homeDirectory = home
    addressBar.setDirectory(target, title: target.isFileURL ? nil : locationLabel(target)); addressBar.showHidden = showHidden; search.placeholderString = NL("在{0}中搜索", locationLabel(target)); search.isEnabled = target.host != "airdrop"; searchBox.update()
    backButton.isEnabled = tabs[activeTab].index > 0; forwardButton.isEnabled = tabs[activeTab].index + 1 < tabs[activeTab].history.count; upButton.isEnabled = target.path != "/"
    rebuildTabs(); for (url, row) in sidebarRows { row.selected = url == target }; render()
    if target.absoluteString == "explorer://trash" || viewingTrash {
      let store = trashStore
      let task = Task.detached(priority: .userInitiated) { try store.list(target.scheme == "explorer" ? nil : target) }; loadTask = task
      Task { @MainActor [weak self] in
        do { let result = try await task.value; guard let self, self.generation == token else { return }; self.snapshot = result; self.recompute() }
        catch { guard let self, self.generation == token else { return }; self.loading = false; self.lastError = error.localizedDescription; self.render() }
      }
      return
    }
    if target.scheme == "explorer" {
      loading = false; upButton.isEnabled = false; snapshot = DirectorySnapshot(directory: target, entries: [], skippedCount: 0, elapsedMilliseconds: 0)
      specialView.show(target.host ?? "computer"); render(); return
    }
    let task = Task.detached(priority: .userInitiated) { try DirectoryReader.read(target) }; loadTask = task
    Task { @MainActor [weak self] in
      do { let result = try await task.value; guard let self, self.generation == token else { return }; self.snapshot = result; self.recompute(); self.refreshVCS() }
      catch { guard let self, self.generation == token else { return }; self.loading = false; self.lastError = self.errorMessage(error); self.render() }
    }
  }
  private func scheduleAutomaticRefresh() {
    guard !stopped, directory.isFileURL, !searchActive else { return }
    refreshPending = true
    guard refreshWork == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }; self.refreshWork = nil; self.refreshAutomatically()
    }
    refreshWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
  }
  private var automaticRefreshBlocked: Bool {
    busy || loading || renamingEntry != nil || addressBar.editing || NSEvent.pressedMouseButtons != 0 || view.window.map { ExplorerDialogs.isPresenting(in: $0) || $0.attachedSheet != nil } == true
  }
  private func refreshAutomatically() {
    guard !stopped, refreshPending, directory.isFileURL, !searchActive else { return }
    if automaticRefreshBlocked || automaticRead != nil { scheduleAutomaticRefresh(); return }
    refreshPending = false
    let target = directory, navigation = generation, queryToken = queryGeneration, order = sort, direction = ascending, hidden = showHidden, query = search.stringValue
    let task = Task.detached(priority: .utility) {
      let snapshot = try DirectoryReader.read(target)
      try Task.checkCancellation()
      return (snapshot, EntryQuery.apply(snapshot.entries, showHidden: hidden, query: query, sort: order, ascending: direction))
    }
    automaticRead = task
    Task { @MainActor [weak self] in
      do {
        let (snapshot, values) = try await task.value
        guard let self, !self.stopped, self.generation == navigation, self.directory == target else { return }
        self.automaticRead = nil
        guard self.queryGeneration == queryToken, !self.automaticRefreshBlocked else { self.scheduleAutomaticRefresh(); return }
        self.snapshot = snapshot
        if self.entries != values || self.lastError != nil {
          let scroll = self.mode == .details ? self.tableScroll : self.collectionScroll, origin = (self.mode == .details ? self.tableScroll : self.collectionScroll).contentView.bounds.origin
          self.entries = values; self.selectedPaths.formIntersection(Set(values.map(\.id))); self.lastError = nil
          self.render(); self.view.layoutSubtreeIfNeeded()
          if let document = scroll.documentView {
            let point = NSPoint(x: min(origin.x, max(0, document.bounds.width - scroll.contentSize.width)), y: min(origin.y, max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
          }
          self.refreshVCS(force: true)
          self.automaticRefreshCount += 1
        }
        if self.refreshPending { self.scheduleAutomaticRefresh() }
      } catch {
        guard let self, !self.stopped, self.generation == navigation else { return }
        self.automaticRead = nil
        if error is CancellationError { return }
        if self.automaticRefreshBlocked { self.scheduleAutomaticRefresh(); return }
        self.entries = []; self.selectedPaths = []; self.snapshot = nil; self.lastError = self.errorMessage(error); self.render()
      }
    }
  }
  func stopObserving() {
    guard !stopped else { return }; stopped = true; generation += 1; queryGeneration += 1
    directoryWatcher.stop(); automaticRead?.cancel(); refreshWork?.cancel(); refreshWork = nil
    loadTask?.cancel(); queryTask?.cancel(); searchTask?.cancel()
    inputNavigation?.close(); inputNavigation = nil; preferencesWork?.cancel(); vcsTimer?.invalidate(); vcsTimer = nil
    if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
    if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver); self.preferencesObserver = nil }
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    if let paletteObserver { NotificationCenter.default.removeObserver(paletteObserver); self.paletteObserver = nil }
    if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver); self.settingsObserver = nil }
  }

  func recompute() {
    let descriptor = table.sortDescriptors.first
    if descriptor?.key != sort.rawValue || descriptor?.ascending != ascending {
      syncingSortDescriptors = true
      table.sortDescriptors = [NSSortDescriptor(key: sort.rawValue, ascending: ascending)]
      syncingSortDescriptors = false
    }
    for column in table.tableColumns { (column.headerCell as? ExplorerHeaderCell)?.ascending = column.identifier.rawValue == sort.rawValue ? ascending : nil }; table.headerView?.needsDisplay = true
    guard let snapshot else { return }; queryGeneration += 1; queryTask?.cancel()
    let token = queryGeneration, navigation = generation, hidden = showHidden, query = searchActive ? "" : search.stringValue, order = sort, direction = ascending
    let task = Task.detached(priority: .userInitiated) { EntryQuery.apply(snapshot.entries, showHidden: hidden, query: query, sort: order, ascending: direction) }; queryTask = task
    Task { @MainActor [weak self] in
      let result = await task.value; guard let self, self.queryGeneration == token, self.generation == navigation else { return }
      self.entries = result.map { entry in var value = entry; value.vcsMark = self.vcsStatus?.statesByPath[entry.id]?.mark; return value }; self.selectedPaths.formIntersection(Set(result.map(\.id))); self.loading = false; self.displayedMilliseconds = Date().timeIntervalSince(self.startedAt) * 1000; self.render(); self.restoreLocationState()
    }
  }
  private func render() {
    if renamingEntry != nil { updateStatus(); return }
    readClipboard()
    sizeSlider.doubleValue = Double(iconSize); sizeValue.stringValue = "\(Int(iconSize))"
    syncingSelection = true
    tableScroll.isHidden = mode != .details || loading || entries.isEmpty
    collectionScroll.isHidden = mode == .details || loading || entries.isEmpty
    // Hidden views can still receive layout callbacks after a directory or layout change.
    table.reloadData(); collection.reloadData()
    let selected = entries.indices.filter { selectedPaths.contains(entries[$0].id) }
    table.selectRowIndexes(IndexSet(selected), byExtendingSelection: false)
    collection.selectionIndexPaths = mode == .details || loading ? [] : Set(selected.map { IndexPath(item: $0, section: 0) })
    syncingSelection = false
    emptyLabel.stringValue = loading ? NL("正在读取…") : lastError == nil ? (search.stringValue.isEmpty ? NL("此文件夹为空") : NL("没有匹配的项目")) : NL("无法显示此位置")
    let special = directory.scheme == "explorer" && !viewingTrash
    specialView.isHidden = !special
    let empty = !loading && entries.isEmpty && !special
    emptyLabel.isHidden = special || !loading && !empty; emptyIcon.isHidden = !empty
    emptyIcon.image = search.stringValue.isEmpty ? ExplorerIcons.folder(size: 68) : ExplorerIcons.image("search", size: 42, color: ExplorerPalette.secondary)
    loadingView.isHidden = !loading || special
    spinner.stopAnimation(nil); spinner.isHidden = true
    tableScroll.isHidden = mode != .details || loading || entries.isEmpty
    collectionScroll.isHidden = mode == .details || loading || entries.isEmpty
    if lastError == nil { lastError = operationError }
    errorBar.color = lastError == nil ? ExplorerPalette.surface : ExplorerPalette.errorSurface
    errorLabel.textColor = lastError == nil ? ExplorerPalette.text : ExplorerPalette.errorText
    privacySettings.isHidden = lastError == nil || !(needsFullDiskAccess || lastError?.contains(NL("完全磁盘访问权限")) == true || lastError?.contains(NL("部分回收站无法读取，请检查访问权限后再清空。")) == true)
    errorClose.isHidden = lastError == nil; exitSearch.isHidden = lastError != nil || !searchActive
    errorLabel.stringValue = lastError ?? (searchActive ? NL("“{0}” 的搜索结果 · {1} 个匹配项目", search.stringValue, entries.count) : "")
    errorLabel.toolTip = lastError
    updateStatus(); updatePane(); view.needsLayout = true
    if !loading, let pendingRename, entries.contains(where: { $0.id == pendingRename }) {
      self.pendingRename = nil
      DispatchQueue.main.async { [weak self] in guard let self, self.selectedPaths == [pendingRename] else { return }; self.renameSelected() }
    }
    view.window?.title = "\(locationLabel(directory)) — Mac Explorer"
  }
  private func updateStatus() {
    let chosen = selectedEntries(), total = chosen.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
    status.stringValue = loading ? NL("正在读取…") : NL("{0} 个项目", entries.count) + (chosen.isEmpty ? "" : NL("     已选择 {0} 个项目", chosen.count)) + (total > 0 ? "     \(ExplorerFormat.size(total))" : "") + (message.isEmpty ? (showHidden ? NL("     显示隐藏的项目") : "") : "     \(message)")
    commands["cut"]?.isEnabled = !chosen.isEmpty && !busy && !viewingTrash; commands["copy"]?.isEnabled = !chosen.isEmpty && !busy
    commands["paste"]?.isEnabled = (!clipboard.isEmpty || filePasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])) && !busy && writable
    commands["rename"]?.isEnabled = chosen.count == 1 && !busy && !viewingTrash; commands["share"]?.isEnabled = !chosen.isEmpty && !busy; commands["trash"]?.isEnabled = !chosen.isEmpty && !busy && !viewingTrash
    commands["trash"]?.toolTip = deletionTitle + " " + shortcutHint("trash")
    commands["airdrop"]?.isEnabled = !chosen.isEmpty && !busy; commands["terminal"]?.isEnabled = directory.isFileURL && !busy
    commands["undo"]?.isEnabled = !undoChanges.isEmpty && !busy; commands["refresh"]?.isEnabled = !busy
    if let vcsStatus, vcsStatus.error == nil { status.stringValue += "     \(vcsStatus.kind == .git ? "Git" : "SVN") · \(vcsStatus.branch)" }
    if !directory.isFileURL { status.stringValue = locationLabel(directory) }
    newButton.isEnabled = !busy && writable; detailViewButton.active = mode == .details; iconViewButton.active = mode == .icons; previewButton.active = paneMode == "preview"
  }
  private func configureCollectionLayout() {
    collection.autoresizingMask = mode == .list ? [.height] : [.width]
    // Give each layout organization its own instance, as recommended by AppKit.
    if collectionLayout.mode != mode {
      collectionLayout = ExplorerCollectionLayout()
      collectionLayout.mode = mode
      if isViewLoaded { collection.collectionViewLayout = collectionLayout }
    }
    collectionLayout.mode = mode; collectionLayout.iconSize = iconSize; collectionLayout.compact = compact
  }
  func updateMode(persist: Bool = true) {
    configureCollectionLayout(); table.rowHeight = compact ? 28 : 36
    collectionLayout.invalidateLayout(); sizeSlider.doubleValue = Double(iconSize); sizeValue.stringValue = "\(Int(iconSize))"
    if persist { saveView() }; render(); view.window?.makeFirstResponder(mode == .details ? table : collection)
  }
  func setView(_ layout: ExplorerLayoutMode, size: CGFloat? = nil) { mode = layout; if let size { iconSize = size }; updateMode() }
  @objc private func resizeIcons() { iconSize = CGFloat((sizeSlider.doubleValue / 8).rounded() * 8); updateMode() }
  private func saveView(group: String = "layout") {
    guard directory.isFileURL || directory.scheme == "explorer" else { return }
    let key = directory.isFileURL ? directory.path : directory.absoluteString
    savedFolderViews = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    let global = defaults.dictionary(forKey: "defaultFolderView") ?? [:]
    var current = savedFolderViews[key] ?? [:]
    if group == "columns" {
      if detailColumns == (DetailColumns(propertyList: global["columns"]) ?? DetailColumns()) { current.removeValue(forKey: "columns") }
      else { current["columns"] = detailColumns.propertyList }
    } else if group == "sort" {
      if sort.rawValue == (global["sort"] as? String ?? "name") && ascending == (global["ascending"] as? Bool ?? true) { current.removeValue(forKey: "sort"); current.removeValue(forKey: "ascending") }
      else { current["sort"] = sort.rawValue; current["ascending"] = ascending }
    } else {
      if mode.rawValue == (global["view"] as? String ?? "icons") && Int(iconSize) == (global["iconSize"] as? Int ?? 64) { current.removeValue(forKey: "view"); current.removeValue(forKey: "iconSize") }
      else { current["view"] = mode.rawValue; current["iconSize"] = Int(iconSize) }
    }
    if current["view"] == nil && current["sort"] == nil && current["columns"] == nil { savedFolderViews.removeValue(forKey: key) }
    else { current["lastUsed"] = Date().timeIntervalSince1970; savedFolderViews[key] = current }
    if savedFolderViews.count > 5000 {
      let oldest = savedFolderViews.filter { $0.key != key }.sorted {
        let a = $0.value["lastUsed"] as? Double ?? 0, b = $1.value["lastUsed"] as? Double ?? 0
        return a == b ? $0.key < $1.key : a < b
      }.prefix(savedFolderViews.count - 5000)
      for item in oldest { savedFolderViews.removeValue(forKey: item.key) }
    }
    assert(savedFolderViews.count <= 5000)
    defaults.set(savedFolderViews, forKey: "folderViews")
  }
  private func restoreView(_ url: URL, touch: Bool = false) {
    guard url.isFileURL || url.scheme == "explorer" else { return }
    let key = url.isFileURL ? url.path : url.absoluteString
    savedFolderViews = defaults.dictionary(forKey: "folderViews") as? [String: [String: Any]] ?? [:]
    if touch, var saved = savedFolderViews[key] {
      var info = stat()
      let status = url.isFileURL ? url.path.withCString { fstatat(AT_FDCWD, $0, &info, 0) } : 0
      if status == 0 && (!url.isFileURL || info.st_mode & S_IFMT == S_IFDIR) { saved["lastUsed"] = Date().timeIntervalSince1970; savedFolderViews[key] = saved }
      else if status == 0 || errno == ENOENT || errno == ENOTDIR { savedFolderViews.removeValue(forKey: key) }
      defaults.set(savedFolderViews, forKey: "folderViews")
    }
    let global = defaults.dictionary(forKey: "defaultFolderView") ?? [:], saved = savedFolderViews[key] ?? [:]
    mode = ExplorerLayoutMode(rawValue: global["view"] as? String ?? "icons") ?? .icons
    iconSize = CGFloat((32...128).contains(global["iconSize"] as? Int ?? 64) ? global["iconSize"] as? Int ?? 64 : 64)
    sort = EntrySort(rawValue: global["sort"] as? String ?? "name") ?? .name; ascending = global["ascending"] as? Bool ?? true
    if let view = saved["view"] as? String, let layout = ExplorerLayoutMode(rawValue: view), let size = saved["iconSize"] as? Int, (32...128).contains(size) { mode = layout; iconSize = CGFloat(size) }
    if let order = saved["sort"] as? String, let key = EntrySort(rawValue: order), let direction = saved["ascending"] as? Bool { sort = key; ascending = direction }
    detailColumns = DetailColumns(propertyList: saved["columns"]) ?? DetailColumns(propertyList: global["columns"]) ?? DetailColumns()
    configureCollectionLayout()
  }
  func selectedEntries() -> [FileEntry] { entries.filter { selectedPaths.contains($0.id) } }
  private func displayName(_ entry: FileEntry) -> String { if entry.isPackage { return entry.url.deletingPathExtension().lastPathComponent }; return extensions || entry.isDirectory || entry.url.pathExtension.isEmpty ? entry.name : entry.url.deletingPathExtension().lastPathComponent }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard entries.indices.contains(row), let id = tableColumn?.identifier else { return nil }; let entry = entries[row]
    if id.rawValue == "name" {
      let cell = (table.makeView(withIdentifier: id, owner: self) as? NameCell) ?? NameCell(); cell.identifier = id; cell.configure(entry, name: displayName(entry)); cell.checkboxes = checkboxes
      cell.checkbox.state = selectedPaths.contains(entry.id) ? .on : .off; cell.checkbox.changed = { [weak self] in self?.toggleSelection(entry.id, selected: $0) }
      cell.alphaValue = isCut && clipboard.contains(entry.url) ? 0.44 : entry.isHidden ? 0.6 : 1; return cell
    }
    let cell = (table.makeView(withIdentifier: id, owner: self) as? MetadataCell) ?? MetadataCell(); cell.identifier = id
    cell.value.alignment = .left
    switch id.rawValue { case "modified": cell.value.stringValue = entry.modified.map(dateFormatter.string) ?? ""; case "created": cell.value.stringValue = entry.created.map(dateFormatter.string) ?? ""; case "size": cell.value.stringValue = entry.isDirectory ? "" : ExplorerFormat.size(entry.size); cell.value.alignment = .right; default: cell.value.stringValue = entry.kind }; return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) { guard !syncingSelection, mode == .details else { return }; selectedPaths = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil }); updateStatus(); updatePane() }
  func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { guard !syncingSortDescriptors, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let order = EntrySort(rawValue: key) else { return }; sort = order; ascending = descriptor.ascending; saveView(group: "sort"); recompute() }
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { mode == .details || loading ? 0 : entries.count }
  func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
    let item = collection.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("file"), for: indexPath) as! IconItem
    guard entries.indices.contains(indexPath.item) else { item.view.isHidden = true; return item }
    let entry = entries[indexPath.item]; item.view.isHidden = false
    item.configure(entry, name: displayName(entry), mode: mode, size: iconSize, checkboxes: checkboxes)
    item.checkbox.changed = { [weak self] in self?.toggleSelection(entry.id, selected: $0) }; return item
  }
  func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncCollectionSelection() }
  func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncCollectionSelection() }
  private func syncCollectionSelection() { guard !syncingSelection, mode != .details else { return }; selectedPaths = Set(collection.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].id : nil }); updateStatus(); updatePane() }
  private func toggleSelection(_ path: String, selected: Bool) { if selected { selectedPaths.insert(path) } else { selectedPaths.remove(path) }; render() }
  func controlTextDidChange(_ obj: Notification) { guard (obj.object as? NSTextField) === search else { return }; searchBox.update(); if !directory.isFileURL { specialView.filter(search.stringValue); return }; if search.stringValue.isEmpty { if searchActive { searchActive = false; reload() } else { recompute() } } }

  var canDetachTab: Bool {
    !stopped && !busy && renamingEntry == nil && view.window.map { !ExplorerDialogs.isPresenting(in: $0) && $0.attachedSheet == nil } == true
  }
  @discardableResult
  func detachTab(id: UUID, at point: NSPoint) -> Bool {
    guard canDetachTab, let index = tabs.firstIndex(where: { $0.id == id }), let window = view.window else { return false }
    ExplorerMenu.dismiss()
    if tabs.count == 1 { ApplicationDelegate.position(window, at: point); window.makeKeyAndOrderFront(nil); return true }
    if index == activeTab { rememberLocationState() }
    guard onDetachTab?(tabs[index], point) == true else { return false }
    closeTab(at: index)
    return true
  }
  func adopt(_ tab: BrowserTab) {
    guard !tab.history.isEmpty, tab.history.indices.contains(tab.index) else { return }
    tabs = [tab]; activeTab = 0; prepareLocationState(tab.locationStates[tab.index] ?? BrowserLocationState(selection: tab.selectedPaths)); restoreView(tab.directory, touch: true)
  }
  func openTab(at url: URL) {
    rememberLocationState()
    tabs.append(BrowserTab(history: [url])); activeTab = tabs.count - 1; prepareLocationState(BrowserLocationState()); search.stringValue = ""; searchActive = false; restoreView(directory, touch: true); reload()
    view.layoutSubtreeIfNeeded(); tabsDocument.subviews.last?.scrollToVisible(tabsDocument.subviews.last!.bounds)
  }
  @objc func newTab() { openTab(at: NativeStartLocation.load(defaults).url(home: home)) }
  @objc func closeTab() { closeTab(at: activeTab) }
  private func closeTab(at index: Int) {
    guard tabs.indices.contains(index) else { return }
    if tabs.count == 1 { view.window?.close(); return }
    let wasActive = index == activeTab
    rememberLocationState()
    tabs.remove(at: index)
    if index < activeTab || wasActive { activeTab = max(0, activeTab - 1) }
    if wasActive { prepareLocationState(tabs[activeTab].locationStates[tabs[activeTab].index] ?? BrowserLocationState(selection: selectedPaths)); search.stringValue = ""; searchActive = false; restoreView(directory, touch: true); reload() } else { rebuildTabs() }
  }
  func switchTab(to index: Int) {
    guard tabs.indices.contains(index), index != activeTab else { return }
    rememberLocationState(); activeTab = index
    prepareLocationState(tabs[activeTab].locationStates[tabs[activeTab].index] ?? BrowserLocationState(selection: selectedPaths))
    search.stringValue = ""; searchActive = false; restoreView(directory, touch: true); reload()
  }
  @objc func back() { travelHistory(-1) }
  @objc func forward() { travelHistory(1) }
  @objc func up() { navigate(to: directory.deletingLastPathComponent()) }
  @objc func focusAddress() { addressBar.beginEditing() }
  @objc func focusSearch() { view.window?.makeFirstResponder(search); search.selectText(nil) }
  @objc func goAddress() { goAddress(address.stringValue) }
  private func goAddress(_ value: String) {
    let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, !input.contains("\0") else { return }
    addressSubmission += 1; let request = addressSubmission
    if input.lowercased().hasPrefix("smb:") { connectServer(input); return }
    let base = directory, tab = tabs[activeTab].id, home = self.home
    Task { @MainActor [weak self] in
      do {
        let metadata = try await Task.detached { try NativeAddressPath.metadata(NativeAddressPath.resolve(input, current: base, home: home)) }.value
        guard let self, self.addressSubmission == request, self.tabs[self.activeTab].id == tab, self.directory == base else { return }
        if metadata.isFolder { self.navigate(to: metadata.url) }
        else if NativeArchives.isArchive(metadata.url), let window = self.view.window { NativeArchiveWindow.present(archive: metadata.url, parent: window) { [weak self] in self?.acceptExternalResult($0) } }
        else if !NSWorkspace.shared.open(metadata.url) { throw NativeNetwork.failure("无法打开此项目。") }
        self.addressBar.recentPaths = Array(([metadata.url.path] + self.addressBar.recentPaths.filter { $0 != metadata.url.path }).prefix(25))
        self.defaults.set(self.addressBar.recentPaths, forKey: "typedPaths")
      } catch { guard let self, self.addressSubmission == request, self.tabs[self.activeTab].id == tab, self.directory == base else { return }; self.lastError = self.errorMessage(error); self.render() }
    }
  }

  @objc func toggleHidden() { showHidden.toggle(); defaults.set(showHidden, forKey: "showHidden"); addressBar.showHidden = showHidden; recompute(); for path in expanded { readFolderChildren(URL(fileURLWithPath: path)) }; rebuildSidebar() }
  @objc func selectAllFiles() { selectedPaths = Set(entries.map(\.id)); render() }
  @objc func openSelected() {
    guard let entry = selectedEntries().first, selectedPaths.count == 1 else { return }
    if entry.isDirectory && !entry.isPackage { navigate(to: entry.url) }
    else if NativeArchives.isArchive(entry.url), let window = view.window { NativeArchiveWindow.present(archive: entry.url, parent: window) { [weak self] in self?.acceptExternalResult($0) } }
    else { NSWorkspace.shared.open(entry.url) }
  }
  @objc func revealSelected() { NSWorkspace.shared.activateFileViewerSelecting(selectedEntries().map(\.url)) }
  @objc func copyPaths() { let paths = selectedEntries().map { $0.url.path }; guard !paths.isEmpty else { return }; filePasteboard.clearContents(); filePasteboard.setString(paths.joined(separator: "\n"), forType: .string) }
  @objc func previewSelected() { previewURLs = selectedEntries().map { $0.url as NSURL }; guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }; panel.makeKeyAndOrderFront(nil); panel.reloadData() }
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !previewURLs.isEmpty }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] }

  private func performSearch() {
    if !directory.isFileURL { specialView.filter(search.stringValue); return }
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { searchActive = false; reload(); return }
    directoryWatcher.stop(); automaticRead?.cancel(); automaticRead = nil; refreshWork?.cancel(); refreshWork = nil; refreshPending = false
    generation += 1; queryGeneration += 1; loadTask?.cancel(); queryTask?.cancel(); searchTask?.cancel()
    let token = generation, target = directory, hidden = showHidden
    let mode = FileSearchMode(rawValue: defaults.string(forKey: "searchMode") ?? "") ?? .text
    loading = true; lastError = nil; snapshot = nil; entries = []; searchActive = true; selectedPaths = []; render()
    let task = Task.detached(priority: .userInitiated) { try FileSearch.search(in: target, query: query, showHidden: hidden, mode: mode) }; searchTask = task
    Task { @MainActor [weak self] in
      do { let result = try await task.value; guard let self, self.generation == token else { return }; self.snapshot = DirectorySnapshot(directory: target, entries: result.entries, skippedCount: result.skipped, elapsedMilliseconds: 0); self.message = result.truncated ? NL("已达到搜索上限") : ""; self.recompute() }
      catch { guard let self, self.generation == token else { return }; self.loading = false; self.lastError = self.errorMessage(error); self.render() }
    }
  }

  func sortMenu() -> [ExplorerMenuItem] {
    var items = [(NL("名称"), EntrySort.name), (NL("修改日期"), .modified), (NL("创建日期"), .created), (NL("类型"), .kind), (NL("大小"), .size)].map { name, key in ExplorerMenuItem(title: name, checked: sort == key, action: { [weak self] in self?.sort = key; self?.saveView(group: "sort"); self?.recompute() }) }
    items += [ExplorerMenuItem(title: NL("递增"), checked: ascending, divider: true, action: { [weak self] in self?.ascending = true; self?.saveView(group: "sort"); self?.recompute() }), ExplorerMenuItem(title: NL("递减"), checked: !ascending, action: { [weak self] in self?.ascending = false; self?.saveView(group: "sort"); self?.recompute() })]; return items
  }
  func columnMenu() -> [ExplorerMenuItem] {
    let titles = ["name": NL("名称"), "modified": NL("修改日期"), "created": NL("创建日期"), "kind": NL("类型"), "size": NL("大小")]
    return detailColumns.order.map { id in
      ExplorerMenuItem(title: titles[id]!, checked: detailColumns.visible.contains(id), enabled: id != "name", action: { [weak self] in
        guard let self, id != "name" else { return }; self.captureColumnWidths()
        if self.detailColumns.visible.contains(id) { self.detailColumns.visible.remove(id) } else { self.detailColumns.visible.insert(id) }
        self.detailColumns.automatic = false; self.saveView(group: "columns"); self.view.needsLayout = true
      })
    } + [ExplorerMenuItem(title: NL("恢复默认列"), divider: true, action: { [weak self] in
      guard let self else { return }; self.detailColumns = DetailColumns(); self.saveView(group: "columns"); self.view.needsLayout = true
    })]
  }
  private func captureColumnWidths() {
    guard detailColumns.automatic else { return }
    for column in table.tableColumns { detailColumns.widths[column.identifier.rawValue] = column.width }
  }
  func tableViewColumnDidResize(_ notification: Notification) {
    guard !syncingColumns, isViewLoaded, view.window != nil, mode == .details else { return }
    for column in table.tableColumns { detailColumns.widths[column.identifier.rawValue] = column.width }
    detailColumns.automatic = false; saveView(group: "columns")
  }
  func tableViewColumnDidMove(_ notification: Notification) {
    guard !syncingColumns, isViewLoaded, view.window != nil, mode == .details else { return }
    captureColumnWidths(); detailColumns.order = table.tableColumns.map { $0.identifier.rawValue }
    detailColumns.automatic = false; saveView(group: "columns")
  }
  func viewMenu() -> [ExplorerMenuItem] {
    var items = [(NL("超大图标"), CGFloat(128)), (NL("大图标"), 64), (NL("中图标"), 48), (NL("小图标"), 32)].enumerated().map { index, option in ExplorerMenuItem(title: option.0, icon: ["viewExtra", "viewLarge", "viewMedium", "viewSmall"][index], checked: mode == .icons && iconSize == option.1, radio: true, shortcut: shortcutHint(["extra-large-icons", "icons", "medium-icons", "small-icons"][index]), action: { [weak self] in self?.setView(.icons, size: option.1) }) }
    for (index, option) in [(NL("列表"), ExplorerLayoutMode.list), (NL("详细信息"), .details), (NL("平铺"), .tiles), (NL("内容"), .content)].enumerated() { items.append(ExplorerMenuItem(title: option.0, icon: ["viewList", "viewDetails", "viewTiles", "viewContent"][index], checked: mode == option.1, radio: true, shortcut: shortcutHint(["list", "details", "tiles", "content"][index]), action: { [weak self] in self?.setView(option.1) })) }
    items.append(ExplorerMenuItem(title: NL("列"), children: columnMenu()))
    items += [ExplorerMenuItem(title: NL("详细信息窗格"), icon: "panelRight", checked: paneMode == "details", divider: true, action: { [weak self] in self?.togglePane("details") }), ExplorerMenuItem(title: NL("预览窗格"), icon: "panelRight", checked: paneMode == "preview", action: { [weak self] in self?.togglePane("preview") }), ExplorerMenuItem(title: NL("显示"), divider: true, children: [
      ExplorerMenuItem(title: NL("导航窗格"), icon: "panelLeft", checked: navigationPane, action: { [weak self] in guard let self else { return }; self.navigationPane.toggle(); self.defaults.set(self.navigationPane, forKey: "navigationPane"); self.view.needsLayout = true }),
      ExplorerMenuItem(title: NL("紧凑视图"), icon: "list", checked: compact, divider: true, action: { [weak self] in guard let self else { return }; self.compact.toggle(); self.defaults.set(self.compact, forKey: "compact"); self.updateMode(persist: false) }),
      ExplorerMenuItem(title: NL("项目复选框"), icon: "check", checked: checkboxes, divider: true, action: { [weak self] in guard let self else { return }; self.checkboxes.toggle(); self.defaults.set(self.checkboxes, forKey: "checkboxes"); self.render() }),
      ExplorerMenuItem(title: NL("文件扩展名"), icon: "document", checked: extensions, action: { [weak self] in guard let self else { return }; self.extensions.toggle(); self.defaults.set(self.extensions, forKey: "extensions"); self.render() }),
      ExplorerMenuItem(title: NL("隐藏的项目"), icon: "eye", checked: showHidden, action: { [weak self] in self?.toggleHidden() }),
    ]), ExplorerMenuItem(title: NL("应用到所有文件夹"), divider: true, action: { [weak self] in guard let self else { return }; self.defaults.set(["view": self.mode.rawValue, "iconSize": Int(self.iconSize), "sort": self.sort.rawValue, "ascending": self.ascending, "columns": self.detailColumns.propertyList], forKey: "defaultFolderView"); self.savedFolderViews = [:]; self.defaults.set([String: [String: Any]](), forKey: "folderViews") })]; return items
  }
  private func newMenu() -> [ExplorerMenuItem] {
    [(NL("文件夹"), "folder"), (NL("文本文档"), "txt"), (NL("Word 文档"), "docx"), (NL("Excel 工作簿"), "xlsx"), (NL("PowerPoint 演示文稿"), "pptx")].map { name, kind in
      ExplorerMenuItem(title: name, icon: kind == "folder" ? "folder" : "document", action: { [weak self] in self?.createEntry(kind: kind) })
    }
  }
  private func moreMenu() -> [ExplorerMenuItem] {
    let target = pinTarget(), pinned = target.map { pinnedPaths.contains($0.path) } ?? false
    return [ExplorerMenuItem(title: NL("打开文件夹…"), icon: "folder", action: { [weak self] in self?.chooseDirectory() }), ExplorerMenuItem(title: pinned ? NL("从快速访问取消固定") : NL("固定到快速访问"), icon: "pin", enabled: target != nil, action: { [weak self] in if let target { self?.togglePin(target) } }), ExplorerMenuItem(title: NL("全选"), shortcut: shortcutHint("select-all"), action: { [weak self] in self?.selectAllFiles() }), ExplorerMenuItem(title: NL("取消选择"), action: { [weak self] in self?.selectedPaths = []; self?.render() }), ExplorerMenuItem(title: NL("撤销"), icon: "undo", enabled: !undoChanges.isEmpty && !busy, divider: true, shortcut: shortcutHint("undo"), action: { [weak self] in self?.undoFiles() }), ExplorerMenuItem(title: NL("重做"), enabled: !redoChanges.isEmpty && !busy, shortcut: shortcutHint("redo"), action: { [weak self] in self?.redoFiles() }), ExplorerMenuItem(title: NL("设置…"), icon: "settings", divider: true, action: { [weak self] in self?.showSettings() })]
  }
  func contextItems() -> [ExplorerMenuItem] {
    let chosen = selectedEntries(), first = selectedEntries().first
    let canPaste = !busy && writable && (!clipboard.isEmpty || filePasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]))
    let refresh = ExplorerMenuItem(title: NL("刷新"), icon: "refresh", shortcut: shortcutHint("refresh"), action: { [weak self] in self?.executeAction("refresh") })
    let hidden = ExplorerMenuItem(title: showHidden ? NL("不显示隐藏项目") : NL("显示隐藏的项目"), checked: showHidden, action: { [weak self] in self?.toggleHidden() })
    if viewingTrash {
      var items: [ExplorerMenuItem] = []
      if !chosen.isEmpty {
        items += [ExplorerMenuItem(title: NL("还原"), icon: "undo", enabled: !busy, action: { [weak self] in self?.restoreFromTrash(choose: false) }), ExplorerMenuItem(title: NL("还原到…"), icon: "folder", enabled: !busy, action: { [weak self] in self?.restoreFromTrash(choose: true) })]
      }
      items.append(ExplorerMenuItem(title: NL("清空回收站…"), icon: "trash", enabled: !busy, action: { [weak self] in self?.emptySystemTrash() }))
      if let first {
        items += [ExplorerMenuItem(title: first.isDirectory ? NL("打开") : NL("快速查看"), icon: "folder", action: { [weak self] in if first.isDirectory { self?.openSelected() } else { self?.previewSelected() } }), ExplorerMenuItem(title: NL("复制"), icon: "copy", shortcut: shortcutHint("copy"), action: { [weak self] in self?.copySelection(cut: false) })]
      }
      return items + [refresh, hidden]
    }
    var items: [ExplorerMenuItem] = []
    if let first {
      items = [ExplorerMenuItem(title: NL("打开"), icon: "folder", shortcut: shortcutHint("open"), action: { [weak self] in self?.openSelected() }), openWithMenu(chosen.map(\.url))]
      if !first.isDirectory {
        items.append(ExplorerMenuItem(title: NL("使用文本编辑"), icon: "document", enabled: chosen.allSatisfy { !$0.isDirectory }, action: { [weak self] in self?.openAsText(chosen.map(\.url)) }))
        if NativeArchives.isArchive(first.url) {
          for (mode, title) in [("choose", NL("解压到…")), ("here", NL("解压到当前目录")), ("folder", NL("解压到“{0}/”", NativeArchives.folderName(first.url)))] {
            items.append(ExplorerMenuItem(title: title, icon: "download", enabled: chosen.count == 1 && !busy, action: { [weak self] in self?.extract(first.url, mode: mode) }))
          }
        }
        items.append(ExplorerMenuItem(title: NL("快速查看"), icon: "eye", shortcut: shortcutHint("quick-look"), action: { [weak self] in self?.previewSelected() }))
      } else {
        items += [ExplorerMenuItem(title: NL("在新标签页中打开"), icon: "plus", action: { [weak self] in self?.openTab(at: first.url) }), ExplorerMenuItem(title: NL("在终端中打开"), icon: "terminal", action: { [weak self] in self?.openTerminal(at: first.url) })]
      }
      items += [
        ExplorerMenuItem(title: NL("压缩为 ZIP"), icon: "archive", enabled: !busy, action: { [weak self] in self?.compressSelection() }),
        ExplorerMenuItem(title: NL("剪切"), icon: "scissors", enabled: !busy, shortcut: shortcutHint("cut"), action: { [weak self] in self?.copySelection(cut: true) }),
        ExplorerMenuItem(title: NL("复制"), icon: "copy", shortcut: shortcutHint("copy"), action: { [weak self] in self?.copySelection(cut: false) }),
        ExplorerMenuItem(title: NL("复制文件地址"), icon: "copy", action: { [weak self] in self?.copyPaths() }),
        ExplorerMenuItem(title: NL("重命名"), icon: "rename", enabled: chosen.count == 1 && !busy, shortcut: shortcutHint("rename"), action: { [weak self] in self?.renameSelected() }),
        ExplorerMenuItem(title: NL("共享"), icon: "share", action: { [weak self] in self?.shareSelected() }),
        ExplorerMenuItem(title: deletionTitle, icon: "trash", enabled: !busy, shortcut: shortcutHint("trash"), action: { [weak self] in self?.trashSelected() })]
      if first.isDirectory, first.url != cloudDrive {
        items.append(ExplorerMenuItem(title: pinnedPaths.contains(first.url.path) ? NL("从快速访问取消固定") : NL("固定到快速访问"), icon: "pin", divider: true, action: { [weak self] in self?.togglePin(first.url) }))
      }
      items.append(ExplorerMenuItem(title: NL("属性"), icon: "document", divider: true, action: { [weak self] in self?.showProperties() }))
    } else {
      items = [ExplorerMenuItem(title: NL("新建"), icon: "plus", enabled: writable && !busy, children: newMenu()),
        ExplorerMenuItem(title: NL("粘贴"), icon: "paste", enabled: canPaste, divider: true, shortcut: shortcutHint("paste"), action: { [weak self] in self?.pasteFiles() }),
        ExplorerMenuItem(title: NL("将项目移到这里"), enabled: canPaste, shortcut: shortcutHint("move-here"), action: { [weak self] in self?.executeAction("move-here") }),
        ExplorerMenuItem(title: NL("撤销"), icon: "undo", enabled: !undoChanges.isEmpty && !busy, shortcut: shortcutHint("undo"), action: { [weak self] in self?.undoFiles() }), ExplorerMenuItem(title: NL("重做"), enabled: !redoChanges.isEmpty && !busy, shortcut: shortcutHint("redo"), action: { [weak self] in self?.redoFiles() }), refresh, hidden,
        ExplorerMenuItem(title: NL("打开文件夹…"), icon: "folder", action: { [weak self] in self?.chooseDirectory() })]
      if directory.isFileURL { items.append(ExplorerMenuItem(title: NL("在终端中打开"), icon: "terminal", action: { [weak self] in self?.openTerminal() })) }
    }
    if let vcsStatus {
      var actions = [NativeVCSAction.diff, .add, .commit, .update, .revert].map { action in ExplorerMenuItem(title: action.title, enabled: vcsStatus.error == nil && !busy, action: { [weak self] in self?.showVCS(action) }) }
      actions.append(ExplorerMenuItem(title: NL("刷新版本状态"), action: { [weak self] in self?.refreshVCS(force: true) }))
      items.append(ExplorerMenuItem(title: vcsStatus.kind == .git ? "Git" : "SVN", icon: "terminal", divider: true, children: actions))
    }
    return items
  }
  private func showContext(_ event: NSEvent) {
    guard let window = view.window else { return }
    let items = contextItems()
    let quickNames = viewingTrash || selectedPaths.isEmpty ? [] : [NL("剪切"), NL("复制"), NL("重命名"), NL("移到回收站")]
    let quick = quickNames.compactMap { name in items.first { $0.title == name } }
    ExplorerMenu.show(items.filter { !quickNames.contains($0.title) }, at: window.convertPoint(toScreen: event.locationInWindow), owner: window, quickActions: quick)
  }

  private func togglePane(_ name: String) { paneMode = paneMode == name ? "" : name; defaults.set(paneMode, forKey: "paneMode"); updatePane(); updateStatus(); view.needsLayout = true }
  private func updatePane() {
    paneRequest = UUID(); let request = paneRequest
    detailsPreview?.previewItem = nil; detailsPreview?.removeFromSuperview(); detailsPreview = nil
    pane.subviews.forEach { $0.removeFromSuperview() }; paneBody.subviews.forEach { $0.removeFromSuperview() }
    guard !paneMode.isEmpty else { return }
    let title = label(paneMode == "details" ? NL("详细信息") : NL("预览"), size: 14); title.identifier = NSUserInterfaceItemIdentifier("title"); pane.addSubview(title)
    let close = ExplorerButton(icon: "close") { [weak self] in self?.paneMode = ""; self?.defaults.set("", forKey: "paneMode"); self?.updatePane(); self?.updateStatus(); self?.view.needsLayout = true }; close.identifier = NSUserInterfaceItemIdentifier("close"); pane.addSubview(close)
    paneScroll.documentView = paneBody; paneScroll.hasVerticalScroller = true; paneScroll.autohidesScrollers = true; paneScroll.drawsBackground = false
    pane.addSubview(paneScroll)
    let selected = selectedEntries()
    if selected.count == 1, let entry = selected.first {
      let name = label(entry.name, size: 15); name.font = .systemFont(ofSize: 15, weight: .semibold); name.identifier = NSUserInterfaceItemIdentifier("name"); paneBody.addSubview(name)
      if paneMode == "preview", !entry.isDirectory, let preview = QLPreviewView(frame: .zero, style: .normal) {
        preview.previewItem = entry.url as NSURL; paneBody.addSubview(preview); detailsPreview = preview
      } else {
        let backdrop = SurfaceView(); backdrop.color = ExplorerPalette.surface; backdrop.identifier = NSUserInterfaceItemIdentifier("preview-background"); paneBody.addSubview(backdrop)
        let icon = FileIconView(); icon.show(entry); icon.imageScaling = .scaleProportionallyUpOrDown; icon.identifier = NSUserInterfaceItemIdentifier("icon"); paneBody.addSubview(icon)
        var values = [entry.kind, NL("位置"), entry.url.deletingLastPathComponent().path, NL("大小"), entry.isDirectory ? NL("文件夹") : NL("{0}（{1} 字节）", ExplorerFormat.size(entry.size), entry.size.formatted(.number.locale(NativeLanguage.formatLocale))), NL("修改日期"), entry.modified.map(dateFormatter.string) ?? "—", NL("创建日期"), entry.created.map(dateFormatter.string) ?? "—"]
        if entry.isSymbolicLink { values += [NL("链接"), NL("符号链接")] }
        for (i, text) in values.enumerated() { let value = label(text, size: i == 0 ? 12 : 11, color: i % 2 == 1 ? ExplorerPalette.secondary : ExplorerPalette.text); value.toolTip = text; value.identifier = NSUserInterfaceItemIdentifier("value-\(i)"); paneBody.addSubview(value) }
        if paneMode == "details" {
          Task { @MainActor [weak self, weak icon] in
            let result = try? await Task.detached(priority: .utility) { try NativeFilePreview.read(entry) }.value
            guard let self, self.paneRequest == request else { return }
            if let data = result?.image { icon?.image = NSImage(data: data) }
            if let text = result?.text {
              let preview = NSTextView(); preview.string = text; preview.isEditable = false; preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular); preview.textColor = ExplorerPalette.text; preview.backgroundColor = ExplorerPalette.surface
              let scroll = NSScrollView(); scroll.documentView = preview; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.identifier = NSUserInterfaceItemIdentifier("text-preview"); self.paneBody.addSubview(scroll)
              let heading = label(NL("内容预览"), size: 12); heading.identifier = NSUserInterfaceItemIdentifier("text-heading"); self.paneBody.addSubview(heading)
              if result?.truncated == true { let note = label(NL("仅显示前 16 KB"), size: 11, color: ExplorerPalette.secondary); note.identifier = NSUserInterfaceItemIdentifier("text-limit"); self.paneBody.addSubview(note) }
              self.layoutPane()
            }
          }
        }
      }
      let quick = ExplorerButton(title: NL("快速查看")) { [weak self] in self?.previewSelected() }
      quick.identifier = NSUserInterfaceItemIdentifier("quick-look"); paneBody.addSubview(quick)
    } else {
      let text = selected.isEmpty ? (paneMode == "preview" ? NL("未选择项目") : locationLabel(directory)) : NL("已选择 {0} 个项目", selected.count)
      let name = label(text, size: 15); name.identifier = NSUserInterfaceItemIdentifier("empty"); paneBody.addSubview(name)
      if selected.count > 1, paneMode == "details" {
        let size = selected.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        let total = label(NL("文件大小合计 {0}", ExplorerFormat.size(size)), size: 12, color: ExplorerPalette.secondary)
        total.identifier = NSUserInterfaceItemIdentifier("total"); paneBody.addSubview(total)
      }
    }
    layoutPane()
  }
  private func layoutPane() {
    let width = pane.bounds.width
    pane.subviews.first { $0.identifier?.rawValue == "title" }?.frame = NSRect(x: 22, y: 20, width: width - 70, height: 20)
    pane.subviews.first { $0.identifier?.rawValue == "close" }?.frame = NSRect(x: width - 50, y: 14, width: 28, height: 28)
    paneScroll.frame = NSRect(x: 1, y: 54, width: max(0, width - 1), height: max(0, pane.bounds.height - 54))
    let metadata = paneBody.subviews.compactMap { child -> (Int, NSTextField)? in
      guard let id = child.identifier?.rawValue, id.hasPrefix("value-"), let index = Int(id.dropFirst(6)), let label = child as? NSTextField else { return nil }
      return (index, label)
    }.sorted { $0.0 < $1.0 }
    var contentY: CGFloat = 206
    for (index, value) in metadata {
      value.maximumNumberOfLines = 0; value.lineBreakMode = .byWordWrapping
      let textWidth = max(1, width - 44)
      let measured = (value.stringValue as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: value.font ?? NSFont.systemFont(ofSize: 11)]).height
      let height = max(22, ceil(measured))
      value.frame = NSRect(x: 22, y: contentY, width: textWidth, height: height)
      contentY += height + (index == 0 || index % 2 == 0 ? 18 : 0)
    }
    let hasText = paneBody.subviews.contains { $0.identifier?.rawValue == "text-preview" }
    let quickY = paneMode == "preview" ? max(240, paneScroll.bounds.height - 46) : contentY + (hasText ? 260 : 12)
    for child in paneBody.subviews {
      switch child.identifier?.rawValue ?? "" {
      case "name": child.frame = NSRect(x: 22, y: paneMode == "preview" ? 11 : 170, width: width - 44, height: 25)
      case "preview-background": child.frame = NSRect(x: 22, y: 0, width: width - 44, height: 148)
      case "icon": child.frame = NSRect(x: (width - 70) / 2, y: 41, width: 70, height: 70)
      case "empty": child.frame = NSRect(x: 22, y: 76, width: width - 44, height: 25)
      case "total": child.frame = NSRect(x: 22, y: 113, width: width - 44, height: 22)
      case "quick-look": child.frame = NSRect(x: 22, y: quickY, width: width - 44, height: 30)
      case "text-heading": child.frame = NSRect(x: 22, y: contentY, width: width - 44, height: 22)
      case "text-preview":
        child.frame = NSRect(x: 22, y: contentY + 28, width: width - 44, height: 200)
        if let scroll = child as? NSScrollView, let text = scroll.documentView as? NSTextView {
          text.frame.size.width = scroll.contentSize.width; text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude); text.textContainer?.widthTracksTextView = true
          text.isVerticallyResizable = true; text.minSize = NSSize(width: 0, height: 200); text.sizeToFit()
        }
      case "text-limit": child.frame = NSRect(x: 22, y: contentY + 232, width: width - 44, height: 20)
      default: break
      }
    }
    detailsPreview?.frame = NSRect(x: 22, y: 46, width: max(0, width - 44), height: max(180, quickY - 58))
    paneBody.frame = NSRect(x: 0, y: 0, width: width, height: max(paneScroll.bounds.height, paneBody.subviews.map { $0.frame.maxY + 16 }.max() ?? 0))
  }
  private func chooseDirectory() { guard let window = view.window else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.beginSheetModal(for: window) { [weak self] result in if result == .OK, let url = panel.url { self?.navigate(to: url) } } }
  private func askName(title: String, value: String, completion: @escaping (String) -> Void) {
    guard let window = view.window else { return }
    ExplorerDialogs.name(in: window, title: title, value: value, submit: completion)
  }
  private func createEntry(directory isDirectory: Bool) { createEntry(kind: isDirectory ? "folder" : "txt") }
  private func createEntry(kind: String) {
    guard !busy, writable else { return }
    let stem = ["folder": NL("新建文件夹"), "txt": NL("新建文本文档"), "docx": NL("新建 Word 文档"), "xlsx": NL("新建 Excel 工作簿"), "pptx": NL("新建 PowerPoint 演示文稿")][kind] ?? NL("新建文本文档")
    let suffix = kind == "folder" ? "" : "." + kind, parent = directory
    let names = Set((snapshot?.entries ?? entries).map(\.name)); var name = stem + suffix; var number = 2
    while names.contains(name) { name = "\(stem) (\(number))\(suffix)"; number += 1 }
    let template = ["docx", "xlsx", "pptx"].contains(kind) ? Bundle.main.url(forResource: "blank", withExtension: kind, subdirectory: "templates") : nil
    if ["docx", "xlsx", "pptx"].contains(kind) && template == nil { lastError = NL("文档模板不可用"); render(); return }
    let destinationName = name
    runSingle(beginRename: true) { try FileActions.create(in: parent, name: destinationName, directory: kind == "folder", template: template) }
  }
  private func renameSelected() {
    guard !busy, !viewingTrash, let entry = selectedEntries().first, selectedPaths.count == 1, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
    cancelInlineRename()
    let field: NSTextField?
    if mode == .details {
      let nameColumn = table.column(withIdentifier: .init("name"))
      table.scrollRowToVisible(index); table.scrollColumnToVisible(nameColumn); field = (table.view(atColumn: nameColumn, row: index, makeIfNecessary: true) as? NameCell)?.nameLabel
    } else {
      let path = IndexPath(item: index, section: 0)
      collection.scrollToItems(at: [path], scrollPosition: .top); collection.layoutSubtreeIfNeeded()
      field = (collection.item(at: path) as? IconItem)?.nameLabel
    }
    guard let field else { return }
    renamingEntry = entry; renameField = field; field.identifier = NSUserInterfaceItemIdentifier(entry.id)
    field.stringValue = entry.name; field.isEditable = true; field.isSelectable = true; field.isBordered = true; field.drawsBackground = true; field.backgroundColor = ExplorerPalette.surface; field.focusRingType = .none
    field.delegate = self; field.target = self; field.action = #selector(commitInlineRename)
    field.superview?.needsLayout = true; field.superview?.layoutSubtreeIfNeeded()
    view.window?.makeFirstResponder(field)
    let stem = entry.isDirectory || entry.url.pathExtension.isEmpty ? entry.name : entry.url.deletingPathExtension().lastPathComponent
    if let editor = field.currentEditor() as? NSTextView {
      if mode == .details, let font = field.font {
        let height = NSLayoutManager().defaultLineHeight(for: font)
        let centered = NSRect(x: 2, y: (field.bounds.height - height) / 2, width: editor.bounds.width, height: height)
        if let clip = editor.superview as? NSClipView {
          clip.frame = field.convert(centered, to: clip.superview)
          editor.frame = NSRect(origin: .zero, size: centered.size)
        }
      }
      editor.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
    }
  }
  private func cancelInlineRename() {
    guard let field = renameField else { renamingEntry = nil; return }
    renamingEntry = nil; renameField = nil; field.delegate = nil; field.target = nil; field.action = nil
    field.abortEditing(); field.isEditable = false; field.isSelectable = false; field.isBordered = false; field.drawsBackground = false; field.superview?.needsLayout = true
  }
  @objc private func commitInlineRename() {
    guard let entry = renamingEntry, let field = renameField, field.identifier?.rawValue == entry.id else { cancelInlineRename(); return }
    let name = field.stringValue
    cancelInlineRename(); view.window?.makeFirstResponder(mode == .details ? table : collection)
    guard name != entry.name else { render(); return }
    runSingle { try FileActions.rename(entry.url, to: name) }
  }
  func controlTextDidEndEditing(_ notification: Notification) {
    if let field = notification.object as? NSTextField, field === renameField { commitInlineRename() }
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if control === renameField && commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelInlineRename(); render(); view.window?.makeFirstResponder(mode == .details ? table : collection); return true }
    return false
  }
  private func readClipboard() {
    guard filePasteboard.changeCount != clipboardChange else { return }
    clipboard = (filePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    isCut = false
    if let data = filePasteboard.data(forType: Self.filesType), data.count <= 4 * 1024 * 1024,
       let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let paths = payload["paths"] as? [String], paths == clipboard.map(\.path), payload["cut"] as? Bool == true { isCut = true }
    clipboardChange = filePasteboard.changeCount
  }
  private func writeClipboard() {
    filePasteboard.clearContents()
    if !clipboard.isEmpty {
      filePasteboard.writeObjects(clipboard as [NSURL])
      if let data = try? JSONSerialization.data(withJSONObject: ["paths": clipboard.map(\.path), "cut": isCut]) { filePasteboard.setData(data, forType: Self.filesType) }
    }
    clipboardChange = filePasteboard.changeCount
  }
  private func copySelection(cut: Bool) {
    let sources = selectedEntries().map(\.url); guard !sources.isEmpty, !cut || !viewingTrash else { return }
    clipboard = sources; isCut = cut; writeClipboard(); render()
  }
  private func pasteFiles() {
    guard !busy, writable else { return }; readClipboard()
    let sources = clipboard, target = directory, move = isCut, version = clipboardChange
    guard !sources.isEmpty else { return }
    runTransferOperation(completion: { [weak self] result in
      guard let self, move, self.clipboardChange == version else { return }
      let moved = Set((result.consumedMoveSources + result.succeeded.filter { sources.contains($0) }).map(\.path))
      self.clipboard.removeAll { moved.contains($0.path) }; if self.clipboard.isEmpty { self.isCut = false }
      if self.filePasteboard.changeCount == version { self.writeClipboard() }
    }) { control in FileActions.transfer(sources, to: target, move: move, control: control) }
  }
  // Cached mount classification keeps menu/selection updates free of network I/O.
  var deletionNetworkLocation: (URL) -> Bool? = NativeFileFailure.networkLocation
  var prepareNetworkDeletion: @Sendable (URL) throws -> NetworkDeletion = { try NetworkDeletion($0) }
  private var deletionTitle: String {
    selectedEntries().contains { deletionNetworkLocation($0.url) == true } ? NL("删除") : NL("移到回收站")
  }
  private func trashSelected() {
    let sources = selectedEntries().map(\.url)
    guard !busy, !sources.isEmpty, !viewingTrash, let window = view.window else { return }
    let networkSources = Set(sources.filter { deletionNetworkLocation($0) == true })
    let perform: ([URL: NetworkDeletion]) -> Void = { [weak self, weak window] prepared in
      guard let self, let window else { return }
      if !prepared.isEmpty { self.redoChanges.removeAll() }
      self.readClipboard(); let version = self.clipboardChange
      let store = self.trashStore, cloud = self.cloudDrive, testTrash = self.testTrashDirectory
      let origin = self.tabs[self.activeTab].id, originDirectory = self.directory
      var removed = Set<String>()
      self.runAsyncOperation(selectResults: false, completion: { [weak self] result in
        guard let self else { return }
        if self.clipboardChange == version, self.filePasteboard.changeCount == version {
          self.clipboard.removeAll { removed.contains($0.path) }
          if self.clipboard.isEmpty { self.isCut = false }
          if !removed.isEmpty { self.writeClipboard() }
        }
        // A successful irreversible deletion has no destination to select.
        if let index = self.tabs.firstIndex(where: { $0.id == origin }), self.tabs[index].directory == originDirectory {
          self.tabs[index].selectedPaths = Set(sources.filter { !removed.contains($0.path) && !result.changes.compactMap(\.source).contains($0) }.map(\.path))
        }
      }) {
        var succeeded: [URL] = [], errors: [String] = [], changes: [FileActionChange] = []
        for source in sources {
          do {
            if let deletion = prepared[source] {
              try await Task.detached { try deletion.remove() }.value
              removed.insert(source.path)
            } else {
              // A local item becoming remote requires a fresh destructive confirmation.
              guard self.deletionNetworkLocation(source) != true else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE), userInfo: [NSFilePathErrorKey: source.path]) }
              let trashed: URL
              if let testTrash {
                let result = await Task.detached { FileActions.trash([source], testTrash: testTrash) }.value
                guard let change = result.changes.first else { throw NSError(domain: "NativeRecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: result.errors.joined(separator: "\n")]) }
                trashed = change.destination
              } else { trashed = try await self.recycleItem(source, cloud, window) }
              changes.append(FileActionChange(source: source, destination: trashed, kind: .trash)); succeeded.append(trashed); removed.insert(source.path)
              do { try store.remember(trashed, original: source) } catch { errors.append(NL("文件已移入回收站，但无法保存原位置。请使用“还原到…”恢复。")) }
            }
          } catch {
            var message = (error as NSError).code == NSUserCancelledError ? NL("已取消") : self.errorMessage(error, at: source)
            if prepared[source] != nil { message = NL("删除未完成，部分内容可能已删除。") + " " + message }
            errors.append(message.contains(source.lastPathComponent) ? message : message + "：" + source.lastPathComponent)
            if (error as NSError).code == NSUserCancelledError { break }
          }
        }
        return FileActionResult(succeeded: succeeded, errors: errors, changes: changes)
      }
    }
    if !networkSources.isEmpty {
      // Bind the confirmation to metadata captured off the UI thread, before deletion.
      let prepare = prepareNetworkDeletion, origin = tabs[activeTab].id, originDirectory = directory
      busy = true; operationError = nil; needsFullDiskAccess = false; updateStatus()
      Task { @MainActor [weak self, weak window] in
        do {
          let prepared = try await Task.detached { try Dictionary(uniqueKeysWithValues: networkSources.map { ($0, try prepare($0)) }) }.value
          guard let self else { return }; self.busy = false
          guard let window, !self.stopped else { self.updateStatus(); return }
          guard self.tabs[self.activeTab].id == origin, self.directory == originDirectory else { self.updateStatus(); return }
          self.updateStatus()
          let detail = sources.count == networkSources.count
            ? NL("永久删除网络驱动器上的 {0} 个项目？这些项目不会进入回收站，此操作无法撤销。", networkSources.count)
            : NL("永久删除 {0} 个网络项目，并将 {1} 个本地项目移到回收站？网络项目无法撤销删除。", networkSources.count, sources.count - networkSources.count)
          ExplorerDialogs.confirm(in: window, title: NL("删除"), detail: detail + "\n\n" + sources.prefix(5).map(\.path).joined(separator: "\n"), confirmTitle: NL("永久删除"), destructive: true) { perform(prepared) }
        } catch { self?.busy = false; self?.operationError = self?.errorMessage(error, at: sources.first); self?.render() }
      }
    } else if defaults.bool(forKey: "skipTrashConfirmation") { perform([:]) }
    else { ExplorerDialogs.confirm(in: window, title: NL("移到回收站"), detail: NL("将 {0} 个项目移到回收站？", sources.count), confirmTitle: NL("移到回收站"), remember: { [weak self] in self?.defaults.set($0, forKey: "skipTrashConfirmation") }) { perform([:]) } }
  }
  private func recordChanges(_ changes: [FileActionChange]) {
    guard !changes.isEmpty else { return }
    redoChanges.removeAll(); undoChanges.append(changes)
    if undoChanges.count > 100 { undoChanges.removeFirst(undoChanges.count - 100) }
  }
  @objc func undo(_ sender: Any?) {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }; return }
    undoFiles()
  }
  @objc func redo(_ sender: Any?) {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { if editor.undoManager?.canRedo == true { editor.undoManager?.redo() }; return }
    redoFiles()
  }
  @objc func undoFiles() { replayHistory(redo: false) }
  @objc func redoFiles() { replayHistory(redo: true) }
  private func replayHistory(redo: Bool) {
    guard !busy, view.window.map({ !ExplorerDialogs.isPresenting(in: $0) && $0.attachedSheet == nil }) == true else { return }
    guard let changes = redo ? redoChanges.popLast() : undoChanges.popLast() else { return }
    let testTrash = testTrashDirectory
    runTransferOperation(recordUndo: false, completion: { [weak self] result in
      guard let self else { return }
      // Replaying the recorded inverse restores the same object. It never recopies
      // a possibly changed original source or overwrites a newly occupied path.
      if !result.changes.isEmpty {
        if redo { self.undoChanges.append(result.changes) } else { self.redoChanges.append(result.changes) }
      }
      let completed = Set((result.changes.compactMap(\.source) + result.succeeded + result.consumedMoveSources).map(\.path))
      let remaining = changes.filter { !completed.contains($0.destination.path) }
      if !remaining.isEmpty {
        if redo { self.redoChanges.append(remaining) } else { self.undoChanges.append(remaining) }
      }
    }) { control in FileActions.undo(changes, testTrash: testTrash, control: control) }
  }
  private func runSingle(beginRename: Bool = false, _ operation: @escaping @Sendable () throws -> FileActionChange) {
    guard !busy else { return }; busy = true; operationError = nil; needsFullDiskAccess = false; message = NL("正在处理…"); updateStatus()
    let origin = tabs[activeTab].id, originDirectory = directory
    Task { @MainActor [weak self] in
      do {
        let change = try await Task.detached { try operation() }.value; guard let self else { return }
        self.recordChanges([change]); self.message = NL("已完成"); self.busy = false
        if let index = self.tabs.firstIndex(where: { $0.id == origin }), self.tabs[index].directory == originDirectory { self.tabs[index].selectedPaths = [change.destination.path] }
        if self.tabs[self.activeTab].id == origin && self.directory == originDirectory { self.pendingRename = beginRename ? change.destination.path : nil; self.reload() } else { self.updateStatus() }
      }
      catch { self?.busy = false; self?.operationError = self?.errorMessage(error); self?.message = ""; self?.render() }
    }
  }
  private func runOperation(recordUndo: Bool = true, completion: ((FileActionResult) -> Void)? = nil, _ operation: @escaping @Sendable () -> FileActionResult) {
    runAsyncOperation(recordUndo: recordUndo, completion: completion) { await Task.detached { operation() }.value }
  }
  func runAsyncOperation(recordUndo: Bool = true, selectResults: Bool = true, completion: ((FileActionResult) -> Void)? = nil, _ operation: @escaping () async -> FileActionResult) {
    guard !busy else { return }; busy = true; operationError = nil; needsFullDiskAccess = false; message = NL("正在处理…"); updateStatus()
    let origin = tabs[activeTab].id, originDirectory = directory
    Task { @MainActor [weak self] in
      let result = await operation(); guard let self else { return }
      if recordUndo { self.recordChanges(result.changes) }
      completion?(result)
      self.operationError = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
      self.busy = false; self.message = result.errors.isEmpty ? (result.transfers.contains { $0.method == .serverSideCopy } ? NL("已完成（服务端复制）") : NL("已完成")) : result.errors.prefix(2).joined(separator: "；")
      if selectResults, let index = self.tabs.firstIndex(where: { $0.id == origin }), self.tabs[index].directory == originDirectory { self.tabs[index].selectedPaths = Set(result.succeeded.map(\.path)) }
      if self.tabs[self.activeTab].id == origin && self.directory == originDirectory { self.reload() } else { self.updateStatus() }
    }
  }
  private func sendAirDrop() { let urls = selectedEntries().map(\.url); guard !urls.isEmpty else { return }; NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls) }
  private func openTerminal(at url: URL? = nil) {
    let selected = selectedEntries(); let target = url ?? (selected.count == 1 && selected[0].isDirectory ? selected[0].url : directory)
    do {
      let request = try NativeTerminal.request(directory: target, selected: defaults.string(forKey: NativeTerminal.preferenceKey) ?? "")
      NSWorkspace.shared.open([request.directory], withApplicationAt: request.application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
        if let error { DispatchQueue.main.async { self?.lastError = error.localizedDescription; self?.render() } }
      }
    } catch { lastError = error.localizedDescription; render() }
  }
  private func shareSelected() { let urls = selectedEntries().map(\.url); guard !urls.isEmpty, let button = commands["share"] else { return }; NSSharingServicePicker(items: urls).show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
  private func openSystemLocation(_ name: String) {
    if name == "airdrop" { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")) }
    else { askName(title: NL("连接服务器"), value: "smb://") { [weak self] value in self?.connectServer(value) } }
  }
  private func connectServer(_ address: String) {
    guard !busy else { return }
    Task { @MainActor [weak self] in
      do { if let destination = try await NativeNetwork.shared.connection(address) { self?.navigate(to: destination) } }
      catch { self?.operationError = error.localizedDescription; self?.render() }
    }
  }
  private func ejectVolume(_ url: URL) {
    guard !busy else { return }
    Task { @MainActor [weak self] in
      do { _ = try await Task.detached { try NativeVolumes.eject(url) }.value; self?.rebuildSidebar(); if self?.directory == url { self?.navigate(to: URL(string: "explorer://computer")!) } }
      catch { self?.operationError = error.localizedDescription; self?.render() }
    }
  }
  private func showProperties() {
    let chosen = selectedEntries(); guard let entry = chosen.first, let window = view.window else { return }
    let urls = chosen.map(\.url), selection = selectedPaths
    let title = chosen.count == 1 ? entry.name : NL("{0} 个项目", chosen.count)
    let location = Set(urls.map { $0.deletingLastPathComponent().path }).sorted().joined(separator: "、")
    let initial = [(NL("类型"), chosen.count == 1 ? entry.kind : NL("多个项目")), (NL("位置"), location), (NL("大小"), NL("正在计算…"))]
    var expectedIdentity: String?
    let rename: ((String) -> Void)? = chosen.count == 1 && !viewingTrash ? { [weak self] name in
      guard let self, let expected = expectedIdentity else { return }
      self.runSingle { try FileActions.rename(entry.url, to: name, expectedIdentity: expected) }
    } : nil
    let present: (NSImage) -> Void = { [weak self, weak window] icon in
      guard let self, let window, window.isVisible, self.selectedPaths == selection else { return }
      ExplorerDialogs.properties(in: window, title: title, icon: icon, values: initial, rename: rename, load: {
        let task = Task.detached(priority: .utility) { try FilePropertiesReader.read(urls) }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        var values = Array(initial.prefix(2)) + [(NL("大小"), ExplorerFormat.size(result.size)), (NL("占用空间"), ExplorerFormat.size(result.allocated) + NL("（{0} 字节）", result.allocated.formatted(.number.locale(NativeLanguage.formatLocale))))]
        if chosen.count > 1 || entry.isDirectory { values.append((NL("包含"), NL("{0} 个文件，{1} 个文件夹", result.files, result.folders))) }
        if chosen.count == 1 { values += [(NL("创建日期"), result.created.map(self.dateFormatter.string) ?? "—"), (NL("修改日期"), result.modified.map(self.dateFormatter.string) ?? "—")] }
        if let readOnly = result.readOnly { values.append((NL("只读"), readOnly ? NL("是") : NL("否"))) }
        if chosen.count == 1 { values.append((NL("隐藏"), entry.isHidden ? NL("是") : NL("否"))) }
        if result.skipped > 0 { values.append((NL("状态"), NL("{0} 个项目无法读取，统计不完整", result.skipped))) }
        expectedIdentity = result.metadata?.identity
        var details = [(NL("位置"), location), (NL("类型"), chosen.count == 1 ? entry.kind : NL("多个项目"))]
        var permissions: [(String, String)] = []
        if let metadata = result.metadata {
          details += [(NL("完整路径"), entry.url.path), (NL("扩展名"), entry.url.pathExtension.isEmpty ? "—" : entry.url.pathExtension), (NL("访问日期"), self.dateFormatter.string(from: metadata.accessed)), (NL("硬链接数"), String(metadata.hardLinks))]
          if let target = metadata.linkTarget { details.append((NL("链接目标"), target)) }
          permissions = [(NL("所有者 UID"), String(metadata.owner)), (NL("组 GID"), String(metadata.group)), (NL("POSIX 权限"), metadata.permissions)]
          if let readOnly = result.readOnly { permissions.append((NL("当前用户可写"), readOnly ? NL("否") : NL("是"))) }
        } else { permissions = [(NL("状态"), NL("选择单个项目查看权限"))] }
        return EDPropertyValues(general: values, details: details, permissions: permissions)
      })
    }
    if entry.isDirectory || chosen.count > 1 { present(ExplorerIcons.folder(size: 42, url: chosen.count == 1 ? entry.url : nil)) } else { _ = IconLoader.shared.request(entry, pixels: 128, completion: present) }
  }
  private func showSettings(initialTab: Int = 0) {
    guard let window = view.window else { return }
    let rows = ExplorerShortcuts.actions.map { ($0.title, ExplorerShortcuts.bindings($0.id, overrides: shortcutOverrides).joined(separator: " / ")) }
    let shortcutDefaults = Dictionary(uniqueKeysWithValues: ExplorerShortcuts.actions.map { ($0.title, $0.defaults.joined(separator: " / ")) })
    let folder = defaults.dictionary(forKey: "defaultFolderView") ?? [:]
    let folderSettings = ["view": folder["view"] as? String ?? "icons", "iconSize": String(folder["iconSize"] as? Int ?? 64), "sort": folder["sort"] as? String ?? "name", "ascending": String(folder["ascending"] as? Bool ?? true)]
    ExplorerDialogs.settings(in: window, theme: defaults.string(forKey: "theme") ?? "light", onTheme: { [weak self] in self?.setAppearance($0) }, toolbar: toolbarOrder, onToolbar: { [weak self] order in
      guard let self else { return }; self.toolbarOrder = order.filter { self.commands[$0] != nil }; self.defaults.set(self.toolbarOrder, forKey: "toolbar"); self.view.needsLayout = true
    }, shortcutRows: rows, onShortcut: { [weak self] title, binding in
      guard let self, let action = ExplorerShortcuts.actions.first(where: { $0.title == title }) else { return }
      guard binding.isEmpty || binding != self.defaults.string(forKey: "wakeShortcut") else { self.operationError = NL("快捷键与唤醒快捷键冲突。"); self.render(); return }
      self.shortcutOverrides[action.id] = binding == action.defaults.joined(separator: " / ") ? nil : ExplorerShortcuts.normalize(binding); self.defaults.set(self.shortcutOverrides, forKey: "shortcuts"); self.syncMenuShortcuts()
    }, shortcutDefaults: shortcutDefaults, folderDefaults: folderSettings, onFolderDefaults: { [weak self] values in
      guard let self else { return }
      var updated = self.defaults.dictionary(forKey: "defaultFolderView") ?? [:]
      updated.merge(["view": values["view"] ?? "icons", "iconSize": Int(values["iconSize"] ?? "64") ?? 64, "sort": values["sort"] ?? "name", "ascending": values["ascending"] != "false"]) { _, new in new }
      self.defaults.set(updated, forKey: "defaultFolderView")
      if self.savedFolderViews[self.directory.path] == nil { self.restoreView(self.directory); self.updateMode(persist: false) }
    }, onResetFolders: { [weak self] in
      guard let self else { return }; self.savedFolderViews = [:]; self.defaults.removeObject(forKey: "folderViews"); self.restoreView(self.directory); self.updateMode(persist: false)
    }, browser: self, initialTab: initialTab)
  }
  private func setAppearance(_ mode: String) { defaults.set(mode, forKey: "theme"); NSApp.appearance = mode == "system" ? nil : NSAppearance(named: mode == "dark" ? .darkAqua : .aqua); view.needsDisplay = true; table.reloadData(); collection.reloadData() }
  private func handleKey(_ event: NSEvent) -> NSEvent? {
    guard event.window === view.window else { return event }
    if event.type == .scrollWheel {
      guard !automaticRefreshBlocked, !(view.window?.firstResponder is NSTextView) else { return event }
      if event.modifierFlags.contains(.control), mode == .icons, content.bounds.contains(content.convert(event.locationInWindow, from: nil)), event.scrollingDeltaY != 0 {
        iconSize = min(128, max(32, iconSize + (event.scrollingDeltaY > 0 ? 8 : -8))); updateMode(); return nil
      }
      return event
    }
    if renamingEntry != nil || view.window.map({ ExplorerDialogs.isPresenting(in: $0) || $0.attachedSheet != nil }) == true { return event }
    let fixed: [String: () -> Void] = [
      "Command+Shift+H": { [weak self] in if let self { self.navigate(to: self.home) } },
      "Command+Shift+D": { [weak self] in if let self { self.navigate(to: self.home.appendingPathComponent("Desktop")) } },
      "Command+Shift+O": { [weak self] in if let self { self.navigate(to: self.home.appendingPathComponent("Documents")) } },
      "Command+Alt+L": { [weak self] in if let self { self.navigate(to: self.home.appendingPathComponent("Downloads")) } },
      "Command+Shift+C": { [weak self] in self?.navigate(to: URL(string: "explorer://computer")!) },
      "Command+Alt+S": { [weak self] in guard let self else { return }; self.navigationPane.toggle(); self.defaults.set(self.navigationPane, forKey: "navigationPane"); self.view.needsLayout = true },
    ]
    if let action = fixed[ExplorerShortcuts.key(event)] { action(); return nil }
    let editing = view.window?.firstResponder is NSTextView
    guard let action = ExplorerShortcuts.match(event, overrides: shortcutOverrides) else {
      if !editing, ExplorerShortcuts.actions.contains(where: { shortcutOverrides[$0.id] != nil && $0.defaults.contains(ExplorerShortcuts.key(event)) }) { return nil }
      return event
    }
    if !directory.isFileURL && ["rename", "open", "select-all"].contains(action) { return event }
    let global = ["address", "search", "new-tab", "close-tab", "next-tab", "previous-tab", "last-tab"]
    if editing && !global.contains(action) && !action.hasPrefix("tab-") { return event }
    executeAction(action); return nil
  }
  func executeAction(_ action: String) {
    switch action {
    case "about": showSettings(initialTab: 3)
    case "settings": showSettings()
    case "properties": showProperties()
    case "rename": renameSelected()
    case "open": openSelected()
    case "copy": copySelection(cut: false)
    case "cut": copySelection(cut: true)
    case "paste": pasteFiles()
    case "undo": undoFiles()
    case "redo": redoFiles()
    case "move-here":
      clipboard = (filePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []; clipboardChange = filePasteboard.changeCount; isCut = true; pasteFiles()
    case "duplicate": guard writable else { return }; let sources = selectedEntries().map(\.url), target = directory; runTransferOperation { control in FileActions.transfer(sources, to: target, move: false, control: control) }
    case "select-all": selectAllFiles()
    case "new-folder": createEntry(directory: true)
    case "trash": trashSelected()
    case "quick-look": previewSelected()
    case "back": back()
    case "forward": forward()
    case "parent": if directory.isFileURL { up() }
    case "address": focusAddress()
    case "search": focusSearch()
    case "new-tab": newTab()
    case "close-tab": closeTab()
    case "next-tab": switchTab(to: (activeTab + 1) % tabs.count)
    case "previous-tab": switchTab(to: (activeTab - 1 + tabs.count) % tabs.count)
    case "last-tab": switchTab(to: tabs.count - 1)
    case "extra-large-icons": setView(.icons, size: 128)
    case "icons": setView(.icons, size: 64)
    case "medium-icons": setView(.icons, size: 48)
    case "small-icons": setView(.icons, size: 32)
    case "list": setView(.list)
    case "details": setView(.details)
    case "tiles": setView(.tiles)
    case "content": setView(.content)
    case "preview": togglePane("preview")
    case "details-pane": togglePane("details")
    case "hidden": toggleHidden()
    case "refresh": IconLoader.shared.clear(); reload()
    default: if action.hasPrefix("tab-"), let number = Int(action.dropFirst(4)) { switchTab(to: number - 1) }
    }
  }
  private func shortcutHint(_ action: String) -> String { ExplorerShortcuts.bindings(action, overrides: shortcutOverrides).first.map(ExplorerShortcuts.display) ?? "" }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
      if menuItem.action == #selector(undo(_:)) { return editor.undoManager?.canUndo == true }
      if menuItem.action == #selector(redo(_:)) { return editor.undoManager?.canRedo == true }
    }
    if let window = view.window, ExplorerDialogs.isPresenting(in: window) { return false }
    switch menuItem.action {
    case #selector(openSelected): return selectedPaths.count == 1
    case #selector(previewSelected), #selector(revealSelected), #selector(copyPaths): return !selectedPaths.isEmpty
    case #selector(back): return tabs[activeTab].index > 0
    case #selector(forward): return tabs[activeTab].index + 1 < tabs[activeTab].history.count
    case #selector(undo(_:)): return !busy && !undoChanges.isEmpty
    case #selector(redo(_:)): return !busy && !redoChanges.isEmpty
    case #selector(up): return directory.isFileURL && directory.path != "/"
    default: return true
    }
  }
  func syncMenuShortcuts() {
    let mapping: [Selector: String] = [#selector(undo(_:)): "undo", #selector(redo(_:)): "redo", #selector(newTab): "new-tab", #selector(closeTab as () -> Void): "close-tab", #selector(openSelected): "open", #selector(previewSelected): "quick-look", #selector(back): "back", #selector(forward): "forward", #selector(up): "parent", #selector(focusAddress): "address", #selector(focusSearch): "search", #selector(reload): "refresh"]
    for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
      for item in menu.items {
        guard let action = item.action, let id = mapping[action] else { continue }
        guard let binding = ExplorerShortcuts.bindings(id, overrides: shortcutOverrides).first(where: { $0.contains("+") }) else { item.keyEquivalent = ""; continue }
        let parts = binding.split(separator: "+").map(String.init); let last = parts.last ?? ""
        let keys = ["Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey, "Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey]
        item.keyEquivalent = keys[last].flatMap(UnicodeScalar.init).map(String.init) ?? last.lowercased()
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("Command") { flags.insert(.command) }; if parts.contains("Control") { flags.insert(.control) }; if parts.contains("Alt") { flags.insert(.option) }; if parts.contains("Shift") { flags.insert(.shift) }
        item.keyEquivalentModifierMask = flags
      }
    }
    for (id, button) in commands { button.toolTip = (ExplorerShortcuts.actions.first { $0.id == id }?.title ?? button.toolTip ?? id) + " " + shortcutHint(id) }
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
    guard entries.indices.contains(row) else { return nil }; return entries[row].url as NSURL
  }
  func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
    guard entries.indices.contains(indexPath.item) else { return nil }; return entries[indexPath.item].url as NSURL
  }
  private func dropOperation(_ info: NSDraggingInfo, target: URL? = nil) -> NSDragOperation {
    let acceptsTarget: Bool
    if let target { acceptsTarget = target.isFileURL && target.path != home.appendingPathComponent(".Trash").path && !target.path.hasPrefix(home.appendingPathComponent(".Trash").path + "/") && !target.pathComponents.contains(".Trashes") }
    else { acceptsTarget = writable }
    guard !busy, acceptsTarget, info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
    return NSEvent.modifierFlags.contains(.option) || !info.draggingSourceOperationMask.contains(.move) ? .copy : .move
  }
  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
    if entries.indices.contains(row), entries[row].isDirectory, !entries[row].isPackage { tableView.setDropRow(row, dropOperation: .on) }
    else { tableView.setDropRow(-1, dropOperation: .on) }
    return dropOperation(info)
  }
  func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
    let target = entries.indices.contains(row) && entries[row].isDirectory && !entries[row].isPackage ? entries[row].url : directory
    return acceptFiles(info, at: target)
  }
  func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath index: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation operation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
    let row = index.pointee.item
    operation.pointee = entries.indices.contains(row) && entries[row].isDirectory && !entries[row].isPackage ? .on : .before
    return dropOperation(info)
  }
  func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation operation: NSCollectionView.DropOperation) -> Bool {
    let row = indexPath.item
    let target = operation == .on && entries.indices.contains(row) && entries[row].isDirectory && !entries[row].isPackage ? entries[row].url : directory
    return acceptFiles(info, at: target)
  }
  private func acceptFiles(_ info: NSDraggingInfo, at target: URL, fromTab: Bool = false) -> Bool {
    let operation = dropOperation(info, target: fromTab ? target : nil)
    let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard !urls.isEmpty, !operation.isEmpty else { return false }
    runTransferOperation { control in FileActions.transfer(urls, to: target, move: operation == .move, control: control) }; return true
  }
  func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { reload() }
  func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) { reload() }

  private func errorMessage(_ error: Error, at context: URL? = nil) -> String {
    let failure = NativeFileFailure.describe(error, at: context ?? directory, networkLocation: fileErrorNetworkLocation)
    needsFullDiskAccess = failure.offersPrivacySettings
    return failure.message
  }

  deinit { vcsTimer?.invalidate(); if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; preferencesWork?.cancel(); if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }; loadTask?.cancel(); queryTask?.cancel(); searchTask?.cancel(); automaticRead?.cancel(); refreshWork?.cancel(); if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; if let paletteObserver { NotificationCenter.default.removeObserver(paletteObserver) }; if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }
}


extension BrowserController {
  func importFinderFavorites() async throws -> String {
    let result = try await Task.detached { try FinderFavoritesReader.read() }.value
    let count = places.merge(result.places, defaultPaths: defaultPlaces.map { $0.0.path }, excludedPaths: Set([home.path, cloudDrive?.path].compactMap { $0 }))
    savePlaces()
    return (count > 0 ? NL("已导入 {0} 项", count) : result.places.isEmpty ? NL("未找到收藏夹") : NL("没有新增收藏夹")) + (result.skipped > 0 ? NL(" · 跳过 {0} 项", result.skipped) : "")
  }
  func importFinderServers() async throws -> String {
    let result = try await Task.detached { try FinderServersReader.read() }.value
    let count = try NativeServerFavorites.merge(result.servers, into: defaults)
    return (count > 0 ? NL("已导入 {0} 项", count) : result.servers.isEmpty ? NL("未找到收藏的 SMB 服务器") : NL("没有新增服务器")) + (result.skipped > 0 ? NL(" · 跳过 {0} 项", result.skipped) : "")
  }
  private func openWithMenu(_ urls: [URL]) -> ExplorerMenuItem {
    guard !urls.isEmpty else { return ExplorerMenuItem(title: NL("打开方式"), enabled: false) }
    let choose = ExplorerMenuItem(title: NL("选择其他应用"), icon: "applications", action: { [weak self] in self?.chooseApplication(urls) })
    return ExplorerMenuItem(title: NL("打开方式"), icon: "applications", children: [ExplorerMenuItem(title: NL("正在读取…"), enabled: false), choose], loadChildren: { [weak self] in
      let task = Task.detached(priority: .userInitiated) { NativeOpenWith.applications(urls) }
      let applications = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
      guard !Task.isCancelled else { return [] }
      var items = applications.map { app in ExplorerMenuItem(title: app.name + (app.isDefault ? NL("（默认）") : ""), applicationImage: NSWorkspace.shared.icon(forFile: app.url.path), action: { [weak self] in self?.open(urls, with: app.url) }) }
      var choose = choose; choose.divider = !items.isEmpty; items.append(choose); return items
    })
  }
  private func chooseApplication(_ urls: [URL]) {
    guard let window = view.window else { return }
    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.title = NL("选择其他应用"); panel.prompt = NL("打开")
    panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let app = panel.url { self?.open(urls, with: app) } }
  }
  private func open(_ urls: [URL], with application: URL) {
    NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
      if let error { DispatchQueue.main.async { self?.operationError = error.localizedDescription; self?.render() } }
    }
  }
  private func openAsText(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-n", "-b", "com.apple.TextEdit"] + urls.map(\.path) + ["--args", "-IgnoreHTML", "YES", "-IgnoreRichText", "YES"]
    do { try process.run() } catch { operationError = error.localizedDescription; render() }
  }
}


extension BrowserController {
  var trashStore: TrashStore {
    let roots: [URL]
    if let testTrashDirectory { roots = [testTrashDirectory] }
    else {
      roots = [home.appendingPathComponent(".Trash")] + (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []).filter { $0.path.hasPrefix("/Volumes/") }.map { $0.appendingPathComponent(".Trashes/\(getuid())") }
    }
    let records = testTrashDirectory?.deletingLastPathComponent().appendingPathComponent("native-trash-origins") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mac Explorer Native/trash-origins")
    return TrashStore(roots: roots, records: records)
  }
  private func restoreFromTrash(choose: Bool) {
    let urls = selectedEntries().map(\.url); guard !urls.isEmpty, let window = view.window, !busy else { return }
    let store = trashStore
    if choose {
      let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = NL("还原到此处")
      panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let destination = panel.url { self?.runTransferOperation(recordUndo: false, completion: { [weak self] result in if !result.succeeded.isEmpty { self?.redoChanges.removeAll() } }) { control in store.restore(urls, to: destination, control: control) } } }
    } else { runTransferOperation(recordUndo: false, completion: { [weak self] result in if !result.succeeded.isEmpty { self?.redoChanges.removeAll() } }) { control in store.restore(urls, control: control) } }
  }
  private func emptySystemTrash() {
    guard !busy, let window = view.window else { return }
    let store = trashStore
    do {
      let snapshot = try store.snapshot(); guard !snapshot.isEmpty else { return }
      ExplorerDialogs.confirm(in: window, title: NL("清空回收站"), detail: NL("永久删除 {0} 个项目？此操作无法撤销。", snapshot.count), confirmTitle: NL("永久删除")) { [weak self] in self?.runOperation(recordUndo: false, completion: { [weak self] _ in self?.redoChanges.removeAll() }) { store.empty(snapshot) } }
    } catch { operationError = error.localizedDescription; render() }
  }
}


extension BrowserController {
  func changeLanguage(_ mode: String) { onLanguageChange?(mode) }
  func copySession(from source: BrowserController) {
    source.rememberLocationState()
    tabs = source.tabs; activeTab = source.activeTab; home = source.home
    prepareLocationState(tabs[activeTab].locationStates[tabs[activeTab].index] ?? BrowserLocationState(selection: selectedPaths))
    testTrashDirectory = source.testTrashDirectory; filePasteboard = source.filePasteboard
    undoChanges = source.undoChanges; redoChanges = source.redoChanges; paneMode = source.paneMode; operationError = source.operationError
    restoreView(directory)
  }
}


extension BrowserController {
  func setVersionControl(_ enabled: Bool) {
    defaults.set(enabled, forKey: "versionControl"); versionControl?.setEnabled(enabled)
    NotificationCenter.default.post(name: Self.placesChanged, object: defaults)
    refreshVCS(force: true)
  }
  private func refreshVCS(force: Bool = false) {
    guard !stopped, force || vcsReads == 0 else { return }
    vcsGeneration += 1; let token = vcsGeneration, target = directory
    guard let service = versionControl, service.isEnabled, target.isFileURL, !viewingTrash else { vcsStatus = nil; for index in entries.indices { entries[index].vcsMark = nil }; render(); return }
    vcsReads += 1
    Task { @MainActor [weak self] in
      defer { self?.vcsReads -= 1 }
      do {
        let state = try await Task.detached(priority: .utility) { try service.status(directory: target, force: force) }.value
        guard let self, self.directory == target, self.vcsGeneration == token, !self.stopped, service.isEnabled else { return }
        guard self.vcsStatus != state || self.entries.contains(where: { $0.vcsMark != state?.statesByPath[$0.id]?.mark }) else { return }
        self.vcsStatus = state
        for index in self.entries.indices { self.entries[index].vcsMark = state?.statesByPath[self.entries[index].id]?.mark }
        if let error = state?.error { self.operationError = error }
        self.render()
      } catch { guard let self, self.directory == target, self.vcsGeneration == token, service.isEnabled else { return }; self.operationError = error.localizedDescription; self.render() }
    }
  }
  private func showVCS(_ action: NativeVCSAction) {
    guard let service = versionControl, let window = view.window else { return }
    NativeVCSWindow.present(service: service, directory: directory, paths: selectedEntries().map(\.url), action: action, parent: window) { [weak self] in self?.reload(); self?.refreshVCS(force: true) }
  }
  private func acceptExternalResult(_ result: FileActionResult) {
    recordChanges(result.changes)
    operationError = result.errors.isEmpty ? nil : result.errors.joined(separator: "\n")
    message = result.errors.isEmpty ? NL("已完成") : ""; reload()
  }
  private func compressSelection() {
    let urls = selectedEntries().map(\.url); guard !urls.isEmpty, !busy, !viewingTrash else { return }
    runSingle { let output = try NativeArchives.compress(urls); return FileActionChange(source: nil, destination: output, kind: .create) }
  }
  private func extract(_ archive: URL, mode: String) {
    guard !busy, let window = view.window else { return }
    let perform: (URL) -> Void = { [weak self] destination in
      self?.runOperation {
        do { return try NativeArchives.extract(archive, to: destination, namedFolder: mode == "folder") }
        catch { return FileActionResult(succeeded: [], errors: [error.localizedDescription], changes: []) }
      }
    }
    if mode == "choose" {
      let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = NL("解压到此处")
      panel.beginSheetModal(for: window) { if $0 == .OK, let directory = panel.url { perform(directory) } }
    } else { perform(archive.deletingLastPathComponent()) }
  }
}


extension BrowserController {
  func openExternal(_ url: URL) {
    guard url.isFileURL, !url.path.contains("\0"), let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return }
    if values.isDirectory == true { navigate(to: url) }
    else { navigate(to: url.deletingLastPathComponent()); selectedPaths = [url.path] }
  }
}


extension BrowserController {
  func restoreLocations(_ locations: [String]) {
    var seen = Set<String>()
    let urls = [home] + locations.compactMap(NativeSessions.validLocation).filter { $0 != home }
    tabs = urls.filter { seen.insert($0.absoluteString).inserted }.map { BrowserTab(history: [$0]) }
    activeTab = 0; prepareLocationState(BrowserLocationState()); restoreView(home, touch: true)
    if isViewLoaded { reload() }
  }
}
