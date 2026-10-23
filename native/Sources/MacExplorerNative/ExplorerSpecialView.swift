import AppKit
import ExplorerCore

typealias ExplorerVolume = NativeVolume

final class ExplorerSpecialView: SurfaceView, NetServiceBrowserDelegate, NetServiceDelegate, NSTextFieldDelegate {
  var onNavigate: ((URL) -> Void)?
  // Retained for source compatibility; connections are handled by the Native service.
  var onConnect: ((String) -> Void)?
  var onVolumesChanged: (() -> Void)?
  private var connectionTask: Task<Void, Never>?
  private var ejecting = Set<String>()
  private let defaults: UserDefaults
  private var favoritesObserver: NSObjectProtocol?
  private var favoriteRows: [NetworkDeviceRow] = []
  private let favoritesTitle = label(NL("收藏的服务器"), size: 14)
  private var mode = ""
  private var query = ""
  private var revision = 0
  private var volumeRequest = 0
  private var volumeError: String?
  private let volumeLoader: () async throws -> [NativeVolume]
  private let discoveryEnabled: Bool
  private let volumeStatus = label("", color: ExplorerPalette.secondary)
  private let scroll = NSScrollView(), document = SurfaceView()
  private let heading = label("", size: 20)
  private let choose = EDButton(title: NL("选择文件…"), style: .primary)
  private let server = NSTextField(string: "smb://")
  private let connect = EDButton(title: NL("连接"), style: .primary)
  private let refresh = EDButton(title: NL("重新查找"), style: .secondary)
  private let serverTitle = label(NL("服务器地址"), size: 13)
  private let mountedTitle = label(NL("已连接的共享"), size: 14)
  private let discoveredTitle = label(NL("附近的共享电脑"), size: 14)
  private let emptyIcon = NSImageView()
  private let networkStatus = label("", color: ExplorerPalette.secondary)
  private var discovery = NetServiceBrowser()
  private var services: [NetService] = []
  private var volumes: [ExplorerVolume] = []
  private var cards: [DriveCard] = []
  private var serviceRows: [NetworkDeviceRow] = []
  private var mountedRows: [NetworkDeviceRow] = []
  private let dropArea = AirDropTarget()
  private let airDrop: AirDropDiscovering
  private var airDropCards: [AirDropDeviceCard] = []
  private var airDropSettled = false
  private var windowCloseObserver: NSObjectProtocol?

  init(frame: NSRect = .zero, defaults: UserDefaults = .standard, airDrop: AirDropDiscovering = NativeAirDrop(), volumeLoader: @escaping () async throws -> [NativeVolume] = { try await Task.detached { try NativeVolumes.list() }.value }, discoveryEnabled: Bool = true) {
    self.defaults = defaults; self.airDrop = airDrop; self.volumeLoader = volumeLoader; self.discoveryEnabled = discoveryEnabled
    super.init(frame: frame)
    scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.automaticallyAdjustsContentInsets = false
    addSubview(scroll)
    [heading, dropArea, choose, server, connect, refresh, networkStatus, volumeStatus, serverTitle, mountedTitle, discoveredTitle, favoritesTitle, emptyIcon].forEach(document.addSubview)
    heading.font = .systemFont(ofSize: 20, weight: .medium)
    server.font = .systemFont(ofSize: 13); server.placeholderString = NL("smb://服务器/共享"); server.bezelStyle = .roundedBezel
    server.delegate = self; refresh.iconName = "refresh"
    emptyIcon.image = ExplorerIcons.image("network", size: 32, color: ExplorerPalette.accent); emptyIcon.isHidden = true
    server.target = self; server.action = #selector(connectServer)
    choose.onPress = { [weak self] in self?.chooseFiles() }; connect.onPress = { [weak self] in self?.connectServer() }
    refresh.onPress = { [weak self] in guard let self else { return }; if self.mode == "airdrop" { self.discoverAirDrop() } else { self.discover(); self.loadVolumes(token: self.revision) } }
    dropArea.onFiles = { [weak self] in self?.share($0) }
    discovery.delegate = self
    favoritesObserver = NotificationCenter.default.addObserver(forName: NativeServerFavorites.didChange, object: defaults, queue: .main) { [weak self] _ in self?.updateFavorites() }
  }
  required init?(coder: NSCoder) { fatalError() }
  func show(_ name: String) {
    mode = name; query = ""; revision += 1; let token = revision
    volumes = []; volumeError = nil; volumeStatus.stringValue = ""; volumeStatus.isHidden = true
    connectionTask?.cancel(); connectionTask = nil; setConnecting(false)
    stopDiscovery(); cards.forEach { $0.removeFromSuperview() }; cards.removeAll(); serviceRows.forEach { $0.removeFromSuperview() }; serviceRows.removeAll(); mountedRows.forEach { $0.removeFromSuperview() }; mountedRows.removeAll()
    airDropCards.forEach { $0.removeFromSuperview() }; airDropCards.removeAll()
    heading.stringValue = name == "computer" ? NL("设备和驱动器") : name == "airdrop" ? NL("隔空投送") : NL("网络")
    dropArea.isHidden = name != "airdrop"; choose.isHidden = name != "airdrop"
    for control in [server, connect, refresh, serverTitle, mountedTitle, discoveredTitle] { control.isHidden = name != "network" }
    refresh.isHidden = name == "computer"; discoveredTitle.isHidden = name == "computer"
    discoveredTitle.stringValue = name == "airdrop" ? NL("附近设备") : NL("附近的共享电脑")
    networkStatus.isHidden = false; networkStatus.stringValue = ""
    if name == "airdrop" { discoverAirDrop() }
    updateFavorites()
    if name == "network" { discover() }
    if name == "computer" || name == "network" { loadVolumes(token: token) }

    needsLayout = true
  }
  private func loadVolumes(token: Int) {
    volumeRequest += 1; let request = volumeRequest, loader = volumeLoader
    Task { @MainActor [weak self] in
      do {
        let volumes = try await loader()
        guard let self, self.revision == token, self.volumeRequest == request else { return }; self.volumeError = nil; self.volumes = volumes; self.updateVolumes(); self.needsLayout = true
      } catch {
        guard let self, self.revision == token, self.volumeRequest == request else { return }; self.volumes = []; self.volumeError = NL("无法读取已挂载的磁盘。"); self.updateVolumes(); self.needsLayout = true
      }
    }
  }
  private func eject(_ volume: ExplorerVolume) {
    guard !ejecting.contains(volume.path) else { return }; ejecting.insert(volume.path)
    cards.first(where: { $0.volume.path == volume.path })?.isEjecting = true
    let token = revision
    Task { @MainActor [weak self] in
      do {
        let volumes = try await Task.detached { try NativeVolumes.eject(volume.url) }.value
        guard let self else { return }; self.ejecting.remove(volume.path); self.onVolumesChanged?()
        guard self.revision == token else { return }; self.volumeError = nil; self.volumes = volumes; self.updateVolumes(); self.needsLayout = true
      } catch {
        guard let self else { return }; self.ejecting.remove(volume.path)
        guard self.revision == token else { return }; self.networkStatus.stringValue = NL(error.localizedDescription)
        self.cards.first(where: { $0.volume.path == volume.path })?.isEjecting = false
      }
    }
  }
  private func stopDiscovery() {
    airDrop.onChange = nil; airDrop.stop()
    discovery.delegate = nil; discovery.stop()
    for service in services { service.delegate = nil; service.stop() }; services.removeAll()
  }
  private func discoverAirDrop() {
    revision += 1; let token = revision
    airDropSettled = false
    updateAirDrop([], error: nil)
    airDrop.onChange = { [weak self] names, error in
      guard let self, self.revision == token else { return }
      self.updateAirDrop(names, error: error)
    }
    airDrop.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, self.revision == token, self.mode == "airdrop", !self.isHidden else { return }
      self.airDropSettled = true
      if self.airDropCards.isEmpty && self.networkStatus.stringValue == NL("正在查找附近设备…") { self.networkStatus.stringValue = NL("未发现附近设备") }
    }
  }
  private func updateAirDrop(_ names: [String], error: AirDropDiscoveryError?) {
    guard mode == "airdrop" else { return }
    airDropCards.forEach { $0.removeFromSuperview() }; airDropCards.removeAll()
    for name in names {
      let card = AirDropDeviceCard(name: name.isEmpty ? NL("未命名设备") : name)
      document.addSubview(card); airDropCards.append(card)
    }
    networkStatus.stringValue = error != nil ? NL("无法查找附近设备") : names.isEmpty ? (airDropSettled ? NL("未发现附近设备") : NL("正在查找附近设备…")) : NL("{0} 台设备", names.count)
    needsLayout = true
  }
  override var isHidden: Bool {
    didSet {
      if isHidden, !oldValue { revision += 1; stopDiscovery(); connectionTask?.cancel(); connectionTask = nil; setConnecting(false) }
    }
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }; windowCloseObserver = nil
    if let newWindow {
      windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { [weak self] _ in
        guard let self else { return }; self.revision += 1; self.stopDiscovery(); self.connectionTask?.cancel(); self.connectionTask = nil
      }
    }
    if newWindow == nil { revision += 1; stopDiscovery(); connectionTask?.cancel(); connectionTask = nil }
    super.viewWillMove(toWindow: newWindow)
  }
  private func updateVolumes() {
    guard mode == "computer" || mode == "network" else { return }
    cards.forEach { $0.removeFromSuperview() }; cards.removeAll()
    mountedRows.forEach { $0.removeFromSuperview() }; mountedRows.removeAll()
    volumeStatus.stringValue = volumeError ?? ""; volumeStatus.isHidden = mode != "network" || volumeError == nil
    if mode == "computer" { networkStatus.stringValue = volumeError ?? "" }
    let visible = volumes.filter { (mode == "computer" || $0.isNetwork) && matches($0.name, $0.path) }
    if mode == "network" {
      for volume in visible {
        let row = NetworkDeviceRow(name: volume.name, address: volume.path, icon: "folder", actionTitle: NL("打开")) { [weak self] in self?.onNavigate?(volume.url) }
        document.addSubview(row); mountedRows.append(row)
      }
      mountedTitle.isHidden = visible.isEmpty && volumeError == nil
      return
    }
    if mode == "computer" { heading.stringValue = NL("设备和驱动器（{0}）", visible.count) }
    for volume in visible {
      let card = DriveCard(volume: volume); card.open = { [weak self] in self?.onNavigate?(volume.url) }; card.eject = { [weak self] in self?.eject(volume) }; card.isEjecting = ejecting.contains(volume.path); document.addSubview(card); cards.append(card)
    }
  }
  private func matches(_ name: String, _ address: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) || address.localizedCaseInsensitiveContains(query) }
  func filter(_ value: String) {
    query = value
    updateVolumes()
    if mode == "network" { updateServices(); updateFavorites() }
    needsLayout = true
  }
  override func layout() {
    super.layout(); scroll.frame = bounds
    if mode != "network" { emptyIcon.isHidden = true }
    let width = scroll.contentSize.width
    heading.frame = NSRect(x: 32, y: 28, width: width - 60, height: 28)
    var bottom: CGFloat = 80
    if mode == "airdrop" {
      discoveredTitle.frame = NSRect(x: 32, y: 84, width: max(0, width - 190), height: 24)
      refresh.frame = NSRect(x: max(32, width - 136), y: 78, width: 104, height: 34)
      networkStatus.frame = NSRect(x: 32, y: 118, width: max(0, width - 64), height: 24)
      let columns = max(1, Int((max(0, width - 64) + 16) / 176))
      let cardWidth = max(0, min(190, (width - 64 - CGFloat(columns - 1) * 16) / CGFloat(columns)))
      for (index, card) in airDropCards.enumerated() { card.frame = NSRect(x: 32 + CGFloat(index % columns) * (cardWidth + 16), y: 154 + CGFloat(index / columns) * 118, width: cardWidth, height: 104) }
      let y: CGFloat = airDropCards.isEmpty ? 168 : 172 + CGFloat((airDropCards.count + columns - 1) / columns) * 118
      dropArea.frame = NSRect(x: 32, y: y, width: max(0, width - 64), height: 270)
      choose.frame = NSRect(x: (width - 110) / 2, y: y + 172, width: 110, height: 34); bottom = y + 300
    } else if mode == "computer" {
      let columns = max(1, Int((width - 60 + 16) / 376))
      let cardWidth = min(436, (width - 60 - CGFloat(columns - 1) * 16) / CGFloat(columns))
      for (index, card) in cards.enumerated() { card.frame = NSRect(x: 30 + CGFloat(index % columns) * (cardWidth + 16), y: 70 + CGFloat(index / columns) * 128, width: cardWidth, height: 112) }
      bottom = 90 + CGFloat((cards.count + columns - 1) / columns) * 128
      networkStatus.frame = NSRect(x: 32, y: bottom, width: max(0, width - 64), height: 24); bottom += 32
    } else {
      server.frame = NSRect(x: 32, y: 108, width: max(100, min(width - 170, 582)), height: 34)
      connect.frame = NSRect(x: server.frame.maxX + 10, y: 108, width: 80, height: 34)
      serverTitle.frame = NSRect(x: 32, y: 82, width: width - 64, height: 22)
      var y: CGFloat = 172
      if !favoriteRows.isEmpty {
        favoritesTitle.frame = NSRect(x: 32, y: y, width: width - 64, height: 24); y += 36
        for row in favoriteRows { row.frame = NSRect(x: 32, y: y, width: width - 64, height: 64); y += 72 }
        y += 20
      }
      if !mountedRows.isEmpty || volumeError != nil {
        mountedTitle.frame = NSRect(x: 32, y: y, width: width - 64, height: 24); y += 36
        for row in mountedRows { row.frame = NSRect(x: 32, y: y, width: width - 64, height: 64); y += 72 }
        if volumeError != nil { volumeStatus.frame = NSRect(x: 32, y: y, width: width - 64, height: 24); y += 32 }
        y += 20
      }
      discoveredTitle.frame = NSRect(x: 32, y: y + 6, width: width - 190, height: 24)
      refresh.frame = NSRect(x: width - 136, y: y, width: 104, height: 34); y += 48
      let empty = serviceRows.isEmpty && [NL("未发现共享设备"), NL("没有找到匹配的项目")].contains(networkStatus.stringValue)
      emptyIcon.isHidden = !empty
      emptyIcon.frame = NSRect(x: 32, y: y + 20, width: 32, height: 32)
      networkStatus.textColor = empty ? ExplorerPalette.text : ExplorerPalette.secondary
      networkStatus.frame = NSRect(x: 32, y: y + (empty ? 66 : 0), width: width - 64, height: 24)
      if serviceRows.isEmpty { y += empty ? 110 : 44 }
      for row in serviceRows { row.frame = NSRect(x: 32, y: y, width: width - 64, height: 64); y += 72 }
      bottom = y + 32
    }
    document.frame = NSRect(x: 0, y: 0, width: width, height: max(bounds.height, bottom))
  }
  private func chooseFiles() {
    guard let window else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
    panel.beginSheetModal(for: window) { [weak self] result in if result == .OK { self?.share(panel.urls) } }
  }
  private func share(_ urls: [URL]) {
    guard let service = NSSharingService(named: .sendViaAirDrop), !urls.isEmpty else { return }
    service.perform(withItems: urls)
  }
  private func setConnecting(_ busy: Bool) {
    connect.title = busy ? NL("取消") : NL("连接"); connect.isEnabled = busy || canConnect; server.isEnabled = !busy; refresh.isEnabled = !busy
    for row in favoriteRows { row.button.isEnabled = !busy }
    for row in serviceRows { row.button.isEnabled = !busy && row.available }
  }
  private var canConnect: Bool {
    let address = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return !address.isEmpty && address != "smb://"
  }
  func controlTextDidChange(_ notification: Notification) { connect.isEnabled = connectionTask != nil || canConnect }
  @objc private func connectServer() {
    if let task = connectionTask { task.cancel(); connect.isEnabled = false; networkStatus.stringValue = NL("正在取消…"); return }
    let input = server.stringValue
    do { _ = try NativeNetwork.validate(input) } catch { networkStatus.stringValue = NL(error.localizedDescription); return }
    let token = revision; setConnecting(true); networkStatus.stringValue = NL("正在连接…")
    connectionTask = Task { @MainActor [weak self] in
      do {
        let directory = try await NativeNetwork.shared.connection(input)
        guard let self, self.revision == token else { return }; self.connectionTask = nil; self.setConnecting(false)
        if let directory { self.networkStatus.stringValue = ""; self.onVolumesChanged?(); self.onNavigate?(directory) }
        else { self.networkStatus.stringValue = NL("已取消") }
      } catch {
        guard let self, self.revision == token else { return }; self.connectionTask = nil; self.setConnecting(false); self.networkStatus.stringValue = NL(error.localizedDescription)
      }
    }
  }
  private func discover() {
    stopDiscovery(); guard discoveryEnabled else { updateServices(); return }; discovery = NetServiceBrowser(); discovery.delegate = self
    updateServices(); networkStatus.stringValue = NL("正在查找共享电脑…")
    discovery.searchForServices(ofType: "_smb._tcp.", inDomain: "local.")
    let token = revision, browser = discovery
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak browser] in
      guard let self, self.revision == token, self.discovery === browser, self.connectionTask == nil else { return }
      self.updateServices()
    }
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard browser === discovery, mode == "network", !services.contains(where: { $0.name == service.name && $0.domain == service.domain && $0.type == service.type }) else { return }
    services.append(service); service.delegate = self; service.resolve(withTimeout: 5); if !moreComing { updateServices() }
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
    guard browser === discovery else { return }; service.delegate = nil; service.stop(); services.removeAll { $0 == service }; if !moreComing { updateServices() }
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { guard browser === discovery, connectionTask == nil else { return }; networkStatus.stringValue = NL("无法发现共享电脑") }
  func netServiceDidResolveAddress(_ sender: NetService) { guard services.contains(sender) else { return }; updateServices() }

  private func updateFavorites() {
    favoriteRows.forEach { $0.removeFromSuperview() }; favoriteRows.removeAll()
    favoritesTitle.isHidden = true
    guard mode == "network" else { needsLayout = true; return }
    for favorite in NativeServerFavorites.load(defaults) where matches(favorite.name, favorite.address) {
      let row = NetworkDeviceRow(name: favorite.name, address: favorite.address, icon: "network", actionTitle: NL("连接")) { [weak self] in
        guard let self, self.connectionTask == nil else { return }
        self.server.stringValue = favorite.address; self.connectServer()
      }
      row.button.isEnabled = connectionTask == nil
      row.button.setAccessibilityLabel(NL("连接“{0}”", favorite.name))
      row.onRemove = { [weak self] in
        guard let self else { return }
        do { try NativeServerFavorites.remove(favorite.address, from: self.defaults) }
        catch { self.networkStatus.stringValue = error.localizedDescription }
      }
      document.addSubview(row); favoriteRows.append(row)
    }
    favoritesTitle.isHidden = favoriteRows.isEmpty; needsLayout = true
  }
  private func updateServices() {
    serviceRows.forEach { $0.removeFromSuperview() }; serviceRows.removeAll()
    for service in services where matches(service.name, service.hostName ?? "") {
      var components = URLComponents(); components.scheme = "smb"; components.host = service.hostName
      if service.port > 0 && service.port != 445 { components.port = service.port }
      let address = components.url?.absoluteString ?? ""
      let row = NetworkDeviceRow(name: service.name, address: address, icon: "computer", actionTitle: NL("连接")) { [weak self, weak service] in
        guard let self, let service, service.hostName != nil, service.port > 0 else { return }
        self.server.stringValue = address; self.connectServer()
      }
      row.available = service.hostName != nil && service.port > 0
      row.button.isEnabled = connectionTask == nil && row.available
      row.button.setAccessibilityLabel(NL("连接“{0}”", service.name))
      document.addSubview(row); serviceRows.append(row)
    }
    if connectionTask == nil { networkStatus.stringValue = serviceRows.isEmpty ? (query.isEmpty ? NL("未发现共享设备") : NL("没有找到匹配的项目")) : "" }; needsLayout = true
  }
  deinit { if let favoritesObserver { NotificationCenter.default.removeObserver(favoritesObserver) }; if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }; discovery.delegate = nil; discovery.stop(); services.forEach { $0.delegate = nil; $0.stop() }; connectionTask?.cancel() }
}

final class DriveCard: SurfaceView {
  let volume: ExplorerVolume
  var open: (() -> Void)?
  var eject: (() -> Void)?
  var isEjecting = false { didSet { ejectButton.isEnabled = !isEjecting } }
  private let ejectButton = NSButton(title: "", target: nil, action: nil)
  private let icon = NSImageView(), name = label("", size: 15), kind = label("", size: 11, color: ExplorerPalette.secondary), capacity = label("", size: 11, color: ExplorerPalette.secondary)
  private var selected = false
  init(volume: ExplorerVolume) {
    self.volume = volume; super.init(frame: .zero)
    [icon, name, kind, capacity, ejectButton].forEach(addSubview)
    ejectButton.isBordered = false; ejectButton.image = NSImage(systemSymbolName: "eject", accessibilityDescription: NL("推出")); ejectButton.toolTip = NL("推出"); ejectButton.setAccessibilityLabel(NL("推出")); ejectButton.target = self; ejectButton.action = #selector(ejectVolume); ejectButton.isHidden = !volume.canEject
    icon.image = NSWorkspace.shared.icon(forFile: volume.url.path); icon.imageScaling = .scaleProportionallyUpOrDown
    name.stringValue = volume.name; name.font = .systemFont(ofSize: 15, weight: .semibold)
    switch volume.kind { case .local: kind.stringValue = NL("本地磁盘"); case .network: kind.stringValue = NL("网络驱动器"); case .unknown: kind.stringValue = NL("类型未知") }
    switch volume.capacityState {
    case .unavailable, .invalid: capacity.stringValue = NL("容量不可用")
    case .unknown: capacity.stringValue = NL("容量未知")
    case .known, .partial: capacity.stringValue = NL("{0} 可用，共 {1}", volume.free.map(ExplorerFormat.size) ?? NL("未知"), volume.total.map(ExplorerFormat.size) ?? NL("未知"))
    }
    toolTip = capacity.stringValue
    setAccessibilityRole(.button); setAccessibilityLabel(volume.name + "，" + kind.stringValue + "，" + capacity.stringValue)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func ejectVolume() { eject?() }
  override func layout() { super.layout(); ejectButton.frame = NSRect(x: bounds.width - 40, y: 14, width: 26, height: 26); icon.frame = NSRect(x: 22, y: 24, width: 64, height: 64); name.frame = NSRect(x: 108, y: 17, width: bounds.width - (volume.canEject ? 158 : 130), height: 22); kind.frame = NSRect(x: 108, y: 41, width: bounds.width - 130, height: 17); capacity.frame = NSRect(x: 108, y: 79, width: bounds.width - 130, height: 18) }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); if event.clickCount == 2 { open?() } }
  override func becomeFirstResponder() -> Bool { selected = true; needsDisplay = true; return true }
  override func resignFirstResponder() -> Bool { selected = false; needsDisplay = true; return true }
  override func rightMouseDown(with event: NSEvent) {
    guard let window else { return }
    var items = [ExplorerMenuItem(title: NL("打开"), action: { [weak self] in self?.open?() })]
    if volume.canEject { items.append(ExplorerMenuItem(title: NL("推出“{0}”", volume.name), icon: "eject", enabled: !isEjecting, action: { [weak self] in self?.eject?() })) }
    ExplorerMenu.show(items, at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
  }
  override func accessibilityPerformPress() -> Bool { open?(); return true }
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) { if event.keyCode == 36 { open?() } else { super.keyDown(with: event) } }
  override func draw(_ dirtyRect: NSRect) {
    let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    (selected ? ExplorerPalette.selection : ExplorerPalette.sidebar).setFill(); frame.fill(); ExplorerPalette.border.setStroke(); frame.stroke()
    guard let fraction = volume.usedFraction else { return }
    let track = NSRect(x: 108, y: 65, width: max(0, bounds.width - 130), height: 6)
    ExplorerPalette.active.setFill(); NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
    NSColor(srgbRed: 66 / 255, green: 160 / 255, blue: 218 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: 6), xRadius: 3, yRadius: 3).fill()
  }
}

private final class AirDropDeviceCard: SurfaceView {
  private let image = NSImageView()
  private let name: NSTextField
  init(name: String) {
    self.name = label(name, size: 13)
    super.init(frame: .zero); color = .clear
    image.image = ExplorerIcons.image("computer", size: 48, color: ExplorerPalette.accent)
    image.imageScaling = .scaleProportionallyUpOrDown
    self.name.alignment = .center; self.name.lineBreakMode = .byTruncatingTail; self.name.maximumNumberOfLines = 1
    toolTip = name; setAccessibilityRole(.group); setAccessibilityLabel(name)
    [image, self.name].forEach(addSubview)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout(); image.frame = NSRect(x: (bounds.width - 48) / 2, y: 8, width: 48, height: 48)
    name.frame = NSRect(x: 4, y: 68, width: max(0, bounds.width - 8), height: 22)
  }
}

private final class AirDropTarget: SurfaceView {
  var onFiles: (([URL]) -> Void)?
  override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
  required init?(coder: NSCoder) { fatalError() }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []; guard !urls.isEmpty else { return false }; onFiles?(urls); return true }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); path.setLineDash([4, 4], count: 2, phase: 0); ExplorerPalette.border.setStroke(); path.stroke()
    ExplorerIcons.image("airdrop", size: 56, color: ExplorerPalette.accent).draw(in: NSRect(x: bounds.midX - 28, y: 64, width: 56, height: 56), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let title = NL("拖入要发送的文件") as NSString, attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: ExplorerPalette.text]
    title.draw(at: NSPoint(x: bounds.midX - title.size(withAttributes: attrs).width / 2, y: 136), withAttributes: attrs)
  }
}

private final class NetworkDeviceRow: SurfaceView {
  var onRemove: (() -> Void)?
  let button: EDButton
  var available = true
  private let image = NSImageView()
  private let name: NSTextField
  private let address: NSTextField
  init(name: String, address: String, icon: String, actionTitle: String, action: @escaping () -> Void) {
    self.name = label(name, size: 13); self.name.font = .systemFont(ofSize: 13, weight: .semibold)
    self.address = label(address, size: 11, color: ExplorerPalette.secondary)
    button = EDButton(title: actionTitle, style: .secondary); button.onPress = action
    super.init(frame: .zero)
    image.image = ExplorerIcons.image(icon, size: 28); image.imageScaling = .scaleProportionallyUpOrDown
    [image, self.name, self.address, button].forEach(addSubview)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout(); image.frame = NSRect(x: 12, y: 18, width: 28, height: 28)
    name.frame = NSRect(x: 54, y: 12, width: max(0, bounds.width - 150), height: 20)
    address.frame = NSRect(x: 54, y: 35, width: max(0, bounds.width - 150), height: 18)
    button.frame = NSRect(x: bounds.width - 84, y: 17, width: 72, height: 30)
  }
  override func rightMouseDown(with event: NSEvent) {
    guard let window, let onRemove else { super.rightMouseDown(with: event); return }
    ExplorerMenu.show([ExplorerMenuItem(title: NL("移除收藏"), action: onRemove)], at: window.convertPoint(toScreen: event.locationInWindow), owner: window)
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect); ExplorerPalette.border.setStroke()
    let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: bounds.height - 0.5)); line.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5)); line.stroke()
  }
}
